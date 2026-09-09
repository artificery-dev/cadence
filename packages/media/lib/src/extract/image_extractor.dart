import '../filesystem.dart';

import 'dart:typed_data';

import 'package:exif_reader/exif_reader.dart';
import 'package:image/image.dart' as img;
import 'package:image_size_getter/image_size_getter.dart';
import 'package:iso_base_media/iso_base_media.dart';
import 'package:random_access_source/random_access_source.dart';

import '../database/database.dart';
import '../kinds.dart';
import '../metadata.dart';
import 'extractor.dart';
import 'format.dart';
import 'phash.dart';

/// The pure-Dart image tier.
///
/// Dimensions come from headers, not decodes, wherever a header will say:
/// `image_size_getter` for JPEG/PNG/GIF/WebP/BMP, `package:image`'s
/// `startDecode` for TIFF, and the `ispe` box for the HEIF family. The
/// numbers are the encoded grid — [ImageMetadata.orientation] says which
/// way to hold it. EXIF supplies the camera, the shot, the place, and the
/// moment; every tag it read that found no typed field lands in `extra`,
/// stringified. When the file decodes at all, its pHash rides out in
/// [ExtractionResult.hashes] and a thumbnail rides in the artwork list.
class ImageExtractor implements MetadataExtractor {
  const ImageExtractor({this.fileSystem});
  final FileSystem? fileSystem;

  @override
  bool handles(MediaKind kind, String extension) => kind == MediaKind.image;

  @override
  Future<ExtractionResult?> extract(String path, MediaKind kind) =>
      withMediaFileSystem(
        fileSystem ?? mediaFileSystem,
        () => _extractScoped(path, kind),
      );

  Future<ExtractionResult?> _extractScoped(String path, MediaKind kind) async {
    if (kind != MediaKind.image) return null;
    final bytes = await mediaFileSystem.file(path).readAsBytes();

    ExifData? exif;
    try {
      exif = await readExifFromBytes(bytes);
    } catch (_) {
      exif = null;
    }

    img.Image? decoded;
    try {
      decoded = img.decodeImage(bytes);
    } catch (_) {
      decoded = null;
    }

    var dimensions = await _dimensions(path, extensionOf(path), bytes);
    if (dimensions == null && decoded != null) {
      dimensions = (decoded.width, decoded.height);
    }

    ExtractedArtwork? thumbnail;
    try {
      thumbnail = decoded == null ? null : _thumbnailOf(decoded, 256);
    } catch (_) {
      thumbnail = null;
    }

    return ExtractionResult(
      metadata: _metadata(exif, dimensions),
      artwork: [?thumbnail],
      hashes: {
        if (decoded != null) HashKind.perceptual: perceptualHashOf(decoded),
      },
    );
  }

  /// Width and height straight from the header, or null when the header
  /// keeps quiet and the caller must fall back to a decode.
  Future<(int, int)?> _dimensions(
    String path,
    String extension,
    Uint8List bytes,
  ) async {
    if (const {'heic', 'heif', 'avif'}.contains(extension)) {
      return _ispeDimensions(path);
    }
    if (extension == 'tif' || extension == 'tiff') {
      final info = img.TiffDecoder().startDecode(bytes);
      return info == null ? null : (info.width, info.height);
    }
    try {
      final size = ImageSizeGetter.getSizeResult(MemoryInput(bytes)).size;
      return (size.width, size.height);
    } catch (_) {
      return null;
    }
  }

  /// The HEIF family stores its pixel grid in an `ispe` property box —
  /// `meta` → `iprp` → `ipco` → `ispe`, then width and height as two
  /// big-endian uint32s past the full-box header. No codec required.
  Future<(int, int)?> _ispeDimensions(String path) async {
    final FileRASource src;
    try {
      src = await FileRASource.loadFile(mediaFileSystem.file(path));
    } catch (_) {
      return null;
    }
    try {
      final ispe = await ISOBox.createRootBox().getChildByTypePath(src, const [
        'meta',
        'iprp',
        'ipco',
        'ispe',
      ]);
      if (ispe == null) return null;
      final data = await ispe.extractData(src);
      if (data.length < 8) return null;
      final view = ByteData.sublistView(data);
      return (view.getUint32(0), view.getUint32(4));
    } catch (_) {
      return null;
    } finally {
      await src.close();
    }
  }

  ImageMetadata _metadata(ExifData? exif, (int, int)? dimensions) {
    final tags = exif?.tags ?? const <String, IfdTag>{};

    var altitude = _rational(tags['GPS GPSAltitude']);
    if (altitude != null && _int(tags['GPS GPSAltitudeRef']) == 1) {
      altitude = -altitude;
    }

    final extra = <String, Object?>{};
    for (final MapEntry(:key, :value) in tags.entries) {
      if (_typedTags.contains(key) || _plumbingTags.contains(key)) continue;
      final printable = value.printable.trim();
      if (printable.isEmpty) continue;
      extra[key] = printable.length > _extraValueCap
          ? String.fromCharCodes(printable.runes.take(_extraValueCap))
          : printable;
      if (extra.length >= _extraEntryCap) break;
    }

    return ImageMetadata(
      takenAt: _exifDateTime(tags['EXIF DateTimeOriginal']),
      width: dimensions?.$1,
      height: dimensions?.$2,
      cameraMake: _string(tags['Image Make']),
      cameraModel: _string(tags['Image Model']),
      lensModel: _string(tags['EXIF LensModel']),
      orientation: _int(tags['Image Orientation']),
      iso: _int(tags['EXIF ISOSpeedRatings']),
      exposureSeconds: _rational(tags['EXIF ExposureTime']),
      fNumber: _rational(tags['EXIF FNumber']),
      focalLengthMm: _rational(tags['EXIF FocalLength']),
      gpsLatitude: _coordinate(
        tags['GPS GPSLatitude'],
        tags['GPS GPSLatitudeRef'],
        'S',
      ),
      gpsLongitude: _coordinate(
        tags['GPS GPSLongitude'],
        tags['GPS GPSLongitudeRef'],
        'W',
      ),
      gpsAltitude: altitude,
      description: _string(tags['Image ImageDescription']),
      extra: extra,
    );
  }
}

