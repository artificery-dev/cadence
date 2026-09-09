//! cadence-probe: the native enrichment tier behind three C symbols.
//!
//! Dart hands over a path; this crate hands back JSON — typed fields
//! under the `MediaMetadata` names, every raw tag preserved in `extra`,
//! artwork as base64, without computing content fingerprints. Malformed media
//! can find panics in this stack, so every entry point is wrapped in `catch_unwind`:
//! the worst a bad file can do is an `err` envelope. No globals live
//! here; several Dart worker isolates call in at once.
//!
//! The envelope: `{"ok": {...}}` on success, `{"err": {"code", "msg"}}`
//! on anything else. See `daemon/lib/probe.dart` for
//! the reader.

mod asf;
mod audio;
mod avi;
mod document;
mod image_probe;
mod report;
mod tagmap;
mod video;

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;

use serde_json::{json, Value};

/// Bumped when the symbols or the envelope change shape.
const ABI_VERSION: u32 = 1;

pub struct ProbeError {
    code: &'static str,
    msg: String,
}

impl ProbeError {
    fn unsupported(ext: &str) -> Self {
        ProbeError {
            code: "unsupported",
            msg: format!("no probe for .{ext}"),
        }
    }

    fn parse(msg: String) -> Self {
        ProbeError { code: "parse", msg }
    }
}

impl From<std::io::Error> for ProbeError {
    fn from(err: std::io::Error) -> Self {
        ProbeError {
            code: "io",
            msg: err.to_string(),
        }
    }
}

impl From<lofty::error::FileParseError> for ProbeError {
    fn from(err: lofty::error::FileParseError) -> Self {
        ProbeError::parse(err.to_string())
    }
}

pub type Result<T> = std::result::Result<T, ProbeError>;

