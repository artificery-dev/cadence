//! The image probe: dimensions from headers, EXIF through nom-exif —
//! HEIC included — and a DCT pHash for anything the `image` crate can
//! decode. Typed fields take the camera and the coordinates; every other
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

    if let Ok(decoded) = image::open(path) {
        r.phash64 = Some(phash(&decoded));
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
    if let Some(orientation) = exif
        .get(ExifTag::Orientation)
        .and_then(EntryValue::as_u32)
    {
        r.set_int("orientation", i64::from(orientation));
    }
    if let Some(iso) = exif
        .get(ExifTag::ISOSpeedRatings)
        .and_then(EntryValue::as_u32)
    {
        r.set_int("iso", i64::from(iso));
    }
    if let Some(exposure) = exif
        .get(ExifTag::ExposureTime)
        .and_then(EntryValue::as_f64)
    {
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
    let offset: String = rendered[19..].chars().filter(|c| !c.is_whitespace()).collect();
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

/// The pinned pHash, by hand — the same bit layout as the Dart tier's
/// `phash.dart`, and a cross-language contract like the SimHash: never
/// change it without versioning the hash kind.
///
/// The pipeline, step for step with the Dart side: grayscale under the
/// Rec. 601 weights, truncated to bytes; a 32×32 box-average resize (the
/// `Interpolation.average` arithmetic, ulp for ulp); an unnormalized 2D
/// DCT-II; the top-left 8×8 block minus its DC term; the 63 survivors
/// thresholded strictly above their median (the 32nd smallest); packed
/// MSB-first in row-major order with the DC position held at zero; 16
/// lowercase hex digits out. Decoder differences against `package:image`
/// wiggle a pixel here and there, so cross-tier hashes agree to within a
/// few bits rather than exactly — the layout is what corresponds.
fn phash(image: &image::DynamicImage) -> String {
    let rgb = image.to_rgb8();
    let (w, h) = (rgb.width() as usize, rgb.height() as usize);
    if w == 0 || h == 0 {
        return format!("{:016x}", 0u64);
    }
    let gray: Vec<u8> = rgb
        .pixels()
        .map(|p| (0.299 * f64::from(p[0]) + 0.587 * f64::from(p[1]) + 0.114 * f64::from(p[2])) as u8)
        .collect();

    let mut luma = [[0f64; 32]; 32];
    for (y, row) in luma.iter_mut().enumerate() {
        let ay1 = y * h / 32;
        let ay2 = ((y + 1) * h / 32).max(ay1 + 1);
        for (x, cell) in row.iter_mut().enumerate() {
            let ax1 = x * w / 32;
            let ax2 = ((x + 1) * w / 32).max(ax1 + 1);
            let mut sum = 0.0;
            let mut np = 0.0;
            for sy in ay1..ay2 {
                for sx in ax1..ax2 {
                    sum += f64::from(gray[sy * w + sx]);
                    np += 1.0;
                }
            }
            let inv = 1.0 / np;
            *cell = f64::from((sum * inv) as u8);
        }
    }

    let coefficients = dct_block(&luma);
    let mut ranked = coefficients[1..].to_vec();
    ranked.sort_by(f64::total_cmp);
    let median = ranked[(ranked.len() - 1) / 2];

    let mut hash = 0u64;
    for (i, coefficient) in coefficients.iter().enumerate().skip(1) {
        if *coefficient > median {
            hash |= 1 << (63 - i);
        }
    }
    format!("{hash:016x}")
}

/// The top-left 8×8 of the 2D DCT-II of the 32×32 grid, row-major —
/// separable, unnormalized, and in the Dart tier's exact loop order.
fn dct_block(luma: &[[f64; 32]; 32]) -> [f64; 64] {
    let mut cos = [[0f64; 32]; 8];
    for (k, row) in cos.iter_mut().enumerate() {
        for (i, value) in row.iter_mut().enumerate() {
            *value = ((2 * i + 1) as f64 * k as f64 * std::f64::consts::PI / 64.0).cos();
        }
    }
    let mut rows = [[0f64; 8]; 32];
    for (y, out) in rows.iter_mut().enumerate() {
        for (v, term) in out.iter_mut().enumerate() {
            let mut sum = 0.0;
            for x in 0..32 {
                sum += luma[y][x] * cos[v][x];
            }
            *term = sum;
        }
    }
    let mut out = [0f64; 64];
    for u in 0..8 {
        for v in 0..8 {
            let mut sum = 0.0;
            for (y, row) in rows.iter().enumerate() {
                sum += row[v] * cos[u][y];
            }
            out[u * 8 + v] = sum;
        }
    }
    out
}

/// The same hash for a picture that arrived as bytes — a video's cover
/// attachment, say. None when the bytes will not decode.
pub fn phash_bytes(bytes: &[u8]) -> Option<String> {
    image::load_from_memory(bytes).ok().map(|img| phash(&img))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The pinned layout holds the DC position at the top bit, always
    /// zero — and a picture with structure votes some bits on. The
    /// cross-tier agreement itself is asserted from the Dart side, in
    /// probe_test.dart, against phash.dart's own numbers.
    #[test]
    fn phash_keeps_the_dc_bit_dark() {
        let mut img = image::RgbImage::new(64, 64);
        for (x, y, pixel) in img.enumerate_pixels_mut() {
            let value = ((x * 4) ^ (y * 4)) as u8;
            *pixel = image::Rgb([value, value, value]);
        }
        let hash = phash(&image::DynamicImage::ImageRgb8(img));
        assert_eq!(hash.len(), 16);
        let bits = u64::from_str_radix(&hash, 16).unwrap();
        assert_eq!(bits >> 63, 0, "the DC position must stay zero");
        assert!(bits.count_ones() > 8, "structure should set bits");
    }
}
