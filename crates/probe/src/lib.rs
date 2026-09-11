//! cadence-probe: the native enrichment tier behind four C symbols.
//!
//! Dart hands over a path; this crate hands back JSON — typed fields
//! under the `MediaMetadata` names, every raw tag preserved in `extra`,
//! artwork as base64, without computing content fingerprints. The same
//! library also hashes whole files (`cadence_hash_file`): a streamed
//! SHA-256 in native code, where Dart's pure implementation crawls.
//! Malformed media can find panics in this stack, so every entry point
//! is wrapped in `catch_unwind`: the worst a bad file can do is an `err`
//! envelope. No globals live here; several Dart isolates call in at once.
//!
//! The envelope: `{"ok": {...}}` on success, `{"err": {"code", "msg"}}`
//! on anything else. See `daemon/lib/probe.dart` for
//! the reader.

mod codecs;
mod report;

use std::ffi::{c_char, CStr, CString};
use std::fmt::Write as _;
use std::fs::File;
use std::io::Read;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;

use serde_json::{json, Value};
use sha2::{Digest, Sha256};

/// Bumped when the symbols or the envelope change shape.
///
/// 1: `cadence_abi_version`, `cadence_probe_file`, `cadence_free_string`.
/// 2: adds `cadence_hash_file`.
const ABI_VERSION: u32 = 2;

/// How much of a file rides in each read while hashing: 1 MiB keeps a
/// slow card streaming without holding a movie in memory.
const HASH_CHUNK_SIZE: usize = 1024 * 1024;

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
    let outcome = codecs::probe(path, &ext);
    match outcome {
        Ok(report) => json!({ "ok": report.to_json() }),
        Err(error) => json!({ "err": { "code": error.code, "msg": error.msg } }),
    }
}

/// The file's SHA-256 as lowercase hex, streamed chunk by chunk — the
/// same identity hash `sha256OfFile` computes in Dart, answered as the
/// envelope `Value`: `{"ok": {"sha256": "…"}}`.
pub fn hash_path(path_str: &str) -> Value {
    match sha256_of_file(Path::new(path_str)) {
        Ok(hex) => json!({ "ok": { "sha256": hex } }),
        Err(error) => json!({ "err": { "code": error.code, "msg": error.msg } }),
    }
}

fn sha256_of_file(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; HASH_CHUNK_SIZE];
    loop {
        let read = match file.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => n,
            Err(err) if err.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(err) => return Err(err.into()),
        };
        hasher.update(&buffer[..read]);
    }
    let digest = hasher.finalize();
    let mut hex = String::with_capacity(digest.len() * 2);
    for byte in digest.iter() {
        write!(hex, "{byte:02x}").expect("writing to a String cannot fail");
    }
    Ok(hex)
}

fn envelope_err(code: &str, msg: &str) -> String {
    json!({ "err": { "code": code, "msg": msg } }).to_string()
}

/// Runs `answer` over the UTF-8 path behind `path`, or renders the
/// matching `badarg` envelope; a panic inside becomes a `panic`
/// envelope. The answer is handed to the caller as a NUL-terminated
/// string to release with [`cadence_free_string`].
///
/// # Safety
///
/// `path` must be a valid NUL-terminated C string, or null.
unsafe fn answer_for_path(path: *const c_char, answer: fn(&str) -> Value) -> *mut c_char {
    let rendered = catch_unwind(AssertUnwindSafe(|| {
        if path.is_null() {
            return envelope_err("badarg", "null path");
        }
        let raw = unsafe { CStr::from_ptr(path) };
        match raw.to_str() {
            Ok(path_str) => answer(path_str).to_string(),
            Err(_) => envelope_err("badarg", "path is not UTF-8"),
        }
    }))
    .unwrap_or_else(|_| envelope_err("panic", "native call panicked; see stderr"));
    match CString::new(rendered) {
        Ok(out) => out.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
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
    unsafe { answer_for_path(path, probe_path) }
}

/// Hashes the whole of `path` (NUL-terminated UTF-8) with SHA-256 and
/// returns a NUL-terminated UTF-8 JSON envelope — `{"ok": {"sha256":
/// "<lowercase hex>"}}` or `{"err": …}` — the caller must release with
/// [`cadence_free_string`]. Blocks for the length of the read: call it
/// off the event loop.
///
/// # Safety
///
/// `path` must be a valid NUL-terminated C string, or null.
#[no_mangle]
pub unsafe extern "C" fn cadence_hash_file(path: *const c_char) -> *mut c_char {
    unsafe { answer_for_path(path, hash_path) }
}

/// Releases a string minted by [`cadence_probe_file`] or
/// [`cadence_hash_file`]. Null is a no-op.
///
/// # Safety
///
/// `ptr` must be null or a pointer previously returned by
/// [`cadence_probe_file`] or [`cadence_hash_file`], and must not be used
/// again after this call.
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
        assert!(fields["musicBrainz"]["recordingId"].as_str().is_some());
        assert!(fields["musicBrainz"]["releaseId"].as_str().is_some());
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
        assert_eq!(cadence_abi_version(), 2);
    }

    /// A scratch file with `contents`, removed when dropped.
    struct Scratch(std::path::PathBuf);

    impl Scratch {
        fn with(name: &str, contents: &[u8]) -> Self {
            let path =
                std::env::temp_dir().join(format!("cadence-probe-{}-{name}", std::process::id()));
            std::fs::write(&path, contents).unwrap();
            Scratch(path)
        }

        fn path(&self) -> &str {
            self.0.to_str().unwrap()
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }

    #[test]
    fn hash_matches_the_published_vectors() {
        let empty = Scratch::with("empty", b"");
        assert_eq!(
            hash_path(empty.path())["ok"]["sha256"],
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        let abc = Scratch::with("abc", b"abc");
        assert_eq!(
            hash_path(abc.path())["ok"]["sha256"],
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn hash_streams_across_chunk_boundaries() {
        // Three chunks and a tail: the digest must not depend on how the
        // reads fall. "a" × (3 MiB + 17) has a known digest computed by
        // sha2 itself over a single update, checked against the stream.
        let size = 3 * HASH_CHUNK_SIZE + 17;
        let big = Scratch::with("big", &vec![b'a'; size]);
        let mut whole = Sha256::new();
        whole.update(vec![b'a'; size]);
        let expected: String = whole
            .finalize()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        assert_eq!(hash_path(big.path())["ok"]["sha256"], expected);
    }

    #[test]
    fn hash_of_a_missing_file_is_an_io_error() {
        let envelope = hash_path("/nonexistent/cadence/file.bin");
        assert_eq!(envelope["err"]["code"], "io");
        assert!(!envelope["err"]["msg"].as_str().unwrap().is_empty());
    }

    #[test]
    fn hash_ffi_round_trip_speaks_json() {
        let abc = Scratch::with("ffi", b"abc");
        let path = CString::new(abc.path()).unwrap();
        let raw = unsafe { cadence_hash_file(path.as_ptr()) };
        assert!(!raw.is_null());
        let text = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_owned();
        unsafe { cadence_free_string(raw) };
        let envelope: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(
            envelope["ok"]["sha256"],
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        let null = unsafe { cadence_hash_file(std::ptr::null()) };
        let text = unsafe { CStr::from_ptr(null) }.to_str().unwrap().to_owned();
        unsafe { cadence_free_string(null) };
        let envelope: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(envelope["err"]["code"], "badarg");
    }
}