/// One file, probed by extension, answered as the envelope `Value`.
pub fn probe_path(path_str: &str) -> Value {
    let path = Path::new(path_str);
    let ext = path
        .extension()
        .map(|e| e.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();
    let outcome = match ext.as_str() {
        "mp3" | "flac" | "ogg" | "oga" | "opus" | "m4a" | "m4b" | "aac" | "wav" | "aiff"
        | "aif" | "ape" | "wv" | "wma" | "mka" => audio::probe(path, &ext),
        "mp4" | "m4v" | "mov" | "mkv" | "webm" | "avi" => video::probe(path, &ext),
        "jpg" | "jpeg" | "png" | "gif" | "webp" | "bmp" | "tif" | "tiff" | "heic" | "heif"
        | "avif" => image_probe::probe(path, &ext),
        "pdf" | "epub" => document::probe(path, &ext),
        _ => Err(ProbeError::unsupported(&ext)),
    };
    match outcome {
        Ok(report) => json!({ "ok": report.to_json() }),
        Err(error) => json!({ "err": { "code": error.code, "msg": error.msg } }),
    }
}

fn envelope_err(code: &str, msg: &str) -> String {
    json!({ "err": { "code": code, "msg": msg } }).to_string()
}

/// The ABI generation this library speaks. Dart refuses any other answer.
#[no_mangle]
pub extern "C" fn cadence_abi_version() -> u32 {
    ABI_VERSION
}

/// Probes `path` (NUL-terminated UTF-8) and returns a NUL-terminated
/// UTF-8 JSON envelope the caller must release with
/// [`cadence_free_string`]. Never returns null except when even the
/// error rendering failed.
///
/// # Safety
///
/// `path` must be a valid NUL-terminated C string, or null.
#[no_mangle]
pub unsafe extern "C" fn cadence_probe_file(path: *const c_char) -> *mut c_char {
    let rendered = catch_unwind(AssertUnwindSafe(|| {
        if path.is_null() {
            return envelope_err("badarg", "null path");
        }
        let raw = unsafe { CStr::from_ptr(path) };
        match raw.to_str() {
            Ok(path_str) => probe_path(path_str).to_string(),
            Err(_) => envelope_err("badarg", "path is not UTF-8"),
        }
    }))
    .unwrap_or_else(|_| envelope_err("panic", "probe panicked; see stderr"));
    match CString::new(rendered) {
        Ok(out) => out.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Releases a string minted by [`cadence_probe_file`]. Null is a no-op.
///
/// # Safety
///
/// `ptr` must be null or a pointer previously returned by
/// [`cadence_probe_file`], and must not be used again after this call.
#[no_mangle]
pub unsafe extern "C" fn cadence_free_string(ptr: *mut c_char) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !ptr.is_null() {
            drop(unsafe { CString::from_raw(ptr) });
        }
    }));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(rel: &str) -> String {
        format!(
            "{}/../../packages/media/test/fixtures/{rel}",
            env!("CARGO_MANIFEST_DIR")
        )
    }

    fn ok_probe(rel: &str) -> Value {
        let envelope = probe_path(&fixture(rel));
        assert!(
            envelope.get("ok").is_some(),
            "expected ok envelope for {rel}, got {envelope}"
        );
        envelope["ok"].clone()
    }

    #[test]
    fn flac_types_musicbrainz_and_replaygain() {
        let ok = ok_probe("audio/tagged.flac");
        let fields = &ok["fields"];
        assert_eq!(fields["musicBrainz"]["recordingId"].as_str().is_some(), true);
        assert_eq!(fields["musicBrainz"]["releaseId"].as_str().is_some(), true);
        assert!(fields["replayGain"]["trackGain"].is_number());
        assert!(fields["replayGain"]["albumPeak"].is_number());
        assert_eq!(fields["trackNumber"], 3);
        assert_eq!(fields["lossless"], true);
        // The raw spellings survive in extra alongside the typed view.
        assert!(ok["extra"]["MUSICBRAINZ_TRACKID"].is_string());
        assert!(ok["extra"]["REPLAYGAIN_TRACK_GAIN"].is_string());
        assert!(!ok["artwork"].as_array().unwrap().is_empty());
    }

    #[test]
    fn m4b_gives_up_its_chapters() {
        let ok = ok_probe("audio/chapters.m4b");
        let chapters = ok["fields"]["chapters"].as_array().unwrap();
        assert_eq!(chapters.len(), 2);
        assert_eq!(chapters[0]["title"], "Chapter One");
        assert_eq!(chapters[1]["title"], "Chapter Two");
    }

    #[test]
    fn mkv_yields_title_and_dimensions() {
        let ok = ok_probe("video/titled.mkv");
        assert_eq!(ok["fields"]["title"], "Two Track Mind");
        assert!(ok["fields"]["width"].as_i64().unwrap() > 0);
        assert!(ok["fields"]["height"].as_i64().unwrap() > 0);
    }

    #[test]
    fn pdf_reads_info_without_fingerprints() {
        let ok = ok_probe("doc/info.pdf");
        assert_eq!(ok["fields"]["title"], "Fixture Document");
        assert_eq!(ok["fields"]["pageCount"], 1);
        assert!(ok.get("phash64").is_none());
        assert!(ok.get("simhash64").is_none());
    }

    #[test]
    fn epub_reads_the_opf() {
        let ok = ok_probe("doc/book.epub");
        assert_eq!(ok["fields"]["title"], "The Fixture Book");
        assert!(ok["fields"]["authors"].as_array().is_some());
        assert!(ok.get("phash64").is_none());
        assert!(ok.get("simhash64").is_none());
    }

    #[test]
    fn exif_jpg_names_its_camera() {
        let ok = ok_probe("image/exif.jpg");
        assert_eq!(ok["fields"]["cameraMake"], "Cadence");
        assert_eq!(ok["fields"]["cameraModel"], "Fixture Cam 1000");
        assert!(ok["fields"]["gpsLatitude"].is_number());
        assert!(ok.get("phash64").is_none());
        assert!(ok.get("simhash64").is_none());
    }

    #[test]
    fn unknown_extension_errs_politely() {
        let envelope = probe_path("/nonexistent/file.xyz");
        assert_eq!(envelope["err"]["code"], "unsupported");
    }

    #[test]
    fn ffi_round_trip_speaks_json() {
        let path = CString::new(fixture("audio/tagged.flac")).unwrap();
        let raw = unsafe { cadence_probe_file(path.as_ptr()) };
        assert!(!raw.is_null());
        let text = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_owned();
        unsafe { cadence_free_string(raw) };
        let envelope: Value = serde_json::from_str(&text).unwrap();
        assert!(envelope.get("ok").is_some());
        assert_eq!(cadence_abi_version(), 1);
    }
}
