//! Where raw tags become typed fields — one dialect at a time.
//!
//! Each tag family (ID3v2 frames, Vorbis comments, APE items, MP4 ilst
//! atoms) gets its own walk over the concrete structures lofty read, so
//! nothing is lost to a generic view. Whatever a walk cannot type lands in
//! `extra` under its source-original key. MusicBrainz, AcoustID, and
//! ReplayGain tags land twice on purpose: typed for queries, raw in
//! `extra` for fidelity — identifiers are too precious to paraphrase.

use lofty::ape::ApeTag;
use lofty::id3::v1::Id3v1Tag;
use lofty::id3::v2::{Frame, Id3v2Tag};
use lofty::iff::aiff::AiffTextChunks;
use lofty::iff::wav::RiffInfoList;
use lofty::mp4::{Atom, AtomData, AtomIdent, Ilst};
use lofty::ogg::tag::VorbisComments;
use lofty::picture::Picture;
use lofty::tag::Accessor;
use serde_json::Value;

use crate::report::Report;

/// A key stripped to its skeleton — uppercase alphanumerics only — so
/// `MUSICBRAINZ_ALBUMID`, `MusicBrainz Album Id`, and the iTunes freeform
/// spelling all answer to one name.
fn norm_key(key: &str) -> String {
    key.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_uppercase())
        .collect()
}

fn parse_int(value: &str) -> Option<i64> {
    let digits: String = value
        .trim()
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    digits.parse().ok()
}

fn parse_float(value: &str) -> Option<f64> {
    let cleaned: String = value
        .trim()
        .chars()
        .take_while(|c| c.is_ascii_digit() || matches!(c, '-' | '+' | '.' | 'e' | 'E'))
        .collect();
    cleaned.parse().ok()
}

/// Splits `3/8` into number and total.
fn set_pair(r: &mut Report, number_key: &str, total_key: &str, value: &str) {
    let mut parts = value.splitn(2, '/');
    if let Some(number) = parts.next().and_then(parse_int) {
        r.set_int(number_key, number);
    }
    if let Some(total) = parts.next().and_then(parse_int) {
        r.set_int(total_key, total);
    }
}

fn set_year_like(r: &mut Report, key: &str, value: &str) {
    if let Some(year) = parse_int(&value.chars().take(4).collect::<String>()) {
        if year >= 1000 {
            r.set_int(key, year);
        }
    }
}

/// The cross-dialect identifiers: typed *and* kept raw. Returns true when
/// the key was one of them.
fn apply_special(r: &mut Report, raw_key: &str, norm: &str, value: &str) -> bool {
    let mb = |r: &mut Report, member: &str, value: &str, raw_key: &str| {
        r.set_nested("musicBrainz", member, Value::from(value.trim()));
        r.extra_str(raw_key, value);
    };
    let rg = |r: &mut Report, member: &str, value: &str, raw_key: &str| {
        if let Some(number) = parse_float(value) {
            r.set_nested("replayGain", member, Value::from(number));
        }
        r.extra_str(raw_key, value);
    };
    match norm {
        "MUSICBRAINZTRACKID" => mb(r, "recordingId", value, raw_key),
        "MUSICBRAINZRELEASETRACKID" => mb(r, "trackId", value, raw_key),
        "MUSICBRAINZALBUMID" => mb(r, "releaseId", value, raw_key),
        "MUSICBRAINZRELEASEGROUPID" => mb(r, "releaseGroupId", value, raw_key),
        "MUSICBRAINZARTISTID" => mb(r, "artistId", value, raw_key),
        "MUSICBRAINZALBUMARTISTID" => mb(r, "albumArtistId", value, raw_key),
        "MUSICBRAINZWORKID" => mb(r, "workId", value, raw_key),
        "ACOUSTIDID" => {
            r.set_str("acoustId", value);
            r.extra_str(raw_key, value);
        }
        "REPLAYGAINTRACKGAIN" => rg(r, "trackGain", value, raw_key),
        "REPLAYGAINTRACKPEAK" => rg(r, "trackPeak", value, raw_key),
        "REPLAYGAINALBUMGAIN" => rg(r, "albumGain", value, raw_key),
        "REPLAYGAINALBUMPEAK" => rg(r, "albumPeak", value, raw_key),
        _ => return false,
    }
    true
}

