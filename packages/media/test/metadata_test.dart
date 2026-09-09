import 'test_filesystem.dart';
import 'dart:convert';

import 'package:cadence_media/cadence_media.dart';
import 'package:test/test.dart'
    hide test, setUp, tearDown, setUpAll, tearDownAll, addTearDown;

/// The metadata model's contract: full JSON survives the round trip
/// untouched, legacy v2 rows decode (and re-encode) unchanged, and empty
/// collections never leak into the JSON.
void main() => memoryTests(registerTests);
void registerTests() {
  group('full round trips', () {
    test('audio: every field there and back', () {
      final decoded =
          MediaMetadata.fromJson(MediaKind.audio, _fullAudio) as AudioMetadata;

      expect(decoded.title, 'Choir of Static');
      expect(decoded.artists, ['Cathode Ray Choir', 'Velvet Modem']);
      expect(
        decoded.chapters.first,
        const ChapterMark('Broadcast', Duration.zero),
      );
      expect(decoded.musicBrainz?.recordingId, 'rec-1234');
      expect(decoded.replayGain?.trackGain, -6.4);
      expect(decoded.lossless, isTrue);
      expect(decoded.extra['TXXX:CUSTOM'], 'y');

      expect(decoded.toJson(), _fullAudio);
      expect(jsonDecode(jsonEncode(decoded.toJson())), _fullAudio);
    });

    test('video: every field there and back', () {
      final decoded =
          MediaMetadata.fromJson(MediaKind.video, _fullVideo) as VideoMetadata;

      expect(decoded.frameRate, 23.976);
      expect(decoded.subtitleLanguages, ['en', 'es']);
      expect(decoded.chapters, hasLength(1));

      expect(decoded.toJson(), _fullVideo);
      expect(jsonDecode(jsonEncode(decoded.toJson())), _fullVideo);
    });

    test('image: every field there and back', () {
      final decoded =
          MediaMetadata.fromJson(MediaKind.image, _fullImage) as ImageMetadata;

      expect(decoded.takenAt, DateTime.utc(2001, 10, 14, 2));
      expect(decoded.cameraModel, 'PowerShot G2');
      expect(decoded.gpsLatitude, 45.523);

      expect(decoded.toJson(), _fullImage);
      expect(jsonDecode(jsonEncode(decoded.toJson())), _fullImage);
    });

    test('document: every field there and back', () {
      final decoded =
          MediaMetadata.fromJson(MediaKind.document, _fullDocument)
              as DocumentMetadata;

      expect(decoded.authors, ['Ada Winters', 'June Satellite']);
      expect(decoded.pageCount, 214);

      expect(decoded.toJson(), _fullDocument);
      expect(jsonDecode(jsonEncode(decoded.toJson())), _fullDocument);
    });
  });

  group('legacy v2 rows', () {
    test('audio decodes with new fields absent, re-encodes unchanged', () {
      const legacy = <String, Object?>{
        'title': 'Handshake',
        'artist': 'Velvet Modem',
        'album': 'Static Bloom',
        'albumArtist': 'Velvet Modem',
        'year': 1997,
        'trackNumber': 3,
        'durationMs': 302000,
        'bitrateKbps': 320,
      };
      final decoded = AudioMetadata.fromJson(legacy);
      expect(decoded.title, 'Handshake');
      expect(decoded.year, 1997);
      expect(decoded.sortTitle, isNull);
      expect(decoded.date, isNull);
      expect(decoded.compilation, isNull);
      expect(decoded.musicBrainz, isNull);
      expect(decoded.replayGain, isNull);
      expect(decoded.artists, isEmpty);
      expect(decoded.genres, isEmpty);
      expect(decoded.chapters, isEmpty);
      expect(decoded.extra, isEmpty);
      expect(decoded.toJson(), legacy);
    });

    test('video decodes with new fields absent, re-encodes unchanged', () {
      const legacy = <String, Object?>{
        'title': 'Vertical Hold',
        'year': 1999,
        'durationMs': 1398000,
        'series': 'Test Pattern After Dark',
        'season': 1,
        'episode': 3,
      };
      final decoded = VideoMetadata.fromJson(legacy);
      expect(decoded.series, 'Test Pattern After Dark');
      expect(decoded.width, isNull);
      expect(decoded.frameRate, isNull);
      expect(decoded.genres, isEmpty);
      expect(decoded.subtitleLanguages, isEmpty);
      expect(decoded.chapters, isEmpty);
      expect(decoded.extra, isEmpty);
      expect(decoded.toJson(), legacy);
    });

    test('image decodes with new fields absent, re-encodes unchanged', () {
      final legacy = <String, Object?>{
        'title': 'Overpass at 2AM',
        'takenAt': DateTime.utc(2001, 10, 14).toIso8601String(),
        'width': 3840,
        'height': 1600,
      };
      final decoded = ImageMetadata.fromJson(legacy);
      expect(decoded.width, 3840);
      expect(decoded.cameraMake, isNull);
      expect(decoded.iso, isNull);
      expect(decoded.gpsLatitude, isNull);
      expect(decoded.extra, isEmpty);
      expect(decoded.toJson(), legacy);
    });

    test('document decodes with new fields absent, re-encodes unchanged', () {
      const legacy = <String, Object?>{
        'title': 'Static Bloom — Liner Notes',
        'author': 'Velvet Modem',
      };
      final decoded = DocumentMetadata.fromJson(legacy);
      expect(decoded.author, 'Velvet Modem');
      expect(decoded.authors, isEmpty);
      expect(decoded.pageCount, isNull);
      expect(decoded.extra, isEmpty);
      expect(decoded.toJson(), legacy);
    });
  });

  group('empty collections stay out of the JSON', () {
    test('audio', () {
      const bare = AudioMetadata(title: 'Test Pattern', extra: {});
      final json = bare.toJson();
      expect(json, {'title': 'Test Pattern'});
      expect(json.containsKey('extra'), isFalse);
      expect(json.containsKey('artists'), isFalse);
      expect(json.containsKey('chapters'), isFalse);
    });

    test('video', () {
      const bare = VideoMetadata(title: 'Sign-Off', extra: {});
      expect(bare.toJson(), {'title': 'Sign-Off'});
    });

    test('image', () {
      const bare = ImageMetadata(title: 'Cathode Bloom', extra: {});
      expect(bare.toJson(), {'title': 'Cathode Bloom'});
    });

    test('document', () {
      const bare = DocumentMetadata(title: 'The Carrier Tone', extra: {});
      expect(bare.toJson(), {'title': 'The Carrier Tone'});
    });
  });

  group('the year and the date', () {
    test('year derives from the date when only the date was tagged', () {
      const dated = AudioMetadata(title: 'x', date: '2001-03-12');
      expect(dated.year, 2001);
    });

    test('a tagged year outranks the date', () {
      const both = AudioMetadata(title: 'x', year: 1999, date: '2001-03-12');
      expect(both.year, 1999);
    });

    test('a derived year is not written back to JSON', () {
      const dated = AudioMetadata(title: 'x', date: '2001-03-12');
      expect(dated.toJson(), {'title': 'x', 'date': '2001-03-12'});
    });

    test('a date with no leading year derives nothing', () {
      const vague = AudioMetadata(title: 'x', date: 'sometime in spring');
      expect(vague.year, isNull);
    });
  });

  group('value types', () {
    test('ChapterMark speaks {title, startMs}', () {
      const mark = ChapterMark('Sign-Off', Duration(minutes: 3, seconds: 21));
      expect(mark.toJson(), {'title': 'Sign-Off', 'startMs': 201000});
      expect(ChapterMark.fromJson(mark.toJson()), mark);
    });

    test('MusicBrainzIds omits what it does not know', () {
      const ids = MusicBrainzIds(recordingId: 'rec-1', releaseId: 'rel-2');
      expect(ids.toJson(), {'recordingId': 'rec-1', 'releaseId': 'rel-2'});
      expect(MusicBrainzIds.fromJson(ids.toJson()), ids);
    });

    test('ReplayGain round trips its four measurements', () {
      const gain = ReplayGain(
        trackGain: -6.4,
        trackPeak: 0.988,
        albumGain: -7.1,
        albumPeak: 1.0,
      );
      expect(ReplayGain.fromJson(gain.toJson()), gain);
      expect(const ReplayGain(trackGain: -1.0).toJson(), {'trackGain': -1.0});
    });
  });
}

