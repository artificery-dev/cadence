import 'package:file/memory.dart';
import '../local_test_scope.dart';
import 'package:file/local.dart';
import 'package:cadence_media/src/filesystem.dart' show withMediaFileSystem;
import 'dart:io';
import 'dart:isolate';

import 'package:cadence_media/src/database/database.dart';
import 'package:cadence_media/src/extract/audio_extractor.dart';
import 'package:cadence_media/src/extract/extractor.dart';
import 'package:cadence_media/src/extract/phash.dart';
import 'package:cadenced/probe.dart';
import 'package:cadence_media/src/kinds.dart';
import 'package:cadence_media/src/metadata.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart'
    hide test, setUp, tearDown, setUpAll, tearDownAll, addTearDown;

import '../../../packages/media/test/fixtures.dart';

/// The native tier, exercised end to end: the Rust library is built when
/// cargo is around (cargo caches, so reruns are cheap), loaded through
/// [ProbeExtractor.tryLoad], and pointed at real fixtures. Every
/// assertion reads the mapped [ExtractionResult] — typed fields, raw
/// `extra`, artwork bytes, fingerprint hashes — never the raw JSON.
///
/// Without a library and without cargo, every test skips aloud.
void main() => withMediaFileSystem(const LocalFileSystem(), registerTests);
void registerTests() {
  ProbeExtractor? probe;

  setUpAll(() {
    probe = ProbeExtractor.tryLoad() ?? _buildAndLoad();
    if (probe == null) {
      print(
        'probe_test: skipping — libcadence_probe not found and cargo is '
        'not installed to build it (see crates/probe/README.md)',
      );
    }
  });

  /// Runs [body] against the loaded probe, or skips with the reason on
  /// record.
  void probeTest(
    String description,
    Future<void> Function(ProbeExtractor probe) body,
  ) {
    test(description, () async {
      final loaded = probe;
      if (loaded == null) {
        markTestSkipped('native probe library unavailable');
        return;
      }
      await body(loaded);
    });
  }

  group('loading', () {
    probeTest('claims the right extensions once loaded', (probe) async {
      expect(probe.handles(MediaKind.audio, 'flac'), isTrue);
      expect(probe.handles(MediaKind.audio, 'wma'), isTrue);
      expect(probe.handles(MediaKind.video, 'mkv'), isTrue);
      expect(probe.handles(MediaKind.image, 'heic'), isTrue);
      expect(probe.handles(MediaKind.document, 'pdf'), isTrue);
      expect(probe.handles(MediaKind.document, 'txt'), isFalse);
      expect(probe.handles(MediaKind.audio, 'xyz'), isFalse);
    });
  });

  group('tagged.flac', () {
    probeTest('types MusicBrainz and ReplayGain, and keeps the raw keys', (
      probe,
    ) async {
      final result = await probe.extract(Fixtures.taggedFlac, MediaKind.audio);
      final metadata = result!.metadata as AudioMetadata;

      expect(
        metadata.musicBrainz?.recordingId,
        '8f6bd1e4-fbe1-4f50-aa9b-4c0f8d3c0b6e',
      );
      expect(
        metadata.musicBrainz?.releaseId,
        '1b7f4a90-95a3-4b47-a44a-2b7c8d1f2a3b',
      );
      expect(
        metadata.musicBrainz?.artistId,
        'c9a1e0d2-3f4b-4d5e-8a6f-7b8c9d0e1f2a',
      );
      expect(metadata.replayGain?.trackGain, closeTo(-6.20, 0.001));
      expect(metadata.replayGain?.trackPeak, closeTo(0.988712, 0.000001));
      expect(metadata.replayGain?.albumGain, closeTo(-5.80, 0.001));
      expect(metadata.replayGain?.albumPeak, closeTo(0.999969, 0.000001));

      // Identifiers ride in both places: typed, and raw under their
      // source spelling in extra.
      expect(
        metadata.extra['MUSICBRAINZ_TRACKID'],
        '8f6bd1e4-fbe1-4f50-aa9b-4c0f8d3c0b6e',
      );
      expect(metadata.extra['REPLAYGAIN_TRACK_GAIN'], '-6.20 dB');

      expect(metadata.trackNumber, 3);
      expect(metadata.lossless, isTrue);
      expect(metadata.codec, 'FLAC');
      expect(result.artwork, isNotEmpty);
      expect(result.artwork.first.role, ArtworkRole.embedded);
      expect(result.artwork.first.bytes, isNotEmpty);
    });
  });

  group('chapters.m4b', () {
    probeTest('reads both chapters', (probe) async {
      final result = await probe.extract(Fixtures.chaptersM4b, MediaKind.audio);
      final metadata = result!.metadata as AudioMetadata;

      expect(metadata.chapters, hasLength(2));
      expect(
        metadata.chapters.first,
        ChapterMark('Chapter One', Duration.zero),
      );
      expect(metadata.chapters.last.title, 'Chapter Two');
      expect(metadata.chapters.last.start, greaterThan(Duration.zero));
    });
  });

  group('scened.mkv', () {
    probeTest('reads the scene stops as chapter marks', (probe) async {
      final result = await probe.extract(Fixtures.scenedMkv, MediaKind.video);
      final metadata = result!.metadata as VideoMetadata;

      expect(metadata.title, 'Scene Study');
      expect(metadata.chapters, hasLength(2));
      expect(metadata.chapters.first, ChapterMark('Opening', Duration.zero));
      expect(metadata.chapters.last.title, 'Finale');
      expect(metadata.chapters.last.start, greaterThan(Duration.zero));
    });
  });

  group('titled.mkv', () {
    probeTest('reads the segment title and frame size', (probe) async {
      final result = await probe.extract(Fixtures.titledMkv, MediaKind.video);
      final metadata = result!.metadata as VideoMetadata;

      expect(metadata.title, 'Two Track Mind');
      expect(metadata.width, 16);
      expect(metadata.height, 16);
      expect(metadata.videoCodec, 'h264');
      expect(metadata.container, 'Matroska');
    });
  });

  group('info.pdf', () {
    probeTest('reads the Info dict and hashes the text', (probe) async {
      final result = await probe.extract(Fixtures.infoPdf, MediaKind.document);
      final metadata = result!.metadata as DocumentMetadata;

      expect(metadata.title, 'Fixture Document');
      expect(metadata.author, 'Cadence Fixtures');
      expect(metadata.pageCount, 1);
      expect(
        result.hashes[HashKind.textSimhash],
        matches(RegExp(r'^[0-9a-f]{16}$')),
      );
    });
  });

  group('book.epub', () {
    probeTest('reads the OPF metadata', (probe) async {
      final result = await probe.extract(Fixtures.bookEpub, MediaKind.document);
      final metadata = result!.metadata as DocumentMetadata;

      expect(metadata.title, 'The Fixture Book');
      expect(metadata.author, 'Cadence Fixtures');
      expect(metadata.authors, contains('Cadence Fixtures'));
      expect(metadata.language, 'en');
      expect(metadata.publisher, 'Fixture Press');
      expect(metadata.isbn, isNotNull);
      expect(
        result.hashes[HashKind.textSimhash],
        matches(RegExp(r'^[0-9a-f]{16}$')),
      );
    });
  });

  group('the path across the boundary', () {
    probeTest('unicode filenames arrive intact', (probe) async {
      final dir = Directory.systemTemp.createTempSync('probe_utf8');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'naïve — ☃.flac');
      File(Fixtures.taggedFlac).copySync(path);
      final result = await probe.extract(path, MediaKind.audio);
      expect((result!.metadata as AudioMetadata).title, 'Lossless Bloom');
    });

    probeTest('an interior NUL earns a graceful null', (probe) async {
      // The C string ends where the NUL falls; the truncated path names
      // nothing, and the io envelope comes back as a quiet null.
      final result = await probe.extract(
        '/no/such/\u0000file.flac',
        MediaKind.audio,
      );
      expect(result, isNull);
    });

    probeTest('a missing file earns a graceful null', (probe) async {
      final result = await probe.extract(
        '/definitely/not/here.flac',
        MediaKind.audio,
      );
      expect(result, isNull);
    });
  });

  group('cross-tier pHash', () {
    // The probe reimplements phash.dart's pinned layout by hand; only
    // decoder differences may separate the two, and those wiggle a few
    // bits at most. A layout mismatch scores ~32 and fails loudly.
    for (final (name, path) in [
      ('jpg', Fixtures.exifJpg),
      ('png', Fixtures.tinyPng),
    ]) {
      probeTest('agrees with the Dart tier on the $name fixture', (
        probe,
      ) async {
        final dartHash = perceptualHash(File(path).readAsBytesSync());
        expect(dartHash, isNotNull, reason: 'Dart tier must decode $name');
        final result = await probe.extract(path, MediaKind.image);
        final probeHash = result!.hashes[HashKind.perceptual];
        expect(probeHash, matches(RegExp(r'^[0-9a-f]{16}$')));
        expect(
          hammingDistance(dartHash!, probeHash!),
          lessThanOrEqualTo(10),
          reason: 'dart=$dartHash probe=$probeHash — the bit layout drifted',
        );
      });
    }
  });

  probeTest('virtual filesystem capability is rejected before native access', (
    probe,
  ) async {
    await expectLater(
      withMediaFileSystem(
        MemoryFileSystem.test(),
        () => probe.extract('/virtual.mp3', MediaKind.audio),
      ),
      throwsUnsupportedError,
    );
  });

  group('concurrency', () {
    probeTest('four isolates probe at once without tripping over', (_) async {
      // The library promises reentrancy — no globals, several worker
      // isolates calling in at once. Each isolate binds its own handle
      // (FFI closures cannot cross isolates) and probes every kind.
      final answers = await Future.wait([
        for (var i = 0; i < 4; i++)
          Isolate.run(
            () => withMediaFileSystem(const LocalFileSystem(), () async {
              final probe = ProbeExtractor.tryLoad();
              if (probe == null) return const <String>[];
              final probes = [
                (Fixtures.taggedFlac, MediaKind.audio),
                (Fixtures.titledMkv, MediaKind.video),
                (Fixtures.exifJpg, MediaKind.image),
                (Fixtures.infoPdf, MediaKind.document),
              ];
              final titles = <String>[];
              for (var round = 0; round < 3; round++) {
                for (final (path, kind) in probes) {
                  final result = await probe.extract(path, kind);
                  titles.add(switch (result?.metadata) {
                    final AudioMetadata m => m.title,
                    final VideoMetadata m => m.title,
                    final ImageMetadata m => m.cameraMake ?? '',
                    final DocumentMetadata m => m.title,
                    null => '<null>',
                  });
                }
              }
              return titles;
            }),
          ),
      ]);
      for (final titles in answers) {
        expect(titles, hasLength(12));
        expect(titles, isNot(contains('<null>')));
        expect(titles, contains('Two Track Mind'));
        expect(titles, contains('Fixture Document'));
      }
    });
  });

  group('truncated files', () {
    // Malformed media must cost an error envelope, never a crash — and
    // never a hang: a truncated AVI once spun the riff walk forever.
    probeTest('answer with envelopes, not crashes', (probe) async {
      final dir = Directory.systemTemp.createTempSync('probe_truncated');
      addTearDown(() => dir.deleteSync(recursive: true));
      final fixtures = [
        (Fixtures.id3v23Mp3, MediaKind.audio),
        (Fixtures.taggedFlac, MediaKind.audio),
        (Fixtures.vorbisOgg, MediaKind.audio),
        (Fixtures.toneOpus, MediaKind.audio),
        (Fixtures.itunesM4a, MediaKind.audio),
        (Fixtures.chaptersM4b, MediaKind.audio),
        (Fixtures.riffWav, MediaKind.audio),
        (Fixtures.plainAiff, MediaKind.audio),
        (Fixtures.wmav2Wma, MediaKind.audio),
        (Fixtures.titledMp4, MediaKind.video),
        (Fixtures.titledMkv, MediaKind.video),
        (Fixtures.vp9Webm, MediaKind.video),
        (Fixtures.mjpegAvi, MediaKind.video),
        (Fixtures.exifJpg, MediaKind.image),
        (Fixtures.tinyPng, MediaKind.image),
        (Fixtures.infoPdf, MediaKind.document),
        (Fixtures.bookEpub, MediaKind.document),
      ];
      for (final (path, kind) in fixtures) {
        final bytes = File(path).readAsBytesSync();
        for (final fraction in const [0.1, 0.5]) {
          final cut = (bytes.length * fraction).round().clamp(1, bytes.length);
          final stump = p.join(dir.path, '$fraction-${p.basename(path)}');
          File(stump).writeAsBytesSync(bytes.sublist(0, cut));
          await expectLater(
            probe.extract(stump, kind).timeout(const Duration(seconds: 30)),
            completes,
            reason:
                '${p.basename(path)} cut at $fraction must not '
                'crash or hang the probe',
          );
        }
      }
    });
  });

  group('facade merge', () {
    // X6 types identifiers AND keeps them raw in extra — by design. The
    // facade's null-filling merge must stay stable under that double
    // booking: one typed value, the raw spelling intact, no flapping
    // between runs.
    probeTest('stays stable with double-typed identifiers', (probe) async {
      final facade = MediaExtractor([const AudioExtractor(), probe]);
      final first = await facade.extract(Fixtures.taggedFlac, MediaKind.audio);
      final second = await facade.extract(Fixtures.taggedFlac, MediaKind.audio);
      final metadata = first.metadata as AudioMetadata;

      expect(
        metadata.musicBrainz?.recordingId,
        '8f6bd1e4-fbe1-4f50-aa9b-4c0f8d3c0b6e',
      );
      expect(
        metadata.extra['MUSICBRAINZ_TRACKID'],
        metadata.musicBrainz?.recordingId,
      );
      expect(metadata.replayGain?.trackGain, closeTo(-6.20, 0.001));
      expect(metadata.extra['REPLAYGAIN_TRACK_GAIN'], '-6.20 dB');
      expect(
        metadata.artists.toSet().length,
        metadata.artists.length,
        reason: 'the merge must not double credits',
      );
      expect(
        second.metadata.toJson(),
        metadata.toJson(),
        reason: 'the same file must merge the same way every time',
      );
    });
  });

  group('exif.jpg', () {
    probeTest('names the camera and places the shot', (probe) async {
      final result = await probe.extract(Fixtures.exifJpg, MediaKind.image);
      final metadata = result!.metadata as ImageMetadata;

      expect(metadata.cameraMake, 'Cadence');
      expect(metadata.cameraModel, 'Fixture Cam 1000');
      expect(metadata.lensModel, 'Fixture 35mm f/2');
      expect(metadata.gpsLatitude, closeTo(51.5007, 0.0001));
      expect(metadata.gpsLongitude, closeTo(-0.1246, 0.0001));
      expect(metadata.width, 8);
      expect(metadata.height, 8);
      expect(
        result.hashes[HashKind.perceptual],
        matches(RegExp(r'^[0-9a-f]{16}$')),
      );
    });
  });
}

/// Builds the crate when cargo is present, then loads the fresh library.
/// Null when there is no cargo or the build failed.
ProbeExtractor? _buildAndLoad() {
  final crate = _crateDir();
  if (crate == null) return null;
  try {
    final built = Process.runSync(Platform.resolvedExecutable, [
      'run',
      p.join(p.dirname(p.dirname(crate)), 'tool', 'bin', 'cadence.dart'),
      'native',
      'build',
    ], workingDirectory: p.dirname(p.dirname(crate)));
    if (built.exitCode != 0) {
      print('probe_test: cargo build failed:\n${built.stderr}');
      return null;
    }
  } on ProcessException {
    return null;
  }
  return ProbeExtractor.tryLoad();
}

/// The crate's directory, found by walking up from the working directory
/// — tests run from the package, the dev loop from the repo root.
String? _crateDir() {
  var dir = Directory.current;
  while (true) {
    final candidate = p.join(dir.path, 'crates', 'probe');
    if (Directory(candidate).existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}
