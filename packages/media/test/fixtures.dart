/// Named doors into the fixture corpus.
///
/// Everything under `test/fixtures/` is grown by `dart run tool/bin/cadence.dart fixtures`;
/// this file is the map. Tests take a getter, get an absolute path, and
/// never spell a fixture filename twice. The one asset the script cannot
/// make — an ID3v2.2 MP3, a dialect ffmpeg stopped speaking — is built by
/// hand in [Fixtures.id3v22Mp3].
library;

import 'dart:convert';
import 'package:cadence_media/src/filesystem.dart';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// The tiny media corpus, one getter per asset.
///
/// Paths are absolute, resolved by walking up from the working directory
/// until a `test/fixtures` (or `packages/media/test/fixtures`) appears —
/// so the helpers work whether tests run from the package or the
/// workspace root.
abstract final class Fixtures {
  /// The absolute path of the `test/fixtures` directory.
  static final String root = _findRoot();

  static String _findRoot() {
    var dir = mediaFileSystem.currentDirectory;
    while (true) {
      for (final candidate in [
        p.join(dir.path, 'test', 'fixtures'),
        p.join(dir.path, 'packages', 'media', 'test', 'fixtures'),
      ]) {
        if (mediaFileSystem.directory(candidate).existsSync()) return candidate;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) {
        throw StateError(
          'test/fixtures not found above ${mediaFileSystem.currentDirectory.path} — '
          'run dart run tool/bin/cadence.dart fixtures first',
        );
      }
      dir = parent;
    }
  }

  static String _at(String relative) => p.join(root, relative);

  // Audio.

  /// MP3, ID3v2.3: title/artist/album/track 1/8, year 2001, genre, and a
  /// TXXX `fixture_note` for the `extra` map to catch.
  static String get id3v23Mp3 => _at('audio/id3v23.mp3');

  /// MP3, ID3v2.4: track 2/8 and a full release date (`2001-03-12`).
  static String get id3v24Mp3 => _at('audio/id3v24.mp3');

  /// MP3 with an APIC front cover (the 32×32 [coverJpg]) riding inside.
  static String get apicMp3 => _at('audio/apic.mp3');

  /// MP3 tagged with ID3v1 *only* — the 128-byte `TAG` block at the tail,
  /// no v2 header. Title/artist/album/year/comment/track/genre all set.
  static String get id3v1Mp3 => _at('audio/id3v1.mp3');

  /// FLAC with vorbis comments (full date, track 3 of 8), MusicBrainz
  /// track/album/artist ids, ReplayGain track+album gain/peak, and an
  /// embedded PICTURE block.
  static String get taggedFlac => _at('audio/tagged.flac');

  /// Ogg Vorbis with TITLE/ARTIST/ALBUM/DATE comments.
  static String get vorbisOgg => _at('audio/vorbis.ogg');

  /// Opus (48kHz, as Opus insists) with TITLE/ARTIST/ALBUM comments.
  static String get toneOpus => _at('audio/tone.opus');

  /// M4A with the iTunes atoms: aART (album artist), cpil (compilation),
  /// track 5/8, disc 1/2.
  static String get itunesM4a => _at('audio/itunes.m4a');

  /// M4B audiobook with two chapters, "Chapter One" and "Chapter Two",
  /// splitting its 0.2 seconds evenly.
  static String get chaptersM4b => _at('audio/chapters.m4b');

  /// WAV with a RIFF INFO list: INAM/IART/IPRD/IGNR/ICRD.
  static String get riffWav => _at('audio/riff.wav');

  /// AIFF, deliberately untagged — technical properties only.
  static String get plainAiff => _at('audio/plain.aiff');

  /// WMA (wmav2 in ASF) with title and artist.
  static String get wmav2Wma => _at('audio/wmav2.wma');

  // Video.

  /// MP4, h264 16×16, container title "Test Card".
  static String get titledMp4 => _at('video/titled.mp4');

  /// MKV titled "Two Track Mind": one h264 video track, one AAC audio
  /// track, no subtitles.
  static String get titledMkv => _at('video/titled.mkv');
  static String get scenedMkv => _at('video/scened.mkv');

  /// WebM, VP9, untagged.
  static String get vp9Webm => _at('video/vp9.webm');

  /// AVI, MJPEG, untagged.
  static String get mjpegAvi => _at('video/mjpeg.avi');

