//! The hundred lines AVI asks for: `avih` for frame size and count,
//! `strh`/`strf` per stream for timing and codec fourccs. The RIFF walk
//! itself comes from the `riff` crate; this file only knows the offsets.

use std::fs::File;
use std::io::BufReader;
use std::path::Path;

use riff::Chunk;

use crate::report::Report;
use crate::{ProbeError, Result};

fn u32_at(data: &[u8], offset: usize) -> Option<u32> {
    data.get(offset..offset + 4)
        .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
}

fn u16_at(data: &[u8], offset: usize) -> Option<u16> {
    data.get(offset..offset + 2)
        .map(|b| u16::from_le_bytes([b[0], b[1]]))
}

fn fourcc_at(data: &[u8], offset: usize) -> Option<String> {
    data.get(offset..offset + 4).and_then(|b| {
        let s: String = b
            .iter()
            .filter(|c| c.is_ascii_graphic())
            .map(|c| char::from(*c).to_ascii_lowercase())
            .collect();
        (!s.is_empty()).then_some(s)
    })
}

pub fn probe(path: &Path, r: &mut Report) -> Result<()> {
    let mut stream = BufReader::new(File::open(path)?);
    let root = Chunk::read(&mut stream, 0)?;
    if root.id().as_str() != "RIFF" {
        return Err(ProbeError::parse("avi: not a RIFF file".into()));
    }

    // map_while, not filter_map: the riff iterator does not advance past
    // a chunk it failed to read, so skipping errors spins forever on a
    // truncated file. The first error ends the walk.
    let children: Vec<Chunk> = root.iter(&mut stream).map_while(|c| c.ok()).collect();
    for child in children {
        if child.id().as_str() != "LIST"
            || child.read_type(&mut stream).ok().map(|t| t.value) != Some(*b"hdrl")
        {
            continue;
        }
        let header_chunks: Vec<Chunk> = child.iter(&mut stream).map_while(|c| c.ok()).collect();
        for header in header_chunks {
            match header.id().as_str() {
                "avih" => {
                    let data = header.read_contents(&mut stream)?;
                    let micros_per_frame = u64::from(u32_at(&data, 0).unwrap_or(0));
                    let frames = u64::from(u32_at(&data, 16).unwrap_or(0));
                    if micros_per_frame > 0 {
                        r.set_f64("frameRate", 1_000_000.0 / micros_per_frame as f64);
                        if frames > 0 {
                            r.set_int("durationMs", (frames * micros_per_frame / 1000) as i64);
                        }
                    }
                    if let Some(width) = u32_at(&data, 32).filter(|w| *w > 0) {
                        r.set_int("width", i64::from(width));
                    }
                    if let Some(height) = u32_at(&data, 36).filter(|h| *h > 0) {
                        r.set_int("height", i64::from(height));
                    }
                }
                "LIST" => {
                    if header.read_type(&mut stream).ok().map(|t| t.value) != Some(*b"strl") {
                        continue;
                    }
                    stream_list(&header, &mut stream, r)?;
                }
                _ => {}
            }
        }
    }
    r.set_str("container", "AVI");
    Ok(())
}

/// One `strl`: the stream header names the kind and handler, the format
/// chunk names the codec for video and the format tag for audio.
fn stream_list(list: &Chunk, stream: &mut BufReader<File>, r: &mut Report) -> Result<()> {
    let chunks: Vec<Chunk> = list.iter(stream).map_while(|c| c.ok()).collect();
    let mut kind: Option<String> = None;
    let mut handler: Option<String> = None;
    for chunk in chunks {
        match chunk.id().as_str() {
            "strh" => {
                let data = chunk.read_contents(stream)?;
                kind = fourcc_at(&data, 0);
                handler = fourcc_at(&data, 4);
                if kind.as_deref() == Some("vids") {
                    let scale = u32_at(&data, 20).unwrap_or(0);
                    let rate = u32_at(&data, 24).unwrap_or(0);
                    if scale > 0 && rate > 0 {
                        r.set_f64("frameRate", f64::from(rate) / f64::from(scale));
                    }
                }
            }
            "strf" => {
                let data = chunk.read_contents(stream)?;
                match kind.as_deref() {
                    Some("vids") => {
                        let codec = fourcc_at(&data, 16).or_else(|| handler.clone());
                        if let Some(codec) = codec {
                            r.set_str("videoCodec", avi_codec(&codec));
                        }
                    }
                    Some("auds") => {
                        if let Some(tag) = u16_at(&data, 0) {
                            r.set_str("audioCodec", wave_format(tag));
                        }
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }
    Ok(())
}

fn avi_codec(fourcc: &str) -> &str {
    match fourcc {
        "mjpg" => "mjpeg",
        "h264" | "avc1" | "x264" => "h264",
        "xvid" | "divx" | "dx50" | "fmp4" => "mpeg4",
        other => other,
    }
}

fn wave_format(tag: u16) -> &'static str {
    match tag {
        0x0001 => "pcm",
        0x0002 => "adpcm",
        0x0050 => "mp2",
        0x0055 => "mp3",
        0x00ff | 0x1600 | 0x1610 => "aac",
        0x2000 => "ac3",
        _ => "unknown",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A truncated AVI once spun the walk forever: the riff iterator
    /// stands still on a chunk it cannot read, and skipping the error
    /// retried it for eternity. The walk must end — with whatever the
    /// header gave up before the cut — never hang.
    #[test]
    fn truncated_avi_ends_the_walk() {
        let whole = std::fs::read(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../packages/media/test/fixtures/video/mjpeg.avi"
        ))
        .expect("mjpeg.avi fixture missing");
        let dir = std::env::temp_dir();
        for (name, cut) in [
            ("cadence_avi_10.avi", whole.len() / 10),
            ("cadence_avi_50.avi", whole.len() / 2),
        ] {
            let path = dir.join(name);
            std::fs::write(&path, &whole[..cut]).unwrap();
            let mut r = Report::new("video");
            let _ = probe(&path, &mut r);
            std::fs::remove_file(&path).ok();
        }
    }
}
