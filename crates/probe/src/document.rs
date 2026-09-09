//! The document probe: lopdf for the Info dictionary and page count,
//! pdf-extract for the prose behind the SimHash — the text the pure-Dart
//! tier cannot reach — and rbook for EPUB metadata and chapters.

use std::path::Path;

use lopdf::{Document, Object};
use serde_json::Value;

use crate::report::Report;
use crate::simhash::simhash;
use crate::{ProbeError, Result};

pub fn probe(path: &Path, ext: &str) -> Result<Report> {
    match ext {
        "pdf" => pdf(path),
        "epub" => epub(path),
        _ => Err(ProbeError::unsupported(ext)),
    }
}

fn pdf(path: &Path) -> Result<Report> {
    let mut r = Report::new("document");
    let doc = Document::load(path).map_err(|e| ProbeError::parse(format!("pdf: {e}")))?;

    if let Ok(info) = doc
        .trailer
        .get(b"Info")
        .and_then(|obj| resolve(&doc, obj))
        .and_then(Object::as_dict)
    {
        for (key, value) in info.iter() {
            let key = String::from_utf8_lossy(key).into_owned();
            let Ok(resolved) = resolve(&doc, value) else {
                continue;
            };
            let Object::String(bytes, _) = resolved else {
                continue;
            };
            let text = pdf_string(bytes);
            match key.as_str() {
                "Title" => r.set_str("title", &text),
                "Author" => {
                    r.set_str("author", &text);
                    r.push_list("authors", &text);
                }
                "Subject" => r.set_str("description", &text),
                _ => r.extra(&key, Value::from(text)),
            }
        }
    }
    let pages = doc.get_pages().len();
    if pages > 0 {
        r.set_int("pageCount", pages as i64);
    }

    // pdf-extract meets a lot of strange PDFs; a panic here must cost
    // only the hash, never the metadata. A clean extraction always
    // hashes — a textless page hashes as emptiness, which the pinned
    // algorithm defines.
    let extracted = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        pdf_extract::extract_text(path)
    }));
    if let Ok(Ok(text)) = extracted {
        r.simhash64 = Some(simhash(&text));
    }
    Ok(r)
}

fn resolve<'a>(doc: &'a Document, object: &'a Object) -> lopdf::Result<&'a Object> {
    match object {
        Object::Reference(id) => doc.get_object(*id),
        other => Ok(other),
    }
}

/// PDF text strings are UTF-16BE behind a BOM, PDFDocEncoding otherwise —
/// close enough to Latin-1 for the printable range.
fn pdf_string(bytes: &[u8]) -> String {
    if bytes.len() >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff {
        let units: Vec<u16> = bytes[2..]
            .chunks_exact(2)
            .map(|pair| u16::from_be_bytes([pair[0], pair[1]]))
            .collect();
        String::from_utf16_lossy(&units)
    } else {
        match std::str::from_utf8(bytes) {
            Ok(text) => text.to_owned(),
            Err(_) => bytes.iter().map(|b| char::from(*b)).collect(),
        }
    }
}

fn epub(path: &Path) -> Result<Report> {
    let mut r = Report::new("document");
    let book =
        rbook::Epub::open(path).map_err(|e| ProbeError::parse(format!("epub: {e}")))?;
    let metadata = book.metadata();

    if let Some(title) = metadata.title() {
        r.set_str("title", title.value());
    }
    for creator in metadata.creators() {
        let name = creator.value();
        r.set_str("author", name);
        r.push_list("authors", name);
    }
    if let Some(language) = metadata.languages().next() {
        r.set_str("language", language.value());
    }
    if let Some(publisher) = metadata.publishers().next() {
        r.set_str("publisher", publisher.value());
    }
    if let Some(description) = metadata.description() {
        r.set_str("description", description.value());
    }
    for identifier in metadata.identifiers() {
        let value = identifier.value();
        if let Some(isbn) = isbn_of(value) {
            r.set_str("isbn", &isbn);
        } else {
            r.extra_str("dc:identifier", value);
        }
    }

    if let Some(cover) = book.manifest().cover_image() {
        if let Ok(bytes) = cover.read_bytes() {
            if let Some(mime) = image_mime(&bytes) {
                r.push_artwork(mime, &bytes, "embedded");
            }
        }
    }

    let mut prose = String::new();
    let mut reader = book.reader();
    while let Some(Ok(content)) = reader.read_next() {
        prose.push_str(content.content());
        prose.push(' ');
    }
    let stripped = strip_html(&prose);
    if !stripped.trim().is_empty() {
        r.simhash64 = Some(simhash(&stripped));
    }
    Ok(r)
}