const _fullAudio = <String, Object?>{
  'title': 'Choir of Static',
  'artist': 'Cathode Ray Choir',
  'album': 'Last Transmission',
  'albumArtist': 'Cathode Ray Choir',
  'year': 2001,
  'trackNumber': 3,
  'durationMs': 388000,
  'bitrateKbps': 964,
  'sortTitle': 'Choir of Static',
  'sortArtist': 'Cathode Ray Choir',
  'sortAlbum': 'Last Transmission',
  'sortAlbumArtist': 'Cathode Ray Choir',
  'artists': ['Cathode Ray Choir', 'Velvet Modem'],
  'composers': ['J. Winters'],
  'lyricists': ['A. Winters'],
  'genres': ['Electronic', 'Shoegaze'],
  'conductor': 'M. Static',
  'remixer': 'DJ Halcyon',
  'grouping': 'Broadcast Suite',
  'comment': 'From the final broadcast.',
  'lyrics': 'Sing the static down',
  'language': 'eng',
  'initialKey': 'F#m',
  'isrc': 'USRC10101234',
  'barcode': '724384960650',
  'catalogNumber': 'CRC-2001',
  'label': 'Test Pattern Records',
  'encoder': 'FLAC 1.4.3',
  'media': 'CD',
  'mood': 'Elegiac',
  'codec': 'flac',
  'date': '2001-10-30',
  'trackTotal': 4,
  'discNumber': 1,
  'discTotal': 2,
  'bpm': 118,
  'sampleRateHz': 44100,
  'channels': 2,
  'bitsPerSample': 16,
  'originalYear': 2000,
  'rating': 90,
  'compilation': false,
  'lossless': true,
  'chapters': [
    {'title': 'Broadcast', 'startMs': 0},
    {'title': 'Sign-Off', 'startMs': 201000},
  ],
  'musicBrainz': {
    'recordingId': 'rec-1234',
    'trackId': 'trk-1234',
    'releaseId': 'rel-1234',
    'releaseGroupId': 'rg-1234',
    'artistId': 'art-1234',
    'albumArtistId': 'aa-1234',
    'workId': 'wrk-1234',
  },
  'acoustId': 'ac-1234',
  'replayGain': {
    'trackGain': -6.4,
    'trackPeak': 0.988,
    'albumGain': -7.1,
    'albumPeak': 1.0,
  },
  'extra': {'MUSICBRAINZ_ALBUMID': 'x', 'TXXX:CUSTOM': 'y'},
};

