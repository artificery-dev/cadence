//! Media format parsers and metadata mapping helpers.

mod asf;
mod audio;
mod avi;
mod document;
mod image_probe;
mod tagmap;
mod video;

use std::path::Path;

use crate::report::Report;
use crate::{ProbeError, Result};

pub(super) fn probe(path: &Path, ext: &str) -> Result<Report> {
    match ext {
        "mp3" | "flac" | "ogg" | "oga" | "opus" | "m4a" | "m4b" | "aac" | "wav" | "aiff"
        | "aif" | "ape" | "wv" | "wma" | "mka" => audio::probe(path, ext),
        "mp4" | "m4v" | "mov" | "mkv" | "webm" | "avi" => video::probe(path, ext),
        "jpg" | "jpeg" | "png" | "gif" | "webp" | "bmp" | "tif" | "tiff" | "heic" | "heif"
        | "avif" => image_probe::probe(path, ext),
        "pdf" | "epub" => document::probe(path, ext),
        _ => Err(ProbeError::unsupported(ext)),
    }
}
