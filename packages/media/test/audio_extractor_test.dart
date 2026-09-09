import 'test_filesystem.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cadence_media/cadence_media.dart';
import 'package:cadence_media/src/extract/audio_extractor.dart';
import 'package:test/test.dart'
    hide test, setUp, tearDown, setUpAll, tearDownAll, addTearDown;

import 'fixtures.dart';

/// The audio tier against the whole fixture shelf: every dialect ffmpeg
/// wrote, the hand-built ID3v2.2, and the corrupt files that must earn a
/// quiet null instead of a stack trace.
void main() => memoryTests(registerTests);
void registerTests() {
  const extractor = AudioExtractor();
  late Directory scratch;

  setUpAll(
    () => scratch = mediaFileSystem.systemTempDirectory.createTempSync(
      'cadence_x2_',
    ),
  );
  tearDownAll(() => scratch.deleteSync(recursive: true));

  Future<AudioMetadata> readAudio(String path) async {
    final result = await extractor.extract(path, MediaKind.audio);
    expect(result, isNotNull, reason: 'no extraction for $path');
    return result!.metadata as AudioMetadata;
  }

  group('handles', () {
    test('claims audio extensions for the audio kind only', () {
      expect(extractor.handles(MediaKind.audio, 'mp3'), isTrue);
      expect(extractor.handles(MediaKind.audio, 'flac'), isTrue);
      expect(extractor.handles(MediaKind.audio, 'm4b'), isTrue);
      expect(extractor.handles(MediaKind.video, 'mp4'), isFalse);
      expect(extractor.handles(MediaKind.audio, 'xyz'), isFalse);
    });
  });

  group('mp3', () {
    test('id3v2.3: tags, track of total, and the TXXX in extra', () async {
      final audio = await readAudio(Fixtures.id3v23Mp3);
      expect(audio.title, 'Sine of the Times');
      expect(audio.artist, 'The Fixtures');
      expect(audio.album, 'Test Pattern');
      expect(audio.trackNumber, 1);
      expect(audio.trackTotal, 8);
      expect(audio.year, 2001);
      expect(audio.genres, ['Electronic']);
      expect(audio.extra['TXXX:fixture_note'], 'hand made for tests');
      expect(audio.codec, 'mp3');
      expect(audio.lossless, isFalse);
      expect(audio.sampleRateHz, 44100);
      expect(audio.channels, 1);
      expect(audio.duration, isNotNull);
      expect(audio.duration!, greaterThan(Duration.zero));
    });

    test('id3v2.4: the second track of eight', () async {
      final audio = await readAudio(Fixtures.id3v24Mp3);
      expect(audio.title, 'Four Forty');
      expect(audio.artist, 'The Fixtures');
      expect(audio.trackNumber, 2);
      expect(audio.trackTotal, 8);
      expect(audio.year, 2001);
    });

    test('apic: embedded artwork with an image mime', () async {
      final result = await extractor.extract(Fixtures.apicMp3, MediaKind.audio);
      final audio = result!.metadata as AudioMetadata;
      expect(audio.title, 'Cover Story');
      expect(result.artwork, hasLength(1));
      expect(result.artwork.single.bytes, isNotEmpty);
      expect(result.artwork.single.mime, startsWith('image/'));
      expect(result.artwork.single.role, ArtworkRole.embedded);
    });

    test('id3v1 only: the 128-byte tail, track byte included', () async {
      final audio = await readAudio(Fixtures.id3v1Mp3);
      expect(audio.title, 'Old Handshake');
      expect(audio.artist, 'The Fixtures');
      expect(audio.album, 'Legacy Format');
      expect(audio.year, 1997);
      expect(audio.comment, 'v1 only');
      expect(audio.trackNumber, 4);
    });

    test('id3v2.2: the hand-built dialect the package cannot read', () async {
      final path = Fixtures.id3v22Mp3(scratch);
      final audio = await readAudio(path);
      expect(audio.title, 'Deux Point Deux');
      expect(audio.artist, 'The Fixtures');
      expect(audio.codec, 'mp3');
      expect(audio.channels, 1);
      expect(audio.sampleRateHz, 44100);
      // The grafted ID3v1 tail still contributes its track byte.
      expect(audio.trackNumber, 4);
    });

    test('id3v2.2: a UTF-16 frame decodes through its BOM', () async {
      final path = _utf16V22Mp3(scratch, title: 'Décimal Deux');
      final audio = await readAudio(path);
      expect(audio.title, 'Décimal Deux');
    });

    test('id3v2.2: an odd-length UTF-16 payload keeps its text', () async {
      // Sloppy taggers leave a stray byte after the code units; the
      // reader takes the pairs it has and never trips on the remainder.
      final path = _utf16V22Mp3(scratch, title: 'Impair', oddTail: true);
      final audio = await readAudio(path);
      expect(audio.title, 'Impair');
    });
  });

  group('flac', () {
    test('vorbis comments, MusicBrainz, ReplayGain, and the PICTURE', () async {
      final result = await extractor.extract(
        Fixtures.taggedFlac,
        MediaKind.audio,
      );
      final audio = result!.metadata as AudioMetadata;

      expect(audio.title, 'Lossless Bloom');
      expect(audio.artist, 'The Fixtures');
      expect(audio.album, 'Test Pattern');
      expect(audio.date, '2001-03-12');
      expect(audio.year, 2001);
      expect(audio.trackNumber, 3);
      expect(audio.trackTotal, 8);
      expect(audio.genres, ['Electronic']);

      expect(
        audio.musicBrainz?.recordingId,
        '8f6bd1e4-fbe1-4f50-aa9b-4c0f8d3c0b6e',
      );
      expect(
        audio.musicBrainz?.releaseId,
        '1b7f4a90-95a3-4b47-a44a-2b7c8d1f2a3b',
      );
      expect(
        audio.musicBrainz?.artistId,
        'c9a1e0d2-3f4b-4d5e-8a6f-7b8c9d0e1f2a',
      );
      // Claimed keys are typed, not duplicated into extra.
      expect(audio.extra.containsKey('MUSICBRAINZ_TRACKID'), isFalse);

      expect(audio.replayGain?.trackGain, -6.2);
      expect(audio.replayGain?.trackPeak, 0.988712);
      expect(audio.replayGain?.albumGain, -5.8);
      expect(audio.replayGain?.albumPeak, 0.999969);

      expect(result.artwork, hasLength(1));
      expect(result.artwork.single.bytes, isNotEmpty);
      expect(result.artwork.single.mime, 'image/jpeg');
      expect(result.artwork.single.role, ArtworkRole.embedded);
    });

    test('STREAMINFO fills the technical truth', () async {
      final audio = await readAudio(Fixtures.taggedFlac);
      expect(audio.sampleRateHz, 44100);
      expect(audio.channels, 1);
      expect(audio.bitsPerSample, 16);
      expect(audio.duration, isNotNull);
      expect(audio.duration!, greaterThan(Duration.zero));
      expect(audio.codec, 'flac');
      expect(audio.lossless, isTrue);
    });
  });

  group('ogg family', () {
    test('vorbis: comments and a year-only date', () async {
      final audio = await readAudio(Fixtures.vorbisOgg);
      expect(audio.title, 'Ogg Verbose');
      expect(audio.artist, 'The Fixtures');
      expect(audio.album, 'Test Pattern');
      expect(audio.year, 2001);
      expect(audio.date, isNull);
      expect(audio.codec, 'vorbis');
      expect(audio.lossless, isFalse);
      expect(audio.sampleRateHz, 44100);
    });

    test('opus: sniffed apart from vorbis, 48kHz as Opus insists', () async {
      final audio = await readAudio(Fixtures.toneOpus);
      expect(audio.title, 'Opus Pocus');
      expect(audio.artist, 'The Fixtures');
      expect(audio.album, 'Test Pattern');
      expect(audio.codec, 'opus');
      expect(audio.sampleRateHz, 48000);
    });
  });

  group('mp4 family', () {
    test('m4a: iTunes atoms, aART and cpil included', () async {
      final audio = await readAudio(Fixtures.itunesM4a);
      expect(audio.title, 'Fruit Company');
      expect(audio.artist, 'The Fixtures');
      expect(audio.album, 'Test Pattern');
      expect(audio.albumArtist, 'Various Fixtures');
      expect(audio.compilation, isTrue);
      expect(audio.trackNumber, 5);
      expect(audio.trackTotal, 8);
      expect(audio.discNumber, 1);
      expect(audio.discTotal, 2);
      expect(audio.genres, ['Electronic']);
      expect(audio.year, 2001);
      expect(audio.codec, 'aac');
      expect(audio.lossless, isFalse);
      expect(audio.sampleRateHz, 44100);
    });

    test('m4b: an audiobook keeps its two chapters', () async {
      final audio = await readAudio(Fixtures.chaptersM4b);
      expect(audio.title, 'Audiobook of Fixtures');
      expect(audio.artist, 'The Fixtures');
      expect(audio.chapters, hasLength(2));
      expect(
        audio.chapters[0],
        const ChapterMark('Chapter One', Duration.zero),
      );
      expect(
        audio.chapters[1],
        const ChapterMark('Chapter Two', Duration(milliseconds: 100)),
      );
      expect(audio.duration, isNotNull);
      expect(audio.duration!, greaterThan(Duration.zero));
    });
  });

  group('riff family', () {
    test('wav: the INFO list and the fmt chunk', () async {
      final audio = await readAudio(Fixtures.riffWav);
      expect(audio.title, 'Riff Raff');
      expect(audio.artist, 'The Fixtures');
      expect(audio.album, 'Test Pattern');
      expect(audio.genres, ['Electronic']);
      expect(audio.sampleRateHz, 44100);
      expect(audio.channels, 1);
      expect(audio.bitsPerSample, 16);
      expect(audio.duration, isNotNull);
      expect(audio.duration!, greaterThan(Duration.zero));
      expect(audio.codec, 'pcm');
      expect(audio.lossless, isTrue);
    });

    test('aiff: untagged, but the stream still testifies', () async {
      final audio = await readAudio(Fixtures.plainAiff);
      expect(audio.title, isEmpty);
      expect(audio.sampleRateHz, 44100);
      expect(audio.duration, isNotNull);
      expect(audio.duration!, greaterThan(Duration.zero));
      expect(audio.codec, 'pcm');
      expect(audio.lossless, isTrue);
    });
  });

  group('beyond the pure-Dart tier', () {
    test('wma: no ASF parser here, so a graceful null', () async {
      final result = await extractor.extract(
        Fixtures.wmav2Wma,
        MediaKind.audio,
      );
      expect(result, isNull);
    });
  });

  group('corrupt input', () {
    test('garbage bytes never throw', () async {
      final path = '${scratch.path}/garbage.mp3';
      mediaFileSystem
          .file(path)
          .writeAsBytesSync(List.generate(64, (i) => (i * 37) & 0xff));
      expect(await extractor.extract(path, MediaKind.audio), isNull);
    });

    test('a truncated flac never throws', () async {
      final path = '${scratch.path}/broken.flac';
      mediaFileSystem.file(path).writeAsBytesSync([
        ...ascii.encode('fLaC'),
        0xff,
        0x00,
        0x10,
      ]);
      expect(await extractor.extract(path, MediaKind.audio), isNull);
    });

    test('every dialect cut at 10% and 50% answers or abstains', () async {
      for (final path in [
        Fixtures.id3v23Mp3,
        Fixtures.id3v24Mp3,
        Fixtures.apicMp3,
        Fixtures.id3v1Mp3,
        Fixtures.taggedFlac,
        Fixtures.vorbisOgg,
        Fixtures.toneOpus,
        Fixtures.itunesM4a,
        Fixtures.chaptersM4b,
        Fixtures.riffWav,
        Fixtures.plainAiff,
        Fixtures.wmav2Wma,
      ]) {
        final bytes = mediaFileSystem.file(path).readAsBytesSync();
        final name = path.split(mediaFileSystem.path.separator).last;
        for (final fraction in const [0.1, 0.5]) {
          final cut = (bytes.length * fraction).round().clamp(1, bytes.length);
          final stump = '${scratch.path}/$fraction-$name';
          mediaFileSystem.file(stump).writeAsBytesSync(bytes.sublist(0, cut));
          await expectLater(
            extractor.extract(stump, MediaKind.audio),
            completes,
            reason: '$name cut at $fraction must never throw',
          );
        }
      }
    });
  });
}

