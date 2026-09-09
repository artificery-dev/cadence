//! A minimal ASF header walk — the only permissive road into WMA.
//!
//! Three objects carry everything worth having: File Properties for the
//! duration, Content Description for the classic five strings, and the
//! Extended Content Description for the `WM/` key-value pairs, which fold
//! into the same dialect table the Vorbis keys use.

use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Path;

use crate::report::Report;
use super::tagmap::apply_vorbis_key;
use crate::{ProbeError, Result};

const HEADER_OBJECT: [u8; 16] = [
    0x30, 0x26, 0xb2, 0x75, 0x8e, 0x66, 0xcf, 0x11, 0xa6, 0xd9, 0x00, 0xaa, 0x00, 0x62, 0xce, 0x6c,
];
const FILE_PROPERTIES: [u8; 16] = [
    0xa1, 0xdc, 0xab, 0x8c, 0x47, 0xa9, 0xcf, 0x11, 0x8e, 0xe4, 0x00, 0xc0, 0x0c, 0x20, 0x53, 0x65,
];
const CONTENT_DESCRIPTION: [u8; 16] = [
    0x33, 0x26, 0xb2, 0x75, 0x8e, 0x66, 0xcf, 0x11, 0xa6, 0xd9, 0x00, 0xaa, 0x00, 0x62, 0xce, 0x6c,
];
const EXTENDED_CONTENT: [u8; 16] = [
    0x40, 0xa4, 0xd0, 0xd2, 0x07, 0xe3, 0xd2, 0x11, 0x97, 0xf0, 0x00, 0xa0, 0xc9, 0x5e, 0xa8, 0x50,
];
const STREAM_PROPERTIES: [u8; 16] = [
    0x91, 0x07, 0xdc, 0xb7, 0xb7, 0xa9, 0xcf, 0x11, 0x8e, 0xe6, 0x00, 0xc0, 0x0c, 0x20, 0x53, 0x65,
];
const AUDIO_MEDIA: [u8; 16] = [
    0x40, 0x9e, 0x69, 0xf8, 0x4d, 0x5b, 0xcf, 0x11, 0xa8, 0xfd, 0x00, 0x80, 0x5f, 0x5c, 0x44, 0x2b,
];

fn u16_at(data: &[u8], at: usize) -> Option<u16> {
    data.get(at..at + 2)
        .map(|b| u16::from_le_bytes([b[0], b[1]]))
}

fn u32_at(data: &[u8], at: usize) -> Option<u32> {
    data.get(at..at + 4)
        .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
}

fn u64_at(data: &[u8], at: usize) -> Option<u64> {
    data.get(at..at + 8).map(|b| {
        u64::from_le_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]])
    })
}

/// UTF-16LE with the trailing NUL ASF loves, rendered as a Rust string.
fn utf16le(data: &[u8]) -> String {
    let units: Vec<u16> = data
        .chunks_exact(2)
        .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
        .collect();
    String::from_utf16_lossy(&units)
        .trim_end_matches('\0')
        .to_owned()
}

pub fn probe(path: &Path, r: &mut Report) -> Result<()> {
    let mut reader = BufReader::new(File::open(path)?);
    let mut header = [0u8; 30];
    reader.read_exact(&mut header)?;
    if header[..16] != HEADER_OBJECT {
        return Err(ProbeError::parse("asf: not an ASF header".into()));
    }
    let object_count = u32_at(&header, 24).unwrap_or(0);

    for _ in 0..object_count {
        let mut object_header = [0u8; 24];
        if reader.read_exact(&mut object_header).is_err() {
            break;
        }
        let size = u64_at(&object_header, 16).unwrap_or(0);
        if size < 24 || size > 16 * 1024 * 1024 {
            break;
        }
        let mut data = vec![0u8; (size - 24) as usize];
        if reader.read_exact(&mut data).is_err() {
            break;
        }
        let guid: [u8; 16] = object_header[..16].try_into().unwrap();
        match guid {
            FILE_PROPERTIES => file_properties(&data, r),
            CONTENT_DESCRIPTION => content_description(&data, r),
            EXTENDED_CONTENT => extended_content(&data, r),
            STREAM_PROPERTIES => stream_properties(&data, r),
            _ => {}
        }
    }
    r.set_str("codec", "WMA");
    r.set_bool("lossless", false);
    Ok(())
}

