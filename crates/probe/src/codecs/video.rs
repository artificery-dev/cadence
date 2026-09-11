//! The video probe: MP4 structure through re_mp4 with lofty reading the
//! ilst, Matroska through the matroska crate, AVI through a short RIFF
//! walk. Attachments and cover atoms come out as artwork.

use std::fs::File;
use std::io::BufReader;
use std::path::Path;

use lofty::config::ParseOptions;
use lofty::file::AudioFile;
use matroska::{Settings, TagValue, Tracktype};

use super::image_probe::entry_value_json;
use super::tagmap;
use crate::report::Report;
use crate::{ProbeError, Result};

pub fn probe(path: &Path, ext: &str) -> Result<Report> {
    let mut r = Report::new("video");
    match ext {
        "mp4" | "m4v" | "mov" => mp4(path, &mut r, ext)?,
        "mkv" | "webm" => mkv(path, &mut r, ext)?,
        "avi" => super::avi::probe(path, &mut r)?,
        _ => return Err(ProbeError::unsupported(ext)),
    }
    Ok(r)
}

fn mp4(path: &Path, r: &mut Report, ext: &str) -> Result<()> {
    let file = File::open(path)?;
    let size = file.metadata()?.len();
    let mp4 = re_mp4::Mp4::read(BufReader::new(file), size)
        .map_err(|e| ProbeError::parse(format!("mp4: {e}")))?;

    let mvhd = &mp4.moov.mvhd;
    if mvhd.timescale > 0 && mvhd.duration > 0 {
        r.set_int(
            "durationMs",
            (mvhd.duration as i128 * 1000 / mvhd.timescale as i128) as i64,
        );
    }
    for track in mp4.tracks().values() {
        match track.kind {
            Some(re_mp4::TrackKind::Video) => {
                if track.width > 0 {
                    r.set_int("width", i64::from(track.width));
                }
                if track.height > 0 {
                    r.set_int("height", i64::from(track.height));
                }
                if let Some(codec) = track.codec_string(&mp4) {
                    r.set_str("videoCodec", codec.split('.').next().unwrap_or(&codec));
                }
                if track.timescale > 0 && track.duration > 0 && !track.samples.is_empty() {
                    let seconds = track.duration as f64 / track.timescale as f64;
                    r.set_f64("frameRate", track.samples.len() as f64 / seconds);
                }
            }
            Some(re_mp4::TrackKind::Audio) => {
                if let Some(codec) = track.codec_string(&mp4) {
                    r.set_str("audioCodec", codec.split('.').next().unwrap_or(&codec));
                }
            }
            Some(re_mp4::TrackKind::Subtitle) => {
                let language = &track.trak(&mp4).mdia.mdhd.language;
                if !language.is_empty() && language != "und" {
                    r.push_list("subtitleLanguages", language);
                }
            }
            None => {}
        }
    }

    // lofty's MP4 reader speaks ilst fluently on video files too —
    // properties stay off, since a video-only MP4 has no audio stream
    // for it to measure.
    if let Ok(tagged) = lofty::mp4::Mp4File::read_from(
        &mut BufReader::new(File::open(path)?),
        ParseOptions::new().read_properties(false),
    ) {
        if let Some(ilst) = tagged.ilst() {
            tagmap::map_ilst_video(r, ilst);
        }
    }
    super::audio::chapters(path, r);
    track_extras(path, r);
    r.set_str(
        "container",
        match ext {
            "mov" => "QuickTime",
            "m4v" => "M4V",
            _ => "MP4",
        },
    );
    Ok(())
}

fn mkv(path: &Path, r: &mut Report, ext: &str) -> Result<()> {
    let m = matroska::open(path).map_err(|e| ProbeError::parse(format!("matroska: {e}")))?;
    if let Some(title) = &m.info.title {
        r.set_str("title", title);
    }
    if let Some(duration) = m.info.duration {
        r.set_int("durationMs", duration.as_millis() as i64);
    }
    for track in &m.tracks {
        match track.tracktype {
            Tracktype::Video => {
                if let Settings::Video(video) = &track.settings {
                    r.set_int("width", video.pixel_width as i64);
                    r.set_int("height", video.pixel_height as i64);
                }
                r.set_str("videoCodec", mkv_codec(&track.codec_id));
                if let Some(frame) = track.default_duration {
                    let seconds = frame.as_secs_f64();
                    if seconds > 0.0 {
                        r.set_f64("frameRate", 1.0 / seconds);
                    }
                }
            }
            Tracktype::Audio => r.set_str("audioCodec", mkv_codec(&track.codec_id)),
            Tracktype::Subtitle => {
                let language = track
                    .language
                    .as_ref()
                    .map_or_else(|| "und".to_owned(), |l| l.to_string());
                if language != "und" {
                    r.push_list("subtitleLanguages", &language);
                }
            }
            _ => {}
        }
    }
    map_mkv_tags(r, &m);
    for edition in m.chapters.iter().filter(|e| !e.hidden).take(1) {
        for chapter in &edition.chapters {
            let title = chapter
                .display
                .first()
                .map_or("", |display| display.string.as_str());
            r.push_chapter(title, chapter.time_start.as_millis() as i64);
        }
    }
    for attachment in &m.attachments {
        if attachment.mime_type.starts_with("image/") {
            r.push_artwork(&attachment.mime_type, &attachment.data, "embedded");
        }
    }
    track_extras(path, r);
    r.set_str("container", if ext == "webm" { "WebM" } else { "Matroska" });
    Ok(())
}