/// One Vorbis-style key/value into the report — also the dialect APE and
/// WMA extended descriptions are folded into.
pub fn apply_vorbis_key(r: &mut Report, key: &str, value: &str) {
    let norm = norm_key(key);
    if apply_special(r, key, &norm, value) {
        return;
    }
    match norm.as_str() {
        "TITLE" => r.set_str("title", value),
        "ARTIST" => {
            r.set_str("artist", value);
            r.push_list("artists", value);
        }
        "ALBUM" => r.set_str("album", value),
        "ALBUMARTIST" => r.set_str("albumArtist", value),
        "DATE" | "YEAR" => r.set_str("date", value),
        "ORIGINALYEAR" | "ORIGINALDATE" => set_year_like(r, "originalYear", value),
        "TRACKNUMBER" | "TRACK" => set_pair(r, "trackNumber", "trackTotal", value),
        "TRACKTOTAL" | "TOTALTRACKS" => {
            if let Some(n) = parse_int(value) {
                r.set_int("trackTotal", n);
            }
        }
        "DISCNUMBER" | "DISC" => set_pair(r, "discNumber", "discTotal", value),
        "DISCTOTAL" | "TOTALDISCS" => {
            if let Some(n) = parse_int(value) {
                r.set_int("discTotal", n);
            }
        }
        "GENRE" => r.push_list("genres", value),
        "COMPOSER" => r.push_list("composers", value),
        "LYRICIST" => r.push_list("lyricists", value),
        "CONDUCTOR" => r.set_str("conductor", value),
        "REMIXER" | "MIXARTIST" => r.set_str("remixer", value),
        "GROUPING" | "CONTENTGROUP" => r.set_str("grouping", value),
        "COMMENT" | "DESCRIPTION" => r.set_str("comment", value),
        "LYRICS" | "UNSYNCEDLYRICS" => r.set_str("lyrics", value),
        "LANGUAGE" => r.set_str("language", value),
        "INITIALKEY" | "KEY" => r.set_str("initialKey", value),
        "ISRC" => r.set_str("isrc", value),
        "BARCODE" => r.set_str("barcode", value),
        "CATALOGNUMBER" | "CATALOGUENUMBER" => r.set_str("catalogNumber", value),
        "LABEL" | "ORGANIZATION" | "PUBLISHER" => r.set_str("label", value),
        "ENCODER" | "ENCODEDBY" => r.set_str("encoder", value),
        "MEDIA" => r.set_str("media", value),
        "MOOD" => r.set_str("mood", value),
        "BPM" => {
            if let Some(n) = parse_int(value) {
                r.set_int("bpm", n);
            }
        }
        "COMPILATION" => r.set_bool("compilation", matches!(value.trim(), "1" | "true")),
        "SORTTITLE" | "TITLESORT" => r.set_str("sortTitle", value),
        "SORTARTIST" | "ARTISTSORT" => r.set_str("sortArtist", value),
        "SORTALBUM" | "ALBUMSORT" => r.set_str("sortAlbum", value),
        "SORTALBUMARTIST" | "ALBUMARTISTSORT" => r.set_str("sortAlbumArtist", value),
        _ => r.extra_str(key, value),
    }
}

pub fn map_vorbis(r: &mut Report, tag: &VorbisComments) {
    for (key, value) in tag.items() {
        apply_vorbis_key(r, key, value);
    }
}

pub fn map_ape(r: &mut Report, tag: &ApeTag) {
    for item in tag {
        if let Some(text) = item.value().text() {
            apply_vorbis_key(r, item.key(), text);
        }
    }
}