/// Builds an ID3v2.2 MP3 whose TT2 frame speaks UTF-16 with a BOM —
/// encoding `$01`, the second dialect the hand reader must understand.
/// [oddTail] grafts one stray byte after the code units, the way sloppy
/// taggers do.
String _utf16V22Mp3(
  Directory dir, {
  required String title,
  bool oddTail = false,
}) {
  final text = <int>[0xff, 0xfe];
  for (final unit in title.codeUnits) {
    text.add(unit & 0xff);
    text.add(unit >> 8);
  }
  if (oddTail) text.add(0x41);
  final content = [0x01, ...text];
  final frame = [
    ...ascii.encode('TT2'),
    (content.length >> 16) & 0xff,
    (content.length >> 8) & 0xff,
    content.length & 0xff,
    ...content,
  ];
  final header = Uint8List(10)
    ..setAll(0, const [0x49, 0x44, 0x33, 0x02, 0x00, 0x00])
    ..[6] = (frame.length >> 21) & 0x7f
    ..[7] = (frame.length >> 14) & 0x7f
    ..[8] = (frame.length >> 7) & 0x7f
    ..[9] = frame.length & 0x7f;
  final out = mediaFileSystem.file('${dir.path}/utf16v22.mp3');
  out.writeAsBytesSync([
    ...header,
    ...frame,
    ...mediaFileSystem.file(Fixtures.id3v1Mp3).readAsBytesSync(),
  ], flush: true);
  return out.path;
}