const _fullVideo = <String, Object?>{
  'title': 'Adjust Your Set',
  'year': 1999,
  'durationMs': 1445000,
  'series': 'Test Pattern After Dark',
  'season': 1,
  'episode': 2,
  'width': 1920,
  'height': 1080,
  'frameRate': 23.976,
  'videoCodec': 'h264',
  'audioCodec': 'aac',
  'container': 'mkv',
  'date': '1999-05-14',
  'genres': ['Late Night'],
  'comment': 'Broadcast master.',
  'subtitleLanguages': ['en', 'es'],
  'chapters': [
    {'title': 'Cold Open', 'startMs': 0},
  ],
  'extra': {'ENCODER': 'libmatroska'},
};

const _fullImage = <String, Object?>{
  'title': 'Overpass at 2AM',
  'takenAt': '2001-10-14T02:00:00.000Z',
  'width': 3840,
  'height': 1600,
  'cameraMake': 'Canon',
  'cameraModel': 'PowerShot G2',
  'lensModel': 'EF 35mm f/2',
  'orientation': 6,
  'iso': 800,
  'exposureSeconds': 0.05,
  'fNumber': 2.0,
  'focalLengthMm': 35.0,
  'gpsLatitude': 45.523,
  'gpsLongitude': -122.676,
  'gpsAltitude': 15.2,
  'description': 'Sodium lights over the interstate.',
  'extra': {'EXIF:Software': 'darktable'},
};

const _fullDocument = <String, Object?>{
  'title': 'The Carrier Tone',
  'author': 'Ada Winters',
  'authors': ['Ada Winters', 'June Satellite'],
  'language': 'en',
  'publisher': 'Test Pattern Press',
  'isbn': '9780316769488',
  'description': 'A novel of the last broadcast.',
  'pageCount': 214,
  'series': 'The Dial Trilogy',
  'extra': {'calibre:series_index': '1'},
};