fn push_picture(r: &mut Report, picture: &Picture) {
    let mime = picture
        .mime_type()
        .map_or("application/octet-stream", |m| m.as_str());
    r.push_artwork(mime, picture.data(), "embedded");
}

/// Every ID3v2 frame, walked concretely — TXXX included, nothing lossy.
pub fn map_id3v2(r: &mut Report, tag: &Id3v2Tag) {
    if let Some(genres) = tag.genres() {
        for genre in genres {
            r.push_list("genres", genre);
        }
    }
    for frame in tag {
        let id = frame.id_str().to_owned();
        match frame {
            Frame::Text(text) => {
                if id == "TCON" {
                    continue; // spoken for by genres() above
                }
                apply_id3_text(r, &id, &text.value);
            }
            Frame::UserText(user) => {
                let raw_key = format!("TXXX:{}", user.description);
                let norm = norm_key(&user.description);
                if apply_special(r, &raw_key, &norm, &user.content) {
                    continue;
                }
                match norm.as_str() {
                    "BARCODE" => r.set_str("barcode", &user.content),
                    "CATALOGNUMBER" => r.set_str("catalogNumber", &user.content),
                    "LABEL" => r.set_str("label", &user.content),
                    "ORIGINALYEAR" => set_year_like(r, "originalYear", &user.content),
                    "COMPILATION" => {
                        r.set_bool("compilation", user.content.trim() == "1");
                    }
                    _ => r.extra_str(&raw_key, &user.content),
                }
            }
            Frame::Comment(comment) => {
                if comment.description.is_empty() {
                    r.set_str("comment", &comment.content);
                } else {
                    r.extra_str(&format!("COMM:{}", comment.description), &comment.content);
                }
            }
            Frame::UnsynchronizedText(lyrics) => r.set_str("lyrics", &lyrics.content),
            Frame::Timestamp(stamp) => {
                let rendered = stamp.timestamp.to_string();
                match id.as_str() {
                    "TDRC" => r.set_str("date", &rendered),
                    "TDOR" => set_year_like(r, "originalYear", &rendered),
                    _ => r.extra_str(&id, &rendered),
                }
            }
            Frame::Picture(picture) => push_picture(r, &picture.picture),
            Frame::Popularimeter(popm) => {
                if popm.rating > 0 {
                    let scaled = (f64::from(popm.rating) * 100.0 / 255.0).round() as i64;
                    r.set_int("rating", scaled);
                }
            }
            Frame::UniqueFileIdentifier(ufid) => {
                let value = String::from_utf8_lossy(&ufid.identifier).into_owned();
                if ufid.owner == "http://musicbrainz.org" {
                    r.set_nested("musicBrainz", "recordingId", Value::from(value.clone()));
                    r.extra_str(&format!("UFID:{}", ufid.owner), &value);
                } else {
                    r.extra_str(&format!("UFID:{}", ufid.owner), &value);
                }
            }
            Frame::KeyValue(pairs) => {
                let rendered: Vec<Value> = pairs
                    .key_value_pairs
                    .iter()
                    .map(|(k, v)| Value::from(format!("{k}: {v}")))
                    .collect();
                r.extra(&id, Value::Array(rendered));
            }
            Frame::Url(url) => r.extra_str(&id, url.url()),
            Frame::UserUrl(url) => {
                r.extra_str(&format!("WXXX:{}", url.description), &url.content);
            }
            Frame::Binary(binary) => {
                r.extra_str(&id, &format!("<{} bytes>", binary.data.len()));
            }
            _ => r.extra_str(&id, "<unrepresented frame>"),
        }
    }
}