  /// MKV whose embedded title is scene-release noise —
  /// `Cool.Show.S01E02.1080p.WEB-DL.x264-GRP` under the filename
  /// `Cool Show (2020) - S01E02.mkv` — for the title-displacement rule.
  static String get releaseNamedMkv =>
      _at('video/Cool Show (2020) - S01E02.mkv');

  /// MKV with no tags at all — `Fixture Show S01E02.mkv` — so series,
  /// season, and episode must come from the filename.
  static String get episodeMkv => _at('video/Fixture Show S01E02.mkv');

  // Images. All 8×8.

  /// JPEG with EXIF via exiftool: camera make/model/lens, ISO 200, 1/250s,
  /// f/2.8, 35mm, DateTimeOriginal 2020-05-17, GPS (51.5007N 0.1246W,
  /// 11.5m), orientation 1, and a description.
  static String get exifJpg => _at('image/exif.jpg');

  static String get tinyPng => _at('image/tiny.png');
  static String get tinyGif => _at('image/tiny.gif');
  static String get tinyWebp => _at('image/tiny.webp');
  static String get tinyBmp => _at('image/tiny.bmp');
  static String get tinyTiff => _at('image/tiny.tiff');

  // Documents.

  /// Minimal hand-written PDF: one page, and an Info dict with Title
  /// "Fixture Document", Author, and CreationDate.
  static String get infoPdf => _at('doc/info.pdf');

  /// EPUB 2 with title, creator, language, publisher, an ISBN identifier,
  /// a description, and one XHTML chapter.
  static String get bookEpub => _at('doc/book.epub');

  /// Plain text — no metadata anywhere; the filename is the title.
  static String get notesTxt => _at('doc/notes.txt');

  /// CBZ comic: two pages and a ComicInfo.xml (series, number 12.5,
  /// writer, publisher, summary).
  static String get issueCbz => _at('doc/issue.cbz');

  // Sidecars.

  /// LRC lyrics: three timestamped lines (plus `[ar:]`/`[ti:]` headers).
  static String get lyricsLrc => _at('sidecar/lyrics.lrc');

  /// SRT subtitles: two cues.
  static String get subsSrt => _at('sidecar/subs.srt');

  /// 32×32 JPEG folder art — the same image the audio fixtures embed.
  static String get coverJpg => _at('sidecar/cover.jpg');

  /// Writes an ID3v2.2-tagged MP3 into [dir] and returns its path.
  ///
  /// ffmpeg no longer writes v2.2, so the tag is assembled by hand and
  /// grafted onto a copy of [id3v1Mp3] (whose trailing ID3v1 block rides
  /// along — a v2.2 + v1 pairing, exactly what elderly files look like).
  ///
  /// Byte layout, per the informal id3v2.2 spec:
  ///
  ///     tag header    "ID3"  $02 00  flags $00  size (4 × 7-bit syncsafe)
  ///     frame         id (3 ascii)   size (3 bytes, big-endian, plain)
  ///     frame body    encoding $00 (ISO-8859-1)  text bytes, no terminator
  ///
  /// Two frames are written: `TT2` (title) and `TP1` (artist).
  static String id3v22Mp3(
    Directory dir, {
    String title = 'Deux Point Deux',
    String artist = 'The Fixtures',
  }) {
    final frames = BytesBuilder()
      ..add(_v22Frame('TT2', title))
      ..add(_v22Frame('TP1', artist));
    final body = frames.toBytes();
    final header = Uint8List(10)
      ..setAll(0, const [0x49, 0x44, 0x33, 0x02, 0x00, 0x00])
      ..[6] = (body.length >> 21) & 0x7f
      ..[7] = (body.length >> 14) & 0x7f
      ..[8] = (body.length >> 7) & 0x7f
      ..[9] = body.length & 0x7f;
    final out = mediaFileSystem.file(p.join(dir.path, 'id3v22.mp3'));
    out.writeAsBytesSync([
      ...header,
      ...body,
      ...mediaFileSystem.file(id3v1Mp3).readAsBytesSync(),
    ], flush: true);
    return out.path;
  }

  static Uint8List _v22Frame(String id, String text) {
    final content = [0x00, ...latin1.encode(text)];
    return Uint8List.fromList([
      ...ascii.encode(id),
      (content.length >> 16) & 0xff,
      (content.length >> 8) & 0xff,
      content.length & 0xff,
      ...content,
    ]);
  }
}
