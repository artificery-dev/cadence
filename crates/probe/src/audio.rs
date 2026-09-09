//! The audio probe: lofty's concrete tag types, format by format, with
//! mp4ameta filling in the one thing lofty lacks — MP4 chapters.
//!
//! Each format opens as its own lofty file struct so every dialect it
//! carries (ID3v2 beside APE beside RIFF INFO) is walked in full. The
//! technical truth rides in last from `FileProperties`, and never
//! overrides what a tag already said.

use std::fs::File;
use std::io::BufReader;
use std::path::Path;

use lofty::config::ParseOptions;
use lofty::file::AudioFile;
use lofty::mp4::Mp4Codec;
use lofty::ogg::OggPictureStorage;
use lofty::properties::FileProperties;

use crate::report::Report;
use crate::tagmap;
use crate::{ProbeError, Result};

pub fn probe(path: &Path, ext: &str) -> Result<Report> {
    let mut r = Report::new("audio");
    match ext {
        "mp3" => mp3(path, &mut r)?,
        "flac" => flac(path, &mut r)?,
        "ogg" | "oga" => vorbis(path, &mut r)?,
        "opus" => opus(path, &mut r)?,
        "m4a" | "m4b" => mp4(path, &mut r)?,
        "aac" => aac(path, &mut r)?,
        "wav" => wav(path, &mut r)?,
        "aiff" | "aif" => aiff(path, &mut r)?,
        "ape" => ape(path, &mut r)?,
        "wv" => wavpack(path, &mut r)?,
        "mka" => crate::video::probe_mka_audio(path, &mut r)?,
        "wma" => crate::asf::probe(path, &mut r)?,
        _ => return Err(ProbeError::unsupported(ext)),
    }
    Ok(r)
}

fn reader(path: &Path) -> Result<BufReader<File>> {
    Ok(BufReader::new(File::open(path)?))
}

/// Duration, bitrate, sample rate, channels, bit depth — the stream's own
/// word on itself.
fn set_props(r: &mut Report, props: &FileProperties, codec: &str, lossless: bool) {
    let millis = props.duration().as_millis();
    if millis > 0 {
        r.set_int("durationMs", millis as i64);
    }
    if let Some(bitrate) = props.audio_bitrate().or_else(|| props.overall_bitrate()) {
        r.set_int("bitrateKbps", i64::from(bitrate));
    }
    if let Some(rate) = props.sample_rate() {
        r.set_int("sampleRateHz", i64::from(rate));
    }
    if let Some(channels) = props.channels() {
        r.set_int("channels", i64::from(channels));
    }
    if let Some(depth) = props.bit_depth() {
        r.set_int("bitsPerSample", i64::from(depth));
    }
    r.set_str("codec", codec);
    r.set_bool("lossless", lossless);
}

fn mp3(path: &Path, r: &mut Report) -> Result<()> {
    let file = lofty::mpeg::MpegFile::read_from(&mut reader(path)?, ParseOptions::new())?;
    if let Some(tag) = file.id3v2() {
        tagmap::map_id3v2(r, tag);
    }
    if let Some(tag) = file.ape() {
        tagmap::map_ape(r, tag);
    }
    if let Some(tag) = file.id3v1() {
        tagmap::map_id3v1(r, tag);
    }
    set_props(r, &file.properties().clone().into(), "MP3", false);
    Ok(())
}

fn flac(path: &Path, r: &mut Report) -> Result<()> {
    let file = lofty::flac::FlacFile::read_from(&mut reader(path)?, ParseOptions::new())?;
    if let Some(tag) = file.vorbis_comments() {
        tagmap::map_vorbis(r, tag);
        tagmap::flac_pictures(r, tag.pictures());
    }
    if let Some(tag) = file.id3v2() {
        tagmap::map_id3v2(r, tag);
    }
    tagmap::flac_pictures(r, file.pictures());
    set_props(r, &file.properties().clone().into(), "FLAC", true);
    Ok(())
}

fn vorbis(path: &Path, r: &mut Report) -> Result<()> {
    let file = lofty::ogg::VorbisFile::read_from(&mut reader(path)?, ParseOptions::new())?;
    tagmap::map_vorbis(r, file.vorbis_comments());
    tagmap::flac_pictures(r, file.vorbis_comments().pictures());
    set_props(r, &file.properties().clone().into(), "Vorbis", false);
    Ok(())
}