fn apply_id3_text(r: &mut Report, id: &str, value: &str) {
    // v2.4 packs multiple values behind NULs; the first is the display one.
    let values: Vec<&str> = value.split('\0').filter(|v| !v.is_empty()).collect();
    let first = values.first().copied().unwrap_or_default();
    match id {
        "TIT2" => r.set_str("title", first),
        "TALB" => r.set_str("album", first),
        "TPE1" => {
            r.set_str("artist", first);
            for v in &values {
                r.push_list("artists", v);
            }
        }
        "TPE2" => r.set_str("albumArtist", first),
        "TPE3" => r.set_str("conductor", first),
        "TPE4" => r.set_str("remixer", first),
        "TIT1" | "GRP1" => r.set_str("grouping", first),
        "TCOM" => {
            for v in &values {
                r.push_list("composers", v);
            }
        }
        "TEXT" => {
            for v in &values {
                r.push_list("lyricists", v);
            }
        }
        "TRCK" => set_pair(r, "trackNumber", "trackTotal", first),
        "TPOS" => set_pair(r, "discNumber", "discTotal", first),
        "TBPM" => {
            if let Some(n) = parse_int(first) {
                r.set_int("bpm", n);
            }
        }
        "TKEY" => r.set_str("initialKey", first),
        "TLAN" => r.set_str("language", first),
        "TMED" => r.set_str("media", first),
        "TMOO" => r.set_str("mood", first),
        "TSRC" => r.set_str("isrc", first),
        "TPUB" => r.set_str("label", first),
        "TENC" | "TSSE" => r.set_str("encoder", first),
        "TSOT" => r.set_str("sortTitle", first),
        "TSOP" => r.set_str("sortArtist", first),
        "TSOA" => r.set_str("sortAlbum", first),
        "TSO2" => r.set_str("sortAlbumArtist", first),
        "TCMP" => r.set_bool("compilation", first.trim() == "1"),
        "TDRC" => r.set_str("date", first),
        "TYER" => r.set_str("date", first),
        "TDOR" | "TORY" => set_year_like(r, "originalYear", first),
        _ => r.extra_str(id, value),
    }
}

/// The 128-byte elder statesman — fills only what nothing else claimed.
pub fn map_id3v1(r: &mut Report, tag: &Id3v1Tag) {
    if let Some(title) = &tag.title {
        r.set_str("title", title);
    }
    if let Some(artist) = &tag.artist {
        r.set_str("artist", artist);
    }
    if let Some(album) = &tag.album {
        r.set_str("album", album);
    }
    if let Some(year) = tag.year {
        r.set_str("date", &year.to_string());
    }
    if let Some(comment) = &tag.comment {
        r.set_str("comment", comment);
    }
    if let Some(track) = tag.track_number {
        r.set_int("trackNumber", i64::from(track));
    }
    if let Some(genre) = tag.genre {
        if let Some(name) = lofty::id3::v1::GENRES.get(genre as usize) {
            r.push_list("genres", name);
        }
    }
}

fn atom_value(data: &AtomData) -> Value {
    match data {
        AtomData::UTF8(s) | AtomData::UTF16(s) => Value::from(s.as_str()),
        AtomData::SignedInteger(n) => Value::from(*n),
        AtomData::UnsignedInteger(n) => Value::from(*n),
        AtomData::Bool(b) => Value::from(*b),
        AtomData::Picture(p) => Value::from(format!("<picture, {} bytes>", p.data().len())),
        _ => Value::from("<binary>"),
    }
}

fn atom_text(atom: &Atom<'_>) -> Option<String> {
    atom.data().find_map(|d| match d {
        AtomData::UTF8(s) | AtomData::UTF16(s) => Some(s.clone()),
        _ => None,
    })
}

fn atom_int(atom: &Atom<'_>) -> Option<i64> {
    atom.data().find_map(|d| match d {
        AtomData::SignedInteger(n) => Some(i64::from(*n)),
        AtomData::UnsignedInteger(n) => Some(i64::from(*n)),
        AtomData::UTF8(s) | AtomData::UTF16(s) => parse_int(s),
        _ => None,
    })
}