/// A Matroska file wearing its audio hat — `.mka` — read for the audio
/// shape: title, duration, and the stream's own numbers.
pub fn probe_mka_audio(path: &Path, r: &mut Report) -> Result<()> {
    let m = matroska::open(path).map_err(|e| ProbeError::parse(format!("matroska: {e}")))?;
    if let Some(title) = &m.info.title {
        r.set_str("title", title);
    }
    if let Some(duration) = m.info.duration {
        r.set_int("durationMs", duration.as_millis() as i64);
    }
    if let Some(track) = m
        .tracks
        .iter()
        .find(|track| track.tracktype == Tracktype::Audio)
    {
        r.set_str("codec", mkv_codec(&track.codec_id));
        if let Settings::Audio(audio) = &track.settings {
            if audio.sample_rate > 0.0 {
                r.set_int("sampleRateHz", audio.sample_rate as i64);
            }
            if audio.channels > 0 {
                r.set_int("channels", audio.channels as i64);
            }
            if let Some(depth) = audio.bit_depth {
                r.set_int("bitsPerSample", depth as i64);
            }
        }
    }
    map_mkv_tags(r, &m);
    for attachment in &m.attachments {
        if attachment.mime_type.starts_with("image/") {
            r.push_artwork(&attachment.mime_type, &attachment.data, "embedded");
        }
    }
    Ok(())
}

/// SimpleTag names into the shape's vocabulary; strangers keep their
/// Matroska names in `extra`. ARTIST and ALBUM are audio vocabulary —
/// typed only for an `.mka`, since the video shape has no field for them
/// and the facade would drop the value on the floor; on video they keep
/// their Matroska names in `extra` instead.
fn map_mkv_tags(r: &mut Report, m: &matroska::Matroska) {
    for tag in &m.tags {
        for simple in &tag.simple {
            let Some(TagValue::String(value)) = &simple.value else {
                continue;
            };
            apply_mkv_tag(r, &simple.name, value);
        }
    }
    if let Some(year) = r.date_year() {
        r.set_int("year", year);
    }
}

fn apply_mkv_tag(r: &mut Report, name: &str, value: &str) {
    match name.to_ascii_uppercase().as_str() {
        "TITLE" => r.set_str("title", value),
        "DATE_RELEASED" | "DATE" => r.set_str("date", value),
        "GENRE" => r.push_list("genres", value),
        "COMMENT" | "DESCRIPTION" => r.set_str("comment", value),
        "ARTIST" if r.is_kind("audio") => {
            r.set_str("artist", value);
            r.push_list("artists", value);
        }
        "ALBUM" if r.is_kind("audio") => r.set_str("album", value),
        _ => r.extra_str(name, value),
    }
}

/// nom-exif's read of the container — camera, creation date, GPS — all of
/// it stays raw in `extra`; a video shape has no typed home for it.
fn track_extras(path: &Path, r: &mut Report) {
    let Ok(info) = nom_exif::read_track(path) else {
        return;
    };
    for (tag, value) in info.iter() {
        r.extra(&format!("{tag:?}"), entry_value_json(value));
    }
}

fn mkv_codec(id: &str) -> &str {
    match id {
        "V_MPEG4/ISO/AVC" => "h264",
        "V_MPEGH/ISO/HEVC" => "hevc",
        "V_VP8" => "vp8",
        "V_VP9" => "vp9",
        "V_AV1" => "av1",
        "V_MPEG4/ISO/ASP" => "mpeg4",
        "A_AAC" => "aac",
        "A_OPUS" => "opus",
        "A_VORBIS" => "vorbis",
        "A_MPEG/L3" => "mp3",
        "A_FLAC" => "flac",
        "A_AC3" => "ac3",
        "A_EAC3" => "eac3",
        "A_DTS" => "dts",
        "A_TRUEHD" => "truehd",
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ARTIST and ALBUM belong to the audio shape; a video report has no
    /// field for them, so typing them there hands the facade values it
    /// silently discards. Raw in `extra` they survive.
    #[test]
    fn artist_types_for_audio_and_stays_raw_for_video() {
        let mut video = Report::new("video");
        apply_mkv_tag(&mut video, "ARTIST", "The Band");
        apply_mkv_tag(&mut video, "ALBUM", "The Record");
        apply_mkv_tag(&mut video, "TITLE", "Tagged Film");
        let ok = video.to_json();
        assert!(ok["fields"].get("artist").is_none());
        assert!(ok["fields"].get("album").is_none());
        assert_eq!(ok["fields"]["title"], "Tagged Film");
        assert_eq!(ok["extra"]["ARTIST"], "The Band");
        assert_eq!(ok["extra"]["ALBUM"], "The Record");

        let mut audio = Report::new("audio");
        apply_mkv_tag(&mut audio, "ARTIST", "The Band");
        apply_mkv_tag(&mut audio, "ALBUM", "The Record");
        let ok = audio.to_json();
        assert_eq!(ok["fields"]["artist"], "The Band");
        assert_eq!(ok["fields"]["artists"][0], "The Band");
        assert_eq!(ok["fields"]["album"], "The Record");
    }
}
