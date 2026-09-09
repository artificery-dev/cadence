import 'test_filesystem.dart';
import 'package:cadence_media/src/filesystem.dart';
import 'dart:typed_data';

import 'package:cadence_media/src/database/database.dart';
import 'package:cadence_media/src/extract/extractor.dart';
import 'package:cadence_media/src/extract/image_extractor.dart';
import 'package:cadence_media/src/extract/phash.dart';
import 'package:cadence_media/src/kinds.dart';
import 'package:cadence_media/src/metadata.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart'
    hide test, setUp, tearDown, setUpAll, tearDownAll, addTearDown;

import 'fixtures.dart';

/// The image tier's contract: every format gives up its pixel grid, EXIF
/// gives up the camera and the place, the pHash tells near from far, and
/// a thumbnail rides out with every decodable file.
void main() => memoryTests(registerTests);
void registerTests() {
  const extractor = ImageExtractor();

  Future<ImageMetadata> extract(String path) async {
    final result = await extractor.extract(path, MediaKind.image);
    return result!.metadata as ImageMetadata;
  }

  group('handles', () {
    test('claims images and nothing else', () {
      expect(extractor.handles(MediaKind.image, 'jpg'), isTrue);
      expect(extractor.handles(MediaKind.image, 'tiff'), isTrue);
      expect(extractor.handles(MediaKind.image, 'heic'), isTrue);
      expect(extractor.handles(MediaKind.audio, 'jpg'), isFalse);
      expect(extractor.handles(MediaKind.video, 'png'), isFalse);
      expect(extractor.handles(MediaKind.document, 'png'), isFalse);
    });
  });

  group('dimensions', () {
    final expected = {
      Fixtures.exifJpg: (8, 8),
      Fixtures.tinyPng: (8, 8),
      Fixtures.tinyGif: (8, 8),
      Fixtures.tinyWebp: (8, 8),
      Fixtures.tinyBmp: (8, 8),
      Fixtures.tinyTiff: (8, 8),
      Fixtures.coverJpg: (32, 32),
    };

    for (final MapEntry(key: path, value: (width, height))
        in expected.entries) {
      test('${p.basename(path)} is $width×$height', () async {
        final metadata = await extract(path);
        expect(metadata.width, width);
        expect(metadata.height, height);
      });
    }

    test('a HEIC yields its ispe box without a codec in sight', () async {
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_image_test',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'mini.heic');
      mediaFileSystem
          .file(path)
          .writeAsBytesSync(_miniHeic(width: 640, height: 480));

      final result = await extractor.extract(path, MediaKind.image);
      final metadata = result!.metadata as ImageMetadata;
      expect(metadata.width, 640);
      expect(metadata.height, 480);
      // Nothing can decode the pixels, so no hash and no thumbnail —
      // quietly, not fatally.
      expect(result.hashes, isEmpty);
      expect(result.artwork, isEmpty);
    });
  });

  group('exif.jpg', () {
    test('the camera, the shot, the moment', () async {
      final metadata = await extract(Fixtures.exifJpg);
      expect(metadata.cameraMake, 'Cadence');
      expect(metadata.cameraModel, 'Fixture Cam 1000');
      expect(metadata.lensModel, 'Fixture 35mm f/2');
      expect(metadata.orientation, 1);
      expect(metadata.iso, 200);
      expect(metadata.exposureSeconds, closeTo(1 / 250, 1e-9));
      expect(metadata.fNumber, closeTo(2.8, 1e-9));
      expect(metadata.focalLengthMm, 35.0);
      expect(metadata.takenAt, DateTime(2020, 5, 17, 10, 30));
      expect(metadata.description, 'An eight by eight test card');
    });

    test('GPS lands as signed decimal degrees', () async {
      final metadata = await extract(Fixtures.exifJpg);
      expect(metadata.gpsLatitude, closeTo(51.5007, 1e-6));
      expect(metadata.gpsLongitude, closeTo(-0.1246, 1e-6));
      expect(metadata.gpsAltitude, 11.5);
    });

    test('untyped tags land in extra; typed and plumbing ones stay '
        'out', () async {
      final metadata = await extract(Fixtures.exifJpg);
      expect(metadata.extra['EXIF ExifVersion'], '0232');
      expect(metadata.extra, isNot(contains('Image Make')));
      expect(metadata.extra, isNot(contains('GPS GPSLatitude')));
      expect(metadata.extra, isNot(contains('Image ExifOffset')));
      expect(metadata.extra, isNot(contains('Image GPSInfo')));
    });

    test('a bare test card carries no camera and no coordinates', () async {
      final metadata = await extract(Fixtures.tinyPng);
      expect(metadata.title, isNull);
      expect(metadata.cameraMake, isNull);
      expect(metadata.takenAt, isNull);
      expect(metadata.gpsLatitude, isNull);
      expect(metadata.extra, isEmpty);
    });

    test('the facade fills the title from the filename', () async {
      final result = await const MediaExtractor([
        ImageExtractor(),
      ]).extract(Fixtures.tinyPng, MediaKind.image);
      expect((result.metadata as ImageMetadata).title, 'tiny');
    });
  });

  group('perceptual hash', () {
    test('rides out of extraction as sixteen hex digits', () async {
      final result = await extractor.extract(Fixtures.tinyPng, MediaKind.image);
      expect(
        result!.hashes[HashKind.perceptual],
        matches(RegExp(r'^[0-9a-f]{16}$')),
      );
    });

    test('the same image hashes the same, every time', () {
      final bytes = mediaFileSystem.file(Fixtures.tinyPng).readAsBytesSync();
      expect(perceptualHash(bytes), perceptualHash(bytes));
      expect(
        hammingDistance(perceptualHash(bytes)!, perceptualHash(bytes)!),
        0,
      );
    });

    test('a re-encode drifts a few bits at most', () async {
      final pngBytes = mediaFileSystem.file(Fixtures.tinyPng).readAsBytesSync();
      final decoded = img.decodeImage(pngBytes)!;
      final reencoded = img.encodeJpg(decoded, quality: 80);
      final distance = hammingDistance(
        perceptualHash(pngBytes)!,
        perceptualHash(reencoded)!,
      );
      expect(distance, lessThanOrEqualTo(6));
    });

    test('different images land far apart', () {
      final distance = hammingDistance(
        perceptualHash(
          mediaFileSystem.file(Fixtures.tinyPng).readAsBytesSync(),
        )!,
        perceptualHash(
          mediaFileSystem.file(Fixtures.coverJpg).readAsBytesSync(),
        )!,
      );
      expect(distance, greaterThan(10));
    });

    test('undecodable bytes hash to nothing', () {
      expect(perceptualHash('not an image'.codeUnits), isNull);
    });
  });

  group('renderThumbnail', () {
    test('a small image passes through untouched but re-wrapped', () {
      final thumbnail = renderThumbnail(
        mediaFileSystem.file(Fixtures.coverJpg).readAsBytesSync(),
      );
      expect(thumbnail, isNotNull);
      expect(thumbnail!.mime, 'image/jpeg');
      expect(thumbnail.role, ArtworkRole.thumbnail);
      final decoded = img.decodeJpg(Uint8List.fromList(thumbnail.bytes));
      expect(decoded!.width, 32);
      expect(decoded.height, 32);
    });

    test('a large image shrinks to 256 on the long side', () {
      final wide = img.Image(width: 512, height: 128);
      final thumbnail = renderThumbnail(img.encodePng(wide));
      final decoded = img.decodeJpg(Uint8List.fromList(thumbnail!.bytes));
      expect(decoded!.width, 256);
      expect(decoded.height, 64);

      final tall = img.Image(width: 100, height: 400);
      final tallThumb = renderThumbnail(img.encodePng(tall), longestSide: 200);
      final tallDecoded = img.decodeJpg(Uint8List.fromList(tallThumb!.bytes));
      expect(tallDecoded!.width, 50);
      expect(tallDecoded.height, 200);
    });

    test('undecodable bytes render nothing', () {
      expect(renderThumbnail('still not an image'.codeUnits), isNull);
    });

    test('every decodable image carries its own thumbnail out', () async {
      final result = await extractor.extract(
        Fixtures.tinyWebp,
        MediaKind.image,
      );
      expect(result!.artwork, hasLength(1));
      final thumbnail = result.artwork.single;
      expect(thumbnail.role, ArtworkRole.thumbnail);
      expect(img.decodeJpg(Uint8List.fromList(thumbnail.bytes)), isNotNull);
    });
  });

  group('corrupt input', () {
    test('every format cut at 10% and 50% answers or abstains', () async {
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_image',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      for (final path in [
        Fixtures.exifJpg,
        Fixtures.tinyPng,
        Fixtures.tinyGif,
        Fixtures.tinyWebp,
        Fixtures.tinyBmp,
        Fixtures.tinyTiff,
      ]) {
        final bytes = mediaFileSystem.file(path).readAsBytesSync();
        final name = p.basename(path);
        for (final fraction in const [0.1, 0.5]) {
          final cut = (bytes.length * fraction).round().clamp(1, bytes.length);
          final stump = p.join(dir.path, '$fraction-$name');
          mediaFileSystem.file(stump).writeAsBytesSync(bytes.sublist(0, cut));
          await expectLater(
            extractor.extract(stump, MediaKind.image),
            completes,
            reason: '$name cut at $fraction must never throw',
          );
        }
      }
    });

    test('a zero-denominator EXIF rational reads as absence', () async {
      // The fixture's ExposureTime is 1/250; surgery turns it into 1/0.
      // The camera fields must survive and the broken rational must
      // become null, not a division mishap.
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_image',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final bytes = mediaFileSystem.file(Fixtures.exifJpg).readAsBytesSync();
      var patched = false;
      for (var i = 0; i + 8 <= bytes.length && !patched; i++) {
        final view = ByteData.sublistView(bytes, i, i + 8);
        if (view.getUint32(0) == 1 && view.getUint32(4) == 250) {
          view.setUint32(4, 0);
          patched = true;
        } else if (view.getUint32(0, Endian.little) == 1 &&
            view.getUint32(4, Endian.little) == 250) {
          view.setUint32(4, 0, Endian.little);
          patched = true;
        }
      }
      expect(patched, isTrue, reason: 'the 1/250 rational should be findable');
      final path = p.join(dir.path, 'zero_denominator.jpg');
      mediaFileSystem.file(path).writeAsBytesSync(bytes);

      final result = await extractor.extract(path, MediaKind.image);
      final metadata = result!.metadata as ImageMetadata;
      expect(metadata.exposureSeconds, isNull);
      expect(metadata.cameraMake, 'Cadence');
      expect(metadata.fNumber, closeTo(2.8, 0.001));
    });

    test('a TIFF whose IFD points past the bytes answers quietly', () async {
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_image',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'bad.tiff');
      mediaFileSystem.file(path).writeAsBytesSync([
        0x49, 0x49, 0x2a, 0x00, 0xff, 0xff, 0x00, 0x00, 1, 2, 3, 4, //
      ]);
      final result = await extractor.extract(path, MediaKind.image);
      expect(result, isNotNull);
      expect((result!.metadata as ImageMetadata).width, isNull);
    });
  });
}

/// The least HEIC that can carry a pixel grid: an `ftyp`, then a `meta`
/// holding `iprp` → `ipco` → `ispe` with the width and height. No pixels
/// anywhere — exactly what the header-only path must survive.
Uint8List _miniHeic({required int width, required int height}) {
  Uint8List u32(int value) => Uint8List.fromList([
    (value >> 24) & 0xff,
    (value >> 16) & 0xff,
    (value >> 8) & 0xff,
    value & 0xff,
  ]);

  Uint8List box(String type, List<List<int>> payloads) {
    final size = 8 + payloads.fold<int>(0, (sum, part) => sum + part.length);
    final builder = BytesBuilder()
      ..add(u32(size))
      ..add(type.codeUnits);
    payloads.forEach(builder.add);
    return builder.toBytes();
  }

  const fullBoxHeader = [0, 0, 0, 0];
  final ispe = box('ispe', [fullBoxHeader, u32(width), u32(height)]);
  final ipco = box('ipco', [ispe]);
  final iprp = box('iprp', [ipco]);
  final meta = box('meta', [fullBoxHeader, iprp]);
  final ftyp = box('ftyp', ['heic'.codeUnits, u32(0)]);
  return Uint8List.fromList([...ftyp, ...meta]);
}