fn opus(path: &Path, r: &mut Report) -> Result<()> {
    let file = lofty::ogg::OpusFile::read_from(&mut reader(path)?, ParseOptions::new())?;
    tagmap::map_vorbis(r, file.vorbis_comments());
    tagmap::flac_pictures(r, file.vorbis_comments().pictures());
    set_props(r, &file.properties().clone().into(), "Opus", false);
    Ok(())
}

fn mp4(path: &Path, r: &mut Report) -> Result<()> {
    let file = lofty::mp4::Mp4File::read_from(&mut reader(path)?, ParseOptions::new())?;
    if let Some(ilst) = file.ilst() {
        tagmap::map_ilst_audio(r, ilst);
    }
    chapters(path, r);
    let (codec, lossless) = match file.properties().codec() {
        Some(Mp4Codec::AAC) => ("AAC", false),
        Some(Mp4Codec::ALAC) => ("ALAC", true),
        Some(Mp4Codec::MP3) => ("MP3", false),
        Some(Mp4Codec::FLAC) => ("FLAC", true),
        _ => ("MP4", false),
    };
    set_props(r, &file.properties().clone().into(), codec, lossless);
    Ok(())
}

/// mp4ameta reads both chapter styles — the `chpl` list and the chapter
/// track — preferring the list. lofty carries no MP4 chapters at all.
pub fn chapters(path: &Path, r: &mut Report) {
    let Ok(tag) = mp4ameta::Tag::read_from_path(path) else {
        return;
    };
    for chapter in tag.userdata.chapters() {
        r.push_chapter(&chapter.title, chapter.start.as_millis() as i64);
    }
}

fn aac(path: &Path, r: &mut Report) -> Result<()> {
    let file = lofty::aac::AacFile::read_from(&mut reader(path)?, ParseOptions::new())?;
    if let Some(tag) = file.id3v2() {
        tagmap::map_id3v2(r, tag);
    }
    if let Some(tag) = file.id3v1() {
        tagmap::map_id3v1(r, tag);
    }
    set_props(r, &file.properties().clone().into(), "AAC", false);
    Ok(())
}

fn wav(path: &Path, r: &mut Report) -> Result<()> {
    let file = lofty::iff::wav::WavFile::read_from(&mut reader(path)?, ParseOptions::new())?;
    if let Some(tag) = file.id3v2() {
        tagmap::map_id3v2(r, tag);
    }
    if let Some(tag) = file.riff_info() {
        tagmap::map_riff_info(r, tag);
    }
    set_props(r, &file.properties().clone().into(), "PCM", true);
    Ok(())
}

fn aiff(path: &Path, r: &mut Report) -> Result<()> {
    let file = lofty::iff::aiff::AiffFile::read_from(&mut reader(path)?, ParseOptions::new())?;
    if let Some(tag) = file.id3v2() {
        tagmap::map_id3v2(r, tag);
    }
    if let Some(tag) = file.text_chunks() {
        tagmap::map_aiff_text(r, tag);
    }
    set_props(r, &file.properties().clone().into(), "PCM", true);
    Ok(())
}

fn ape(path: &Path, r: &mut Report) -> Result<()> {
    let file = lofty::ape::ApeFile::read_from(&mut reader(path)?, ParseOptions::new())?;
    if let Some(tag) = file.ape() {
        tagmap::map_ape(r, tag);
    }
    if let Some(tag) = file.id3v2() {
        tagmap::map_id3v2(r, tag);
    }
    if let Some(tag) = file.id3v1() {
        tagmap::map_id3v1(r, tag);
    }
    set_props(r, &file.properties().clone().into(), "Monkey's Audio", true);
    Ok(())
}

fn wavpack(path: &Path, r: &mut Report) -> Result<()> {
    let file = lofty::wavpack::WavPackFile::read_from(&mut reader(path)?, ParseOptions::new())?;
    if let Some(tag) = file.ape() {
        tagmap::map_ape(r, tag);
    }
    if let Some(tag) = file.id3v1() {
        tagmap::map_id3v1(r, tag);
    }
    set_props(r, &file.properties().clone().into(), "WavPack", true);
    Ok(())
}
