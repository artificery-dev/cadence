import 'test_filesystem.dart';
import 'dart:math' as math;

import 'package:cadence_media/cadence_media.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart'
    hide test, setUp, tearDown, setUpAll, tearDownAll, addTearDown;

import 'fixtures.dart';

/// The first bytes of a fixture — 64 is plenty for every signature
/// classify reads, the EBML DocType included.
List<int> _headerOf(String path, [int length = 64]) {
  final bytes = mediaFileSystem.file(path).readAsBytesSync();
  return bytes.sublist(0, math.min(length, bytes.length));
}

/// Flattens one media file's matches to `kind:basename` strings, so tests
/// can assert on sets instead of list order.
Set<String> _served(Map<String, List<SidecarMatch>> matches, String media) => {
  for (final match in matches[media] ?? const <SidecarMatch>[])
    '${match.kind.name}:${p.basename(match.path)}',
};

void main() => memoryTests(registerTests);
void registerTests() {
  group('classify by extension', () {
    test('maps every supported family', () {
      expect(classify('Track01.mp3'), MediaKind.audio);
      expect(classify('a/b/song.flac'), MediaKind.audio);
      expect(classify('book.m4b'), MediaKind.audio);
      expect(classify('clip.mkv'), MediaKind.video);
      expect(classify('clip.webm'), MediaKind.video);
      expect(classify('photo.jpeg'), MediaKind.image);
      expect(classify('photo.heic'), MediaKind.image);
      expect(classify('paper.pdf'), MediaKind.document);
      expect(classify('book.epub'), MediaKind.document);
      expect(classify('notes.txt'), MediaKind.document);
    });

    test('ignores case', () {
      expect(classify('TRACK.MP3'), MediaKind.audio);
      expect(classify('Photo.JPeG'), MediaKind.image);
    });

    test('shrugs at strangers', () {
      expect(classify('archive.zip'), isNull);
      expect(classify('noextension'), isNull);
      expect(classify('.hidden'), isNull);
    });
  });

  group('classify with magic bytes', () {
    test('confirms every fixture against its own header', () {
      final expected = {
        Fixtures.id3v23Mp3: MediaKind.audio,
        Fixtures.id3v1Mp3: MediaKind.audio, // bare frame sync, no ID3 header
        Fixtures.taggedFlac: MediaKind.audio,
        Fixtures.vorbisOgg: MediaKind.audio,
        Fixtures.toneOpus: MediaKind.audio,
        Fixtures.itunesM4a: MediaKind.audio,
        Fixtures.chaptersM4b: MediaKind.audio,
        Fixtures.riffWav: MediaKind.audio,
        Fixtures.plainAiff: MediaKind.audio,
        Fixtures.wmav2Wma: MediaKind.audio, // no signature; extension holds
        Fixtures.titledMp4: MediaKind.video,
        Fixtures.titledMkv: MediaKind.video,
        Fixtures.vp9Webm: MediaKind.video,
        Fixtures.mjpegAvi: MediaKind.video,
        Fixtures.exifJpg: MediaKind.image,
        Fixtures.tinyPng: MediaKind.image,
        Fixtures.tinyGif: MediaKind.image,
        Fixtures.tinyWebp: MediaKind.image,
        Fixtures.tinyBmp: MediaKind.image,
        Fixtures.tinyTiff: MediaKind.image,
        Fixtures.infoPdf: MediaKind.document,
        Fixtures.bookEpub: MediaKind.document, // zip bytes; extension holds
      };
      for (final MapEntry(key: path, value: kind) in expected.entries) {
        expect(
          classify(path, headerBytes: _headerOf(path)),
          kind,
          reason: p.basename(path),
        );
      }
    });

    test('repairs a lying extension by content', () {
      expect(
        classify('song.txt', headerBytes: _headerOf(Fixtures.id3v23Mp3)),
        MediaKind.audio,
      );
      expect(
        classify('art.mp3', headerBytes: _headerOf(Fixtures.tinyBmp)),
        MediaKind.image,
      );
      expect(
        classify('movie.jpg', headerBytes: _headerOf(Fixtures.mjpegAvi)),
        MediaKind.video,
      );
      expect(
        classify('blob.bin', headerBytes: _headerOf(Fixtures.tinyPng)),
        MediaKind.image,
      );
      expect(
        classify('cover.png', headerBytes: _headerOf(Fixtures.exifJpg)),
        MediaKind.image,
      );
    });

    test('splits the EBML family on its DocType', () {
      final mkv = _headerOf(Fixtures.titledMkv);
      final webm = _headerOf(Fixtures.vp9Webm);
      expect(classify('clip.txt', headerBytes: mkv), MediaKind.video);
      expect(classify('tracks.mka', headerBytes: mkv), MediaKind.audio);
      expect(classify('song.mp3', headerBytes: webm), MediaKind.video);
    });

    test('an EBML header with no DocType lets the extension stand', () {
      // The magic alone, an EBMLVersion element, and no 42 82 anywhere.
      const headless = [0x1a, 0x45, 0xdf, 0xa3, 0x9f, 0x42, 0x86, 0x81, 0x01];
      expect(classify('clip.mkv', headerBytes: headless), MediaKind.video);
      expect(classify('tracks.mka', headerBytes: headless), MediaKind.audio);
      expect(classify('blob.bin', headerBytes: headless), MediaKind.video);
    });

    test('splits the ISO-BMFF family on its ftyp brand', () {
      final m4a = _headerOf(Fixtures.itunesM4a);
      final mp4 = _headerOf(Fixtures.titledMp4);
      expect(classify('video.mp4', headerBytes: m4a), MediaKind.audio);
      expect(classify('song.m4a', headerBytes: mp4), MediaKind.audio);
      expect(classify('file.xyz', headerBytes: mp4), MediaKind.video);
    });

    test('lets the extension stand when the bytes say nothing', () {
      final prose = 'just some words\n'.codeUnits;
      expect(classify('notes.mp3', headerBytes: prose), MediaKind.audio);
      expect(classify('notes.xyz', headerBytes: prose), isNull);
      final truncated = _headerOf(Fixtures.titledMkv, 2);
      expect(classify('clip.mkv', headerBytes: truncated), MediaKind.video);
    });
  });

  group('formatTag', () {
    test('normalises the aliases', () {
      expect(formatTag('photo.jpeg'), 'jpg');
      expect(formatTag('scan.tif'), 'tiff');
      expect(formatTag('take.aif'), 'aiff');
    });

    test('lowercases and passes the rest through', () {
      expect(formatTag('Track.MP3'), 'mp3');
      expect(formatTag('song.flac'), 'flac');
      expect(formatTag('Photo.JPEG'), 'jpg');
    });
  });

  group('extensionOf', () {
    test('is bare and lowercased', () {
      expect(extensionOf('Track.MP3'), 'mp3');
      expect(extensionOf('/a/b/Episode.en.srt'), 'srt');
    });

    test('is empty when there is nothing to take', () {
      expect(extensionOf('noextension'), '');
      expect(extensionOf('.hidden'), '');
    });
  });

  group('isFolderArtName', () {
    test('accepts every art name in every art format', () {
      for (final stem in [
        'cover',
        'folder',
        'front',
        'album',
        'poster',
        'fanart',
      ]) {
        for (final ext in ['jpg', 'jpeg', 'png', 'webp']) {
          expect(isFolderArtName('$stem.$ext'), isTrue, reason: '$stem.$ext');
        }
      }
    });

    test('ignores case and accepts full paths', () {
      expect(isFolderArtName('Cover.JPG'), isTrue);
      expect(isFolderArtName('FANART.WebP'), isTrue);
      expect(isFolderArtName(p.join('a', 'b', 'Folder.png')), isTrue);
    });

    test('rejects the wrong name or the wrong clothes', () {
      expect(isFolderArtName('back.jpg'), isFalse);
      expect(isFolderArtName('cover.bmp'), isFalse);
      expect(isFolderArtName('cover'), isFalse);
      expect(isFolderArtName('cover.jpg.txt'), isFalse);
    });
  });

  group('associateSidecars', () {
    final album = p.join('music', 'The Fixtures', 'Test Pattern');
    final shows = p.join('shows', 'Fixture Show', 'S01');

    test('lyrics find their track by basename', () {
      final track1 = p.join(album, 'Track01.mp3');
      final track2 = p.join(album, 'Track02.mp3');
      final matches = associateSidecars(
        mediaFiles: [track1, track2],
        otherFiles: [p.join(album, 'Track01.lrc')],
      );
      expect(_served(matches, track1), {'lyrics:Track01.lrc'});
      expect(matches, isNot(contains(track2)));
    });

    test('subtitles tolerate a language infix', () {
      final episode = p.join(shows, 'Episode.mkv');
      final matches = associateSidecars(
        mediaFiles: [episode],
        otherFiles: [
          p.join(shows, 'Episode.srt'),
          p.join(shows, 'Episode.en.srt'),
          p.join(shows, 'Episode.en.forced.srt'),
        ],
      );
      expect(_served(matches, episode), {
        'subtitles:Episode.srt',
        'subtitles:Episode.en.srt',
        'subtitles:Episode.en.forced.srt',
      });
    });

    test('the longest matching stem wins', () {
      final plain = p.join(shows, 'Episode.mkv');
      final english = p.join(shows, 'Episode.en.mkv');
      final matches = associateSidecars(
        mediaFiles: [plain, english],
        otherFiles: [p.join(shows, 'Episode.en.srt')],
      );
      expect(_served(matches, english), {'subtitles:Episode.en.srt'});
      expect(matches, isNot(contains(plain)));
    });

    test('a tie serves every winner', () {
      final flac = p.join(album, 'Track01.flac');
      final mp3 = p.join(album, 'Track01.mp3');
      final matches = associateSidecars(
        mediaFiles: [flac, mp3],
        otherFiles: [p.join(album, 'Track01.lrc')],
      );
      expect(_served(matches, flac), {'lyrics:Track01.lrc'});
      expect(_served(matches, mp3), {'lyrics:Track01.lrc'});
    });

    test('prefixes only count at a dot boundary', () {
      final one = p.join(shows, 'Episode 1.mkv');
      final matches = associateSidecars(
        mediaFiles: [one],
        otherFiles: [p.join(shows, 'Episode 12.srt')],
      );
      expect(matches, isEmpty);
    });

    test('folder art serves every media file in the directory', () {
      final track1 = p.join(album, 'Track01.mp3');
      final track2 = p.join(album, 'Track02.flac');
      final matches = associateSidecars(
        mediaFiles: [track1, track2],
        otherFiles: [
          p.join(album, 'cover.jpg'),
          p.join(album, 'Folder.PNG'),
          p.join(album, 'back.jpg'),
        ],
      );
      expect(_served(matches, track1), {
        'artwork:cover.jpg',
        'artwork:Folder.PNG',
      });
      expect(_served(matches, track2), {
        'artwork:cover.jpg',
        'artwork:Folder.PNG',
      });
    });

    test('nothing crosses a directory boundary', () {
      final here = p.join(album, 'Track01.mp3');
      final there = p.join(shows, 'Track01.mp3');
      final matches = associateSidecars(
        mediaFiles: [here, there],
        otherFiles: [p.join(album, 'cover.jpg'), p.join(album, 'Track01.lrc')],
      );
      expect(_served(matches, here), {
        'artwork:cover.jpg',
        'lyrics:Track01.lrc',
      });
      expect(matches, isNot(contains(there)));
    });

    test('unclaimed sidecars and unserved media do not appear', () {
      final track = p.join(album, 'Track01.mp3');
      final matches = associateSidecars(
        mediaFiles: [track],
        otherFiles: [
          p.join(album, 'Track02.lrc'),
          p.join(album, 'Orphan.srt'),
          p.join(album, 'back.jpg'),
        ],
      );
      expect(matches, isEmpty);
    });

    test('a directory mixing all three kinds sorts itself out', () {
      final track = p.join(album, 'Track01.mp3');
      final extras = p.join(album, 'Extras.mkv');
      final matches = associateSidecars(
        mediaFiles: [track, extras],
        otherFiles: [
          p.join(album, 'Track01.lrc'),
          p.join(album, 'Extras.en.srt'),
          p.join(album, 'cover.jpg'),
        ],
      );
      expect(_served(matches, track), {
        'lyrics:Track01.lrc',
        'artwork:cover.jpg',
      });
      expect(_served(matches, extras), {
        'subtitles:Extras.en.srt',
        'artwork:cover.jpg',
      });
    });
  });
}