/// Atom names are four bytes of latin-1 — `©` fronts the classic iTunes
/// atoms — so each byte maps straight to its code point. Reading them as
/// UTF-8 would smear `©` into U+FFFD and split the key from the Dart
/// tier's spelling of the same atom.
fn fourcc_name(bytes: &[u8; 4]) -> String {
    bytes.iter().map(|&b| b as char).collect()
}

fn ilst_extra_key(ident: &AtomIdent<'_>) -> String {
    match ident {
        AtomIdent::Fourcc(cc) => fourcc_name(cc),
        AtomIdent::Freeform { mean, name } => format!("----:{mean}:{name}"),
    }
}

/// The ilst walk both audio and video share: pictures, freeform
/// identifiers, and the atoms that mean the same thing either side.
/// Returns true when the atom was consumed.
fn map_ilst_common(r: &mut Report, atom: &Atom<'_>) -> bool {
    match atom.ident() {
        AtomIdent::Fourcc(cc) => {
            match cc {
                b"\xa9nam" => {
                    if let Some(title) = atom_text(atom) {
                        r.set_str("title", &title);
                    }
                }
                b"\xa9day" => {
                    if let Some(date) = atom_text(atom) {
                        r.set_str("date", &date);
                    }
                }
                b"\xa9gen" | b"gnre" => {
                    if let Some(genre) = atom_text(atom) {
                        r.push_list("genres", &genre);
                    }
                }
                b"\xa9cmt" => {
                    if let Some(comment) = atom_text(atom) {
                        r.set_str("comment", &comment);
                    }
                }
                b"covr" => {
                    for data in atom.data() {
                        if let AtomData::Picture(picture) = data {
                            push_picture(r, picture);
                        }
                    }
                }
                _ => return false,
            }
            true
        }
        AtomIdent::Freeform { mean: _, name } => {
            let raw_key = ilst_extra_key(atom.ident());
            let norm = norm_key(name);
            let Some(text) = atom_text(atom) else {
                r.extra(&raw_key, atom.data().next().map(atom_value).unwrap_or(Value::Null));
                return true;
            };
            if !apply_special(r, &raw_key, &norm, &text) {
                r.extra_str(&raw_key, &text);
            }
            true
        }
    }
}

/// The audio reading of an ilst — iTunes atoms into track vocabulary.
pub fn map_ilst_audio(r: &mut Report, ilst: &Ilst) {
    if let Some(track) = ilst.track() {
        r.set_int("trackNumber", i64::from(track));
    }
    if let Some(total) = ilst.track_total() {
        r.set_int("trackTotal", i64::from(total));
    }
    if let Some(disk) = ilst.disk() {
        r.set_int("discNumber", i64::from(disk));
    }
    if let Some(total) = ilst.disk_total() {
        r.set_int("discTotal", i64::from(total));
    }
    for atom in ilst {
        if map_ilst_common(r, atom) {
            continue;
        }
        let AtomIdent::Fourcc(cc) = atom.ident() else {
            continue;
        };
        match cc {
            b"trkn" | b"disk" => {} // spoken for above
            b"\xa9ART" => {
                if let Some(artist) = atom_text(atom) {
                    r.set_str("artist", &artist);
                    r.push_list("artists", &artist);
                }
            }
            b"aART" => {
                if let Some(artist) = atom_text(atom) {
                    r.set_str("albumArtist", &artist);
                }
            }
            b"\xa9alb" => {
                if let Some(album) = atom_text(atom) {
                    r.set_str("album", &album);
                }
            }
            b"\xa9wrt" => {
                if let Some(composer) = atom_text(atom) {
                    r.push_list("composers", &composer);
                }
            }
            b"\xa9lyr" => {
                if let Some(lyrics) = atom_text(atom) {
                    r.set_str("lyrics", &lyrics);
                }
            }
            b"\xa9grp" => {
                if let Some(grouping) = atom_text(atom) {
                    r.set_str("grouping", &grouping);
                }
            }
            b"\xa9too" => {
                if let Some(encoder) = atom_text(atom) {
                    r.set_str("encoder", &encoder);
                }
            }
            b"tmpo" => {
                if let Some(bpm) = atom_int(atom) {
                    r.set_int("bpm", bpm);
                }
            }
            b"cpil" => {
                let flag = atom.data().next().is_some_and(|d| match d {
                    AtomData::Bool(b) => *b,
                    AtomData::SignedInteger(n) => *n != 0,
                    AtomData::UnsignedInteger(n) => *n != 0,
                    _ => false,
                });
                r.set_bool("compilation", flag);
            }
            b"sonm" => {
                if let Some(v) = atom_text(atom) {
                    r.set_str("sortTitle", &v);
                }
            }
            b"soar" => {
                if let Some(v) = atom_text(atom) {
                    r.set_str("sortArtist", &v);
                }
            }
            b"soal" => {
                if let Some(v) = atom_text(atom) {
                    r.set_str("sortAlbum", &v);
                }
            }
            b"soaa" => {
                if let Some(v) = atom_text(atom) {
                    r.set_str("sortAlbumArtist", &v);
                }
            }
            _ => {
                let key = ilst_extra_key(atom.ident());
                r.extra(&key, atom.data().next().map(atom_value).unwrap_or(Value::Null));
            }
        }
    }
}