fn file_properties(data: &[u8], r: &mut Report) {
    let play_duration = u64_at(data, 40).unwrap_or(0) / 10_000;
    let preroll = u64_at(data, 56).unwrap_or(0);
    if play_duration > preroll && play_duration > 0 {
        r.set_int("durationMs", (play_duration - preroll) as i64);
    }
}

/// The five fixed strings: title, author, copyright, description, rating.
fn content_description(data: &[u8], r: &mut Report) {
    let mut lengths = [0usize; 5];
    for (i, length) in lengths.iter_mut().enumerate() {
        *length = u16_at(data, i * 2).unwrap_or(0) as usize;
    }
    let mut at = 10;
    for (i, length) in lengths.into_iter().enumerate() {
        let Some(bytes) = data.get(at..at + length) else {
            return;
        };
        let text = utf16le(bytes);
        if !text.is_empty() {
            match i {
                0 => r.set_str("title", &text),
                1 => {
                    r.set_str("artist", &text);
                    r.push_list("artists", &text);
                }
                2 => r.extra_str("Copyright", &text),
                3 => r.set_str("comment", &text),
                4 => r.extra_str("Rating", &text),
                _ => {}
            }
        }
        at += length;
    }
}

/// `WM/` pairs, translated into the shared dialect table.
fn extended_content(data: &[u8], r: &mut Report) {
    let count = u16_at(data, 0).unwrap_or(0);
    let mut at = 2;
    for _ in 0..count {
        let Some(name_len) = u16_at(data, at).map(usize::from) else {
            return;
        };
        at += 2;
        let Some(name_bytes) = data.get(at..at + name_len) else {
            return;
        };
        let name = utf16le(name_bytes);
        at += name_len;
        let value_type = u16_at(data, at).unwrap_or(0);
        let Some(value_len) = u16_at(data, at + 2).map(usize::from) else {
            return;
        };
        at += 4;
        let Some(value_bytes) = data.get(at..at + value_len) else {
            return;
        };
        at += value_len;
        let value = match value_type {
            0 => utf16le(value_bytes),
            2 => u32_at(value_bytes, 0).map(|v| v != 0).unwrap_or(false).to_string(),
            3 => u32_at(value_bytes, 0).unwrap_or(0).to_string(),
            4 => u64_at(value_bytes, 0).unwrap_or(0).to_string(),
            5 => u16_at(value_bytes, 0).unwrap_or(0).to_string(),
            _ => continue,
        };
        if value.is_empty() {
            continue;
        }
        match name.as_str() {
            "WM/AlbumTitle" => apply_vorbis_key(r, "ALBUM", &value),
            "WM/AlbumArtist" => apply_vorbis_key(r, "ALBUMARTIST", &value),
            "WM/Genre" => apply_vorbis_key(r, "GENRE", &value),
            "WM/TrackNumber" => apply_vorbis_key(r, "TRACKNUMBER", &value),
            "WM/Year" => apply_vorbis_key(r, "DATE", &value),
            "WM/Composer" => apply_vorbis_key(r, "COMPOSER", &value),
            "WM/Publisher" => apply_vorbis_key(r, "LABEL", &value),
            "WM/Lyrics" => apply_vorbis_key(r, "LYRICS", &value),
            "WM/BeatsPerMinute" => apply_vorbis_key(r, "BPM", &value),
            _ => r.extra_str(&name, &value),
        }
    }
}

/// The audio stream's WAVEFORMATEX: sample rate, channels, byte rate.
fn stream_properties(data: &[u8], r: &mut Report) {
    if data.get(..16) != Some(&AUDIO_MEDIA) {
        return;
    }
    // Stream type (16) + error correction type (16) + time offset (8)
    // + data lengths (10) => the format block starts at 54.
    let format = &data[54.min(data.len())..];
    if let Some(channels) = u16_at(format, 2) {
        r.set_int("channels", i64::from(channels));
    }
    if let Some(rate) = u32_at(format, 4) {
        r.set_int("sampleRateHz", i64::from(rate));
    }
    if let Some(byte_rate) = u32_at(format, 8) {
        r.set_int("bitrateKbps", i64::from(byte_rate) * 8 / 1000);
    }
}