/// An identifier smells like an ISBN when, stripped of its `urn:isbn:`
/// dress and its hyphens, ten or thirteen digits remain — matching the
/// Dart tier's nose exactly.
fn isbn_of(raw: &str) -> Option<String> {
    let mut cleaned = raw.trim().to_ascii_lowercase();
    for prefix in ["urn:isbn:", "isbn:", "isbn "] {
        if let Some(rest) = cleaned.strip_prefix(prefix) {
            cleaned = rest.trim_start().to_owned();
            break;
        }
    }
    let cleaned: String = cleaned.chars().filter(|c| *c != '-' && *c != ' ').collect();
    let digits_13 = cleaned.len() == 13 && cleaned.chars().all(|c| c.is_ascii_digit());
    let digits_10 = cleaned.len() == 10
        && cleaned[..9].chars().all(|c| c.is_ascii_digit())
        && cleaned
            .chars()
            .last()
            .is_some_and(|c| c.is_ascii_digit() || c == 'x');
    (digits_13 || digits_10).then(|| cleaned.to_ascii_uppercase())
}

fn image_mime(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
        Some("image/jpeg")
    } else if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        Some("image/png")
    } else if bytes.starts_with(b"GIF8") {
        Some("image/gif")
    } else if bytes.len() > 12 && &bytes[8..12] == b"WEBP" {
        Some("image/webp")
    } else {
        None
    }
}

/// Chapter XHTML flattened to prose the same way the Dart tier does it:
/// comments, scripts, and styles dropped whole, tags become spaces, the
/// common entities come back as their characters. The simhash normalizer
/// sweeps up the rest.
fn strip_html(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let bytes = html.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'<' {
            let rest = &html[i..];
            let (skip_to, replacement) = if rest.starts_with("<!--") {
                (rest.find("-->").map(|end| i + end + 3), " ")
            } else if starts_with_tag(rest, "script") {
                (close_of(rest, "</script>").map(|end| i + end), " ")
            } else if starts_with_tag(rest, "style") {
                (close_of(rest, "</style>").map(|end| i + end), " ")
            } else {
                (rest.find('>').map(|end| i + end + 1), " ")
            };
            out.push_str(replacement);
            i = skip_to.unwrap_or(bytes.len());
        } else if bytes[i] == b'&' {
            let rest = &html[i..];
            match entity(rest) {
                Some((ch, len)) => {
                    out.push(ch);
                    i += len;
                }
                None => {
                    out.push('&');
                    i += 1;
                }
            }
        } else {
            let ch = html[i..].chars().next().unwrap();
            out.push(ch);
            i += ch.len_utf8();
        }
    }
    out
}

fn starts_with_tag(rest: &str, name: &str) -> bool {
    rest.len() > name.len()
        && rest[1..].len() >= name.len()
        && rest[1..1 + name.len()].eq_ignore_ascii_case(name)
}

fn close_of(rest: &str, close: &str) -> Option<usize> {
    rest.to_ascii_lowercase().find(close).map(|at| at + close.len())
}

fn entity(rest: &str) -> Option<(char, usize)> {
    let end = rest[..rest.len().min(12)].find(';')?;
    let body = &rest[1..end];
    let ch = match body {
        "lt" => '<',
        "gt" => '>',
        "quot" => '"',
        "apos" => '\'',
        "nbsp" => ' ',
        "amp" => '&',
        _ => {
            let code = if let Some(hex) = body.strip_prefix("#x").or_else(|| body.strip_prefix("#X")) {
                u32::from_str_radix(hex, 16).ok()?
            } else if let Some(dec) = body.strip_prefix('#') {
                dec.parse().ok()?
            } else {
                return None;
            };
            char::from_u32(code)?
        }
    };
    Some((ch, end + 1))
}