/// The video reading of an ilst — show, season, episode, and the rest.
pub fn map_ilst_video(r: &mut Report, ilst: &Ilst) {
    for atom in ilst {
        if map_ilst_common(r, atom) {
            continue;
        }
        let AtomIdent::Fourcc(cc) = atom.ident() else {
            continue;
        };
        match cc {
            b"tvsh" => {
                if let Some(series) = atom_text(atom) {
                    r.set_str("series", &series);
                }
            }
            b"tvsn" => {
                if let Some(season) = atom_int(atom) {
                    r.set_int("season", season);
                }
            }
            b"tves" => {
                if let Some(episode) = atom_int(atom) {
                    r.set_int("episode", episode);
                }
            }
            b"desc" => {
                if let Some(comment) = atom_text(atom) {
                    r.set_str("comment", &comment);
                }
            }
            _ => {
                let key = ilst_extra_key(atom.ident());
                r.extra(&key, atom.data().next().map(atom_value).unwrap_or(Value::Null));
            }
        }
    }
    if let Some(date) = r.date_year() {
        r.set_int("year", date);
    }
}

pub fn map_riff_info(r: &mut Report, tag: &RiffInfoList) {
    for (key, value) in tag {
        match key.as_str() {
            "INAM" => r.set_str("title", value),
            "IART" => {
                r.set_str("artist", value);
                r.push_list("artists", value);
            }
            "IPRD" => r.set_str("album", value),
            "IGNR" => r.push_list("genres", value),
            "ICRD" => r.set_str("date", value),
            "ICMT" => r.set_str("comment", value),
            "ISFT" => r.set_str("encoder", value),
            "ITRK" | "IPRT" => set_pair(r, "trackNumber", "trackTotal", value),
            _ => r.extra_str(key, value),
        }
    }
}

pub fn map_aiff_text(r: &mut Report, tag: &AiffTextChunks) {
    if let Some(name) = &tag.name {
        r.set_str("title", name);
    }
    if let Some(author) = &tag.author {
        r.set_str("artist", author);
        r.push_list("artists", author);
    }
    if let Some(copyright) = &tag.copyright {
        r.extra_str("(c) ", copyright);
    }
    for annotation in tag.annotations.iter().flatten() {
        r.set_str("comment", annotation);
    }
    for comment in tag.comments.iter().flatten() {
        r.set_str("comment", &comment.text);
    }
}

pub fn flac_pictures(r: &mut Report, pictures: &[(Picture, lofty::picture::PictureInformation)]) {
    for (picture, _) in pictures {
        push_picture(r, picture);
    }
}
