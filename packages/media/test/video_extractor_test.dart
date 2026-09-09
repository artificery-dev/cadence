import 'test_filesystem.dart';
import 'package:cadence_media/src/filesystem.dart';
import 'dart:typed_data';

import 'package:cadence_media/src/extract/ebml.dart';
import 'package:cadence_media/src/extract/video_extractor.dart';
import 'package:cadence_media/src/kinds.dart';
import 'package:cadence_media/src/metadata.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart'
    hide test, setUp, tearDown, setUpAll, tearDownAll, addTearDown;

import 'fixtures.dart';

void main() => memoryTests(registerTests);
void registerTests() {
  const extractor = VideoExtractor();

  Future<VideoMetadata> read(String path) async {
    final result = await extractor.extract(path, MediaKind.video);
    expect(result, isNotNull, reason: 'no result for $path');
    return result!.metadata as VideoMetadata;
  }

  /// Every fixture is 0.2 seconds of test card; the container may round.
  final nearTheGeneratedLength = predicate<Duration?>(
    (d) =>
        d != null &&
        d > const Duration(milliseconds: 100) &&
        d < const Duration(seconds: 1),
    'within shouting distance of 0.2s',
  );

  group('handles', () {
    test('claims video containers and nothing else', () {
      for (final ext in ['mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi']) {
        expect(extractor.handles(MediaKind.video, ext), isTrue);
      }
      expect(extractor.handles(MediaKind.video, 'mp3'), isFalse);
      expect(extractor.handles(MediaKind.audio, 'mp4'), isFalse);
      expect(extractor.handles(MediaKind.image, 'avi'), isFalse);
    });
  });

  group('mp4', () {
    test('reads the container title, clock, frame, and codec', () async {
      final meta = await read(Fixtures.titledMp4);
      expect(meta.title, 'Test Card');
      expect(meta.width, 16);
      expect(meta.height, 16);
      expect(meta.duration, nearTheGeneratedLength);
      expect(meta.videoCodec, 'h264');
      expect(meta.container, 'mp4');
      expect(meta.extra['videoCodecId'], 'avc1');
    });

    test('computes a frame rate from the sample table', () async {
      final meta = await read(Fixtures.titledMp4);
      expect(meta.frameRate, isNotNull);
      expect(meta.frameRate, closeTo(10, 0.5));
    });

    test('reads a moov behind a 64-bit box size', () async {
      // The fixture's moov rewritten in the largesize dialect: size 1,
      // then the true size in the eight bytes after the type.
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_video',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final bytes = mediaFileSystem.file(Fixtures.titledMp4).readAsBytesSync();
      final at = _indexOf(bytes, 'moov'.codeUnits) - 4;
      final size = ByteData.sublistView(bytes).getUint32(at);
      final wide = size + 8;
      final path = p.join(dir.path, 'large_moov.mp4');
      mediaFileSystem.file(path).writeAsBytesSync([
        ...bytes.sublist(0, at),
        0,
        0,
        0,
        1,
        ...'moov'.codeUnits,
        for (var shift = 56; shift >= 0; shift -= 8) (wide >> shift) & 0xff,
        ...bytes.sublist(at + 8),
      ]);
      final meta = await read(path);
      expect(meta.title, 'Test Card');
      expect(meta.width, 16);
      expect(meta.duration, nearTheGeneratedLength);
    });
  });

  group('mkv', () {
    test('reads title, both codecs, and the frame', () async {
      final meta = await read(Fixtures.titledMkv);
      expect(meta.title, 'Two Track Mind');
      expect(meta.width, 16);
      expect(meta.height, 16);
      expect(meta.duration, nearTheGeneratedLength);
      expect(meta.videoCodec, 'h264');
      expect(meta.audioCodec, 'aac');
      expect(meta.container, 'mkv');
      expect(meta.extra['videoCodecId'], 'V_MPEG4/ISO/AVC');
    });

    test('reads the frame rate from DefaultDuration', () async {
      final meta = await read(Fixtures.titledMkv);
      expect(meta.frameRate, closeTo(10, 0.01));
    });

    test('walks a Segment that declares the unknown size', () async {
      // Streamed and cut-short files leave the Segment size all ones;
      // its children then run to the end of the file.
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_video',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final bytes = mediaFileSystem.file(Fixtures.titledMkv).readAsBytesSync();
      final at = _indexOf(bytes, const [0x18, 0x53, 0x80, 0x67]);
      expect(bytes[at + 4], 0x01, reason: 'expected an 8-byte size vint');
      for (var i = 1; i < 8; i++) {
        bytes[at + 4 + i] = 0xff;
      }
      final path = p.join(dir.path, 'unknown_segment.mkv');
      mediaFileSystem.file(path).writeAsBytesSync(bytes);
      final meta = await read(path);
      expect(meta.title, 'Two Track Mind');
      expect(meta.width, 16);
      expect(meta.videoCodec, 'h264');
    });
  });

  group('webm', () {
    test('reads dimensions, duration, and the VP9 codec', () async {
      final meta = await read(Fixtures.vp9Webm);
      expect(meta.width, 16);
      expect(meta.height, 16);
      expect(meta.duration, nearTheGeneratedLength);
      expect(meta.videoCodec, 'vp9');
      expect(meta.container, 'webm');
    });
  });

  group('avi', () {
    test('reads dimensions, duration, codec, and frame rate', () async {
      final meta = await read(Fixtures.mjpegAvi);
      expect(meta.width, 16);
      expect(meta.height, 16);
      expect(meta.duration, nearTheGeneratedLength);
      expect(meta.videoCodec, 'mjpeg');
      expect(meta.frameRate, closeTo(10, 0.01));
      expect(meta.container, 'avi');
    });
  });

  group('filename inference', () {
    test('SxxEyy names the series, season, and episode', () async {
      final meta = await read(Fixtures.episodeMkv);
      expect(meta.series, 'Fixture Show');
      expect(meta.season, 1);
      expect(meta.episode, 2);
      // Tagless on purpose — the container still speaks for itself.
      expect(meta.width, 16);
      expect(meta.videoCodec, 'h264');
    });

    test('the 1x02 form works too', () async {
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_video',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final copy = p.join(dir.path, 'Fixture Show 1x02.mkv');
      mediaFileSystem.file(Fixtures.episodeMkv).copySync(copy);
      final meta = await read(copy);
      expect(meta.series, 'Fixture Show');
      expect(meta.season, 1);
      expect(meta.episode, 2);
    });

    test('a resolution is not an episode', () async {
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_video',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final copy = p.join(dir.path, 'Fixture Show 1920x1080.mkv');
      mediaFileSystem.file(Fixtures.episodeMkv).copySync(copy);
      final meta = await read(copy);
      expect(meta.season, isNull);
      expect(meta.episode, isNull);
    });

    test('Title (Year) yields both, but a tagged title wins', () async {
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_video',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final titled = p.join(dir.path, 'Fixture Movie (2001).mp4');
      mediaFileSystem.file(Fixtures.titledMp4).copySync(titled);
      final meta = await read(titled);
      expect(meta.title, 'Test Card');
      expect(meta.year, 2001);

      final untitled = p.join(dir.path, 'Quiet Movie (1999).mkv');
      mediaFileSystem.file(Fixtures.episodeMkv).copySync(untitled);
      final quiet = await read(untitled);
      expect(quiet.title, 'Quiet Movie');
      expect(quiet.year, 1999);
    });

    test('a scene-release title steps down for the filename', () async {
      final meta = await read(Fixtures.releaseNamedMkv);
      expect(meta.title, 'Cool Show (2020) - S01E02');
      expect(
        meta.extra['taggedTitle'],
        'Cool.Show.S01E02.1080p.WEB-DL.x264-GRP',
      );
      expect(meta.series, 'Cool Show');
      expect(meta.season, 1);
      expect(meta.episode, 2);
      expect(meta.year, 2020);
    });

    test('an honest tagged title keeps its seat', () async {
      final meta = await read(Fixtures.titledMkv);
      expect(meta.title, 'Two Track Mind');
      expect(meta.extra.containsKey('taggedTitle'), isFalse);
    });

    test('a season directory is skipped on the way to the series', () async {
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_video',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final nested = mediaFileSystem.directory(
        p.join(dir.path, 'Fixture Show (2020)', 'S01'),
      )..createSync(recursive: true);
      final copy = p.join(nested.path, 'S01E02.mkv');
      mediaFileSystem.file(Fixtures.episodeMkv).copySync(copy);
      final meta = await read(copy);
      expect(meta.series, 'Fixture Show');
      expect(meta.season, 1);
      expect(meta.episode, 2);
      expect(meta.year, 2020);
    });
  });

  group('corrupt input', () {
    test('garbage never throws, and the filename still speaks', () async {
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_video',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      for (final name in [
        'Broken Show S02E05.mkv',
        'broken.mp4',
        'broken.avi',
        'broken.webm',
      ]) {
        final path = p.join(dir.path, name);
        mediaFileSystem.file(path).writeAsBytesSync(List.filled(64, 0x42));
        final result = await extractor.extract(path, MediaKind.video);
        expect(result, isNotNull, reason: '$name should still answer');
      }
      final episode = await read(p.join(dir.path, 'Broken Show S02E05.mkv'));
      expect(episode.series, 'Broken Show');
      expect(episode.season, 2);
      expect(episode.episode, 5);
    });

    test('a truncated real file keeps what it managed', () async {
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_video',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final bytes = mediaFileSystem.file(Fixtures.titledMkv).readAsBytesSync();
      final path = p.join(dir.path, 'cut.mkv');
      mediaFileSystem
          .file(path)
          .writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 3));
      final meta = await read(path);
      expect(meta.container, 'mkv');
      // The Info and Tracks elements sit well inside the first third.
      expect(meta.title, 'Two Track Mind');
      expect(meta.videoCodec, 'h264');
    });

    test('every container cut at 10% and 50% answers or abstains', () async {
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_video',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      for (final path in [
        Fixtures.titledMp4,
        Fixtures.titledMkv,
        Fixtures.vp9Webm,
        Fixtures.mjpegAvi,
      ]) {
        final bytes = mediaFileSystem.file(path).readAsBytesSync();
        final name = p.basename(path);
        for (final fraction in const [0.1, 0.5]) {
          final cut = (bytes.length * fraction).round().clamp(1, bytes.length);
          final stump = p.join(dir.path, '$fraction-$name');
          mediaFileSystem.file(stump).writeAsBytesSync(bytes.sublist(0, cut));
          await expectLater(
            extractor.extract(stump, MediaKind.video),
            completes,
            reason: '$name cut at $fraction must never throw',
          );
        }
      }
    });
  });

  group('ebml walker', () {
    RandomAccessFile open(Directory dir, List<int> bytes) {
      final file = mediaFileSystem.file(p.join(dir.path, 'sample.ebml'))
        ..writeAsBytesSync(bytes);
      final raf = file.openSync();
      addTearDown(raf.closeSync);
      return raf;
    }

    test('parses one-byte and multi-byte ids and sizes', () {
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_ebml',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      // Title (0x7BA9, 2-byte id), size 2, "hi"; then a Segment-style
      // 4-byte id with a 2-byte size varint.
      final raf = open(dir, [
        0x7b, 0xa9, 0x82, 0x68, 0x69, // Title "hi"
        0x18, 0x53, 0x80, 0x67, 0x40, 0x01, 0x00, // Segment, size 1
      ]);
      final ebml = EbmlReader(raf);
      final elements = ebml.topLevel().toList();
      expect(elements, hasLength(2));
      expect(elements[0].id, MatroskaId.title);
      expect(ebml.stringOf(elements[0]), 'hi');
      expect(elements[1].id, MatroskaId.segment);
      expect(elements[1].dataSize, 1);
    });

    test('an all-ones size means unknown and ends the walk there', () {
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_ebml',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final raf = open(dir, [
        0x18, 0x53, 0x80, 0x67, 0xff, // Segment, unknown size
        0x7b, 0xa9, 0x81, 0x68, // its child: Title "h"
      ]);
      final ebml = EbmlReader(raf);
      final top = ebml.topLevel().toList();
      expect(top, hasLength(1));
      expect(top.single.dataSize, isNull);
      final children = ebml.children(top.single).toList();
      expect(children.single.id, MatroskaId.title);
      expect(ebml.stringOf(children.single), 'h');
    });

    test('Void and CRC-32 never surface', () {
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_ebml',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final raf = open(dir, [
        0xbf, 0x84, 1, 2, 3, 4, // CRC-32
        0xec, 0x82, 0, 0, // Void
        0x7b, 0xa9, 0x81, 0x68, // Title "h"
      ]);
      final ebml = EbmlReader(raf);
      final elements = ebml.topLevel().toList();
      expect(elements.single.id, MatroskaId.title);
    });

    test('numbers read big-endian at any declared width', () {
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_ebml',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final raf = open(dir, [
        0xb0, 0x82, 0x01, 0x00, // PixelWidth = 256, two bytes
        0x44, 0x89, 0x84, 0x43, 0x48, 0x00, 0x00, // Duration = 200.0f
      ]);
      final ebml = EbmlReader(raf);
      final elements = ebml.topLevel().toList();
      expect(ebml.uintOf(elements[0]), 256);
      expect(ebml.floatOf(elements[1]), 200.0);
    });
  });
}

/// The first offset of [needle] in [haystack] — fixture surgery's compass.
int _indexOf(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  throw StateError('pattern not found in fixture');
}