/// Renders a JPEG thumbnail from encoded image [bytes]: decode, bake the
/// EXIF orientation in, shrink until the longest side fits [longestSide]
/// (never up), encode at quality 80. Null when nothing could decode the
/// bytes — the caller treats that as "no thumbnail", not an error.
ExtractedArtwork? renderThumbnail(List<int> bytes, {int longestSide = 256}) {
  try {
    final decoded = img.decodeImage(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );
    return decoded == null ? null : _thumbnailOf(decoded, longestSide);
  } catch (_) {
    return null;
  }
}

ExtractedArtwork _thumbnailOf(img.Image decoded, int longestSide) {
  var image = decoded;
  final orientation = image.exif.imageIfd.orientation;
  if (image.exif.imageIfd.hasOrientation && orientation != 1) {
    image = img.bakeOrientation(image);
  }
  if (image.width > longestSide || image.height > longestSide) {
    image = image.width >= image.height
        ? img.copyResize(
            image,
            width: longestSide,
            interpolation: img.Interpolation.average,
          )
        : img.copyResize(
            image,
            height: longestSide,
            interpolation: img.Interpolation.average,
          );
  }
  return ExtractedArtwork(
    bytes: img.encodeJpg(image, quality: 80),
    mime: 'image/jpeg',
    role: ArtworkRole.thumbnail,
  );
}

/// EXIF keys that land in typed fields — kept out of `extra`.
const Set<String> _typedTags = {
  'Image Make',
  'Image Model',
  'Image Orientation',
  'Image ImageDescription',
  'EXIF LensModel',
  'EXIF ISOSpeedRatings',
  'EXIF ExposureTime',
  'EXIF FNumber',
  'EXIF FocalLength',
  'EXIF DateTimeOriginal',
  'GPS GPSLatitude',
  'GPS GPSLatitudeRef',
  'GPS GPSLongitude',
  'GPS GPSLongitudeRef',
  'GPS GPSAltitude',
  'GPS GPSAltitudeRef',
};

/// Structural pointers and embedded preview blobs — noise, not knowledge.
const Set<String> _plumbingTags = {
  'Image ExifOffset',
  'Image GPSInfo',
  'EXIF InteroperabilityOffset',
  'JPEGThumbnail',
  'TIFFThumbnail',
};

const int _extraValueCap = 160;
const int _extraEntryCap = 128;

String? _string(IfdTag? tag) {
  final printable = tag?.printable.trim();
  return printable == null || printable.isEmpty ? null : printable;
}

int? _int(IfdTag? tag) =>
    tag == null || tag.values.length == 0 ? null : tag.values.firstAsInt();

double? _rational(IfdTag? tag) {
  final values = tag?.values.toList();
  if (values == null || values.isEmpty) return null;
  return _toDouble(values.first);
}

double? _toDouble(Object? value) => switch (value) {
  Ratio(:final numerator, :final denominator) when denominator != 0 =>
    numerator / denominator,
  final num number => number.toDouble(),
  _ => null,
};

/// EXIF writes moments as `YYYY:MM:DD HH:MM:SS` — colons all the way down,
/// so [DateTime.parse] wants no part of it. Parsed by hand; placeholder
/// dates (`0000:00:00 …`) come back null.
DateTime? _exifDateTime(IfdTag? tag) {
  final printable = tag?.printable.trim();
  if (printable == null) return null;
  final match = RegExp(
    r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})',
  ).firstMatch(printable);
  if (match == null) return DateTime.tryParse(printable);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  return DateTime(
    int.parse(match[1]!),
    month,
    day,
    int.parse(match[4]!),
    int.parse(match[5]!),
    int.parse(match[6]!),
  );
}

/// Degrees, minutes, seconds → signed decimal degrees, negative when the
/// hemisphere ref matches [negativeRef] (`S` for latitude, `W` for
/// longitude).
double? _coordinate(IfdTag? value, IfdTag? ref, String negativeRef) {
  final parts = value?.values.toList();
  if (parts == null || parts.isEmpty) return null;
  const divisors = [1.0, 60.0, 3600.0];
  var degrees = 0.0;
  for (var i = 0; i < parts.length && i < 3; i++) {
    final part = _toDouble(parts[i]);
    if (part == null) return null;
    degrees += part / divisors[i];
  }
  final hemisphere = ref?.printable.trim().toUpperCase();
  return hemisphere != null && hemisphere.startsWith(negativeRef)
      ? -degrees
      : degrees;
}
