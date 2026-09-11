//! The image probe: dimensions from headers, EXIF through nom-exif —
//! HEIC included. Typed fields take the camera and the coordinates; every other
//! EXIF entry keeps its tag name in `extra`.

use std::path::Path;

use nom_exif::{EntryValue, ExifTag, TagOrCode};
use serde_json::Value;

use crate::report::Report;
use crate::Result;

pub fn probe(path: &Path, _ext: &str) -> Result<Report> {
    let mut r = Report::new("image");

    if let Ok((width, height)) = image::image_dimensions(path) {
        r.set_int("width", i64::from(width));
        r.set_int("height", i64::from(height));
    }

    if let Ok(exif) = nom_exif::read_exif(path) {
        map_exif(&mut r, &exif);
    }

    Ok(r)
}

/// The typed EXIF story: camera, exposure, position, description.
fn map_exif(r: &mut Report, exif: &nom_exif::Exif) {
    let text = |tag: ExifTag| exif.get(tag).and_then(EntryValue::as_str);
    if let Some(make) = text(ExifTag::Make) {
        r.set_str("cameraMake", make);
    }
    if let Some(model) = text(ExifTag::Model) {
        r.set_str("cameraModel", model);
    }
    if let Some(lens) = text(ExifTag::LensModel) {
        r.set_str("lensModel", lens);
    }
    if let Some(description) = text(ExifTag::ImageDescription) {
        r.set_str("description", description);
    }
    if let Some(orientation) = exif.get(ExifTag::Orientation).and_then(EntryValue::as_u32) {
        r.set_int("orientation", i64::from(orientation));
    }
    if let Some(iso) = exif
        .get(ExifTag::ISOSpeedRatings)
        .and_then(EntryValue::as_u32)
    {
        r.set_int("iso", i64::from(iso));
    }
    if let Some(exposure) = exif.get(ExifTag::ExposureTime).and_then(EntryValue::as_f64) {
        r.set_f64("exposureSeconds", exposure);
    }
    if let Some(f_number) = exif.get(ExifTag::FNumber).and_then(EntryValue::as_f64) {
        r.set_f64("fNumber", f_number);
    }
    if let Some(focal) = exif.get(ExifTag::FocalLength).and_then(EntryValue::as_f64) {
        r.set_f64("focalLengthMm", focal);
    }
    if let Some(taken) = exif
        .get(ExifTag::DateTimeOriginal)
        .and_then(exif_datetime_iso)
    {
        r.set_str("takenAt", &taken);
    }
    if r.has("width") {
        // Header dimensions won; the EXIF copies stay in extra below.
    } else {
        if let Some(width) = exif
            .get(ExifTag::ExifImageWidth)
            .and_then(EntryValue::as_u32)
        {
            r.set_int("width", i64::from(width));
        }
        if let Some(height) = exif
            .get(ExifTag::ExifImageHeight)
            .and_then(EntryValue::as_u32)
        {
            r.set_int("height", i64::from(height));
        }
    }
    if let Some(gps) = exif.gps_info() {
        if let Some(latitude) = gps.latitude_decimal() {
            r.set_f64("gpsLatitude", latitude);
        }
        if let Some(longitude) = gps.longitude_decimal() {
            r.set_f64("gpsLongitude", longitude);
        }
        if let Some(altitude) = gps.altitude_meters() {
            r.set_f64("gpsAltitude", altitude);
        }
    }
    const CONSUMED: &[ExifTag] = &[
        ExifTag::Make,
        ExifTag::Model,
        ExifTag::LensModel,
        ExifTag::ImageDescription,
        ExifTag::Orientation,
        ExifTag::ISOSpeedRatings,
        ExifTag::ExposureTime,
        ExifTag::FNumber,
        ExifTag::FocalLength,
        ExifTag::DateTimeOriginal,
    ];
    for entry in exif.iter() {
        let key = match &entry.tag {
            TagOrCode::Tag(tag) if CONSUMED.contains(tag) => continue,
            TagOrCode::Tag(tag) => tag.to_string(),
            TagOrCode::Unknown(code) => format!("0x{code:04x}"),
        };
        r.extra(&key, entry_value_json(entry.value));
    }
}

/// EXIF's `2020:05:17 10:30:00` restyled as ISO 8601 so Dart's
/// `DateTime.tryParse` reads it without squinting.
fn exif_datetime_iso(value: &EntryValue) -> Option<String> {
    let rendered = match value.as_str() {
        Some(text) => text.to_owned(),
        None => value.to_string(),
    };
    let rendered = rendered.trim();
    let bytes = rendered.as_bytes();
    if bytes.len() < 19 || bytes[4] != b':' && bytes[4] != b'-' {
        return None;
    }
    let date = rendered[..10].replace(':', "-");
    let time = &rendered[11..19];
    let offset: String = rendered[19..]
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect();
    Some(format!("{date}T{time}{offset}"))
}

pub fn entry_value_json(value: &EntryValue) -> Value {
    match value {
        EntryValue::Text(text) => Value::from(text.as_str()),
        EntryValue::U8(n) => Value::from(*n),
        EntryValue::U16(n) => Value::from(*n),
        EntryValue::U32(n) => Value::from(*n),
        EntryValue::U64(n) => Value::from(*n),
        EntryValue::I8(n) => Value::from(*n),
        EntryValue::I16(n) => Value::from(*n),
        EntryValue::I32(n) => Value::from(*n),
        EntryValue::I64(n) => Value::from(*n),
        EntryValue::F32(n) => Value::from(*n),
        EntryValue::F64(n) => Value::from(*n),
        EntryValue::URational(_) | EntryValue::IRational(_) => value
            .as_f64()
            .map_or_else(|| Value::from(value.to_string()), Value::from),
        EntryValue::Undefined(bytes) => Value::from(format!("<{} bytes>", bytes.len())),
        other => Value::from(other.to_string()),
    }
}
