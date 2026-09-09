import '../filesystem.dart';

import 'package:audio_metadata_reader/audio_metadata_reader.dart' as amr;

import '../database/database.dart';
import '../kinds.dart';
import '../metadata.dart';
import 'audio_tech.dart';
import 'extractor.dart';

/// The pure-Dart audio tier.
///
/// audio_metadata_reader does the heavy lifting through its
/// format-specific structs, so nothing a tagger wrote is normalized away:
/// Vorbis unknowns and TXXX frames land in `extra`, and the well-known
/// wanderers among them — MusicBrainz ids, ReplayGain, album artists,
/// sort names — are mined back into typed fields. What the package cannot
/// see, the header readers in `audio_tech.dart` supply: FLAC STREAMINFO,
/// the WAV `fmt ` chunk, MP3 frame headers, ID3v2.2, and the iTunes atoms
/// it never learned. Corrupt input never throws — a file with nothing to
/// say gets a `null`.
class AudioExtractor implements MetadataExtractor {
  const AudioExtractor({this.fileSystem});
  final FileSystem? fileSystem;

  static const _extensions = {
    'mp3', 'flac', 'ogg', 'oga', 'opus', 'm4a', 'm4b', 'aac', //
    'wav', 'aiff', 'aif', 'ape', 'wv', 'wma', 'mka',
  };

  @override
  bool handles(MediaKind kind, String extension) =>
      kind == MediaKind.audio && _extensions.contains(extension);

  @override
  Future<ExtractionResult?> extract(String path, MediaKind kind) =>
      withMediaFileSystem(
        fileSystem ?? mediaFileSystem,
        () => _extractScoped(path, kind),
      );

  Future<ExtractionResult?> _extractScoped(String path, MediaKind kind) async {
    try {
      return _extract(path);
    } catch (_) {
      return null;
    }
  }

  ExtractionResult? _extract(String path) {
    final extension = _extensionOf(path);

    // The one dialect the package garbles rather than skips: read it
    // by hand before letting the parsers near it.
    final v22 = readId3v22(path);
    if (v22 != null) return _fromId3v22(v22, path);

    Object? tag;
    try {
      tag = amr.readAllMetadata(mediaFileSystem.file(path));
    } catch (_) {
      tag = null;
    }
    switch (tag) {
      case final amr.Mp3Metadata m:
        return _fromMp3(m, path);
      case final amr.VorbisMetadata m:
        return _fromVorbis(m, path, extension);
      case final amr.Mp4Metadata m:
        return _fromMp4(m, path);
      case final amr.RiffMetadata m:
        return _fromRiff(m, path, extension);
      case final amr.ApeMetadata m:
        return _fromApe(m, path);
    }

    // The normalized reader as a fallback, then bare header facts, then
    // an honest null. (WMA lands here: no pure-Dart parser speaks ASF —
    // the native probe owns it.)
    try {
      return _fromGeneric(
        amr.readMetadata(mediaFileSystem.file(path), getImage: true),
      );
    } catch (_) {
      return _fromTechOnly(path, extension);
    }
  }

  ExtractionResult _fromId3v22(Id3v22Tag tag, String path) {
    final tech = readMp3FrameHeader(path);
    return ExtractionResult(
      metadata: AudioMetadata(
        title: tag.title ?? '',
        artist: tag.artist,
        album: tag.album,
        albumArtist: tag.albumArtist,
        composers: _names([tag.composer]),
        genres: _names([tag.genre]),
        year: tag.year,
        trackNumber: tag.trackNumber ?? readId3v1Track(path),
        trackTotal: tag.trackTotal,
        sampleRateHz: tech?.sampleRateHz,
        channels: tech?.channels,
        codec: 'mp3',
        lossless: false,
      ),
    );
  }

  ExtractionResult _fromMp3(amr.Mp3Metadata m, String path) {
    final mined = _Mined();
    m.customMetadata.forEach((key, value) {
      if (!mined.claim(key, value)) {
        mined.keep('TXXX:$key', _clean(value));
      }
    });
    mined
      ..keep('TCOP', m.copyrightMessage)
      ..keep('TIT3', m.subtitle)
      ..keep('TOAL', m.originalAlbum)
      ..keep('TOPE', m.originalArtist)
      ..keep('TOWN', m.fileOwner)
      ..keep('TDAT', m.date);

    final tech = readMp3FrameHeader(path);
    final popularity = m.popularimeter;
    return ExtractionResult(
      metadata: AudioMetadata(
        title: m.songName ?? '',
        artist: m.leadPerformer ?? m.bandOrOrchestra ?? m.originalArtist,
        album: m.album,
        albumArtist: m.bandOrOrchestra ?? mined.albumArtist,
        year: m.year,
        date: mined.date,
        trackNumber: m.trackNumber ?? readId3v1Track(path),
        trackTotal: m.trackTotal,
        discNumber: m.discNumber,
        discTotal: m.totalDics,
        duration: _positive(m.duration),
        bitrateKbps: _kbps(m.bitrate),
        sampleRateHz: m.samplerate ?? tech?.sampleRateHz,
        channels: tech?.channels,
        sortTitle: mined.sortTitle,
        sortArtist: mined.sortArtist,
        sortAlbum: mined.sortAlbum,
        sortAlbumArtist: mined.sortAlbumArtist,
        composers: _names([m.composer]),
        lyricists: _names([m.textWriter]),
        genres: _names(m.genres),
        conductor: m.conductor ?? mined.conductor,
        remixer: m.interpreted ?? mined.remixer,
        grouping: m.contentGroupDescription ?? mined.grouping,
        comment: _text(m.comments.firstOrNull?.text),
        lyrics: _text(m.lyric),
        language: m.languages ?? mined.language,
        initialKey: m.initialKey,
        isrc: m.isrc ?? mined.isrc,
        barcode: mined.barcode,
        catalogNumber: mined.catalogNumber,
        label: m.publisher ?? mined.label,
        encoder: m.encoderSoftware ?? m.encodedBy,
        media: m.mediatype ?? mined.media,
        mood: mined.mood,
        bpm: _int(m.bpm) ?? mined.bpm,
        originalYear: m.originalReleaseYear ?? mined.originalYear,
        rating: popularity == null
            ? null
            : (popularity.rating.clamp(0, 255) * 100 / 255).round(),
        compilation: mined.compilation,
        codec: 'mp3',
        lossless: false,
        musicBrainz: mined.musicBrainz,
        acoustId: mined.acoustId,
        replayGain: mined.replayGain,
        extra: mined.extra,
      ),
      artwork: _artworkOf(m.pictures),
    );
  }

  ExtractionResult _fromVorbis(
    amr.VorbisMetadata m,
    String path,
    String extension,
  ) {
    final mined = _Mined();
    m.unknowns.forEach((key, value) {
      if (!mined.claim(key, value)) mined.keep(key, _clean(value));
    });
    mined
      ..keepAll('VERSION', m.version)
      ..keepAll('COPYRIGHT', m.copyright)
      ..keepAll('LICENSE', m.license)
      ..keepAll('DESCRIPTION', m.description)
      ..keepAll('LOCATION', m.location)
      ..keepAll('CONTACT', m.contact)
      ..keepAll('ACTOR', m.actor)
      ..keepAll('DIRECTOR', m.director)
      ..keepAll('PRODUCER', m.producer)
      ..keepAll('ENCODED_BY', m.encodedBy)
      ..keepAll('ENCODED_USING', m.encodedUsing)
      ..keepAll('ENCODER_OPTIONS', m.encoderOptions);

    final codec = extension == 'flac'
        ? 'flac'
        : sniffOggCodec(path) ?? (extension == 'opus' ? 'opus' : 'vorbis');
    final streamInfo = codec == 'flac' ? readFlacStreamInfo(path) : null;
    final calendar = _calendar(m.date.firstOrNull);

    // The comment parser folds ALBUMARTIST into the artist list, so every
    // name it gathered is a credit; the first one fronts the sleeve.
    final credited = _names([...m.artist, ...m.performer]);

    return ExtractionResult(
      metadata: AudioMetadata(
        title: m.title.firstOrNull ?? '',
        artist: m.artist.firstOrNull,
        album: m.album.firstOrNull,
        albumArtist: mined.albumArtist,
        artists: credited.length > 1 ? credited : const [],
        year: calendar.year,
        date: calendar.date,
        trackNumber: m.trackNumber.firstOrNull,
        trackTotal: m.trackTotal,
        discNumber: m.discNumber,
        discTotal: m.discTotal,
        duration: _positive(m.duration),
        // The package's FLAC "bitrate" is a synthesis and the Opus one a
        // misread; only Vorbis reports a nominal rate worth keeping.
        bitrateKbps: codec == 'vorbis' ? _kbps(m.bitrate) : null,
        sampleRateHz: streamInfo?.sampleRateHz ?? m.sampleRate,
        channels: streamInfo?.channels,
        bitsPerSample: streamInfo?.bitsPerSample,
        sortTitle: mined.sortTitle,
        sortArtist: mined.sortArtist,
        sortAlbum: mined.sortAlbum,
        sortAlbumArtist: mined.sortAlbumArtist,
        composers: _names(m.composer),
        genres: _names(m.genres),
        conductor: mined.conductor,
        remixer: mined.remixer,
        grouping: mined.grouping,
        comment: _text(m.comment.firstOrNull),
        lyrics: _text(m.lyric),
        language: m.language.firstOrNull ?? mined.language,
        isrc: m.isrc.firstOrNull ?? mined.isrc,
        barcode: mined.barcode,
        catalogNumber: mined.catalogNumber,
        label: m.organization.firstOrNull ?? mined.label,
        encoder: m.encoder.firstOrNull,
        media: mined.media,
        mood: mined.mood,
        bpm: mined.bpm,
        originalYear: mined.originalYear,
        compilation: mined.compilation,
        codec: codec,
        lossless: codec == 'flac',
        musicBrainz: mined.musicBrainz,
        acoustId: mined.acoustId,
        replayGain: _replayGain(m, mined),
        extra: mined.extra,
      ),
      artwork: _artworkOf(m.pictures),
    );
  }

  ExtractionResult _fromMp4(amr.Mp4Metadata m, String path) {
    final extras = readMp4Extras(path);
    final mined = _Mined();
    extras?.freeform.forEach((key, value) {
      final name = key.substring(key.lastIndexOf(':') + 1);
      if (!mined.claim(name, value)) mined.keep(key, _clean(value));
    });
    final calendar = _calendar(m.year);
    final codec = extras?.codec;

    return ExtractionResult(
      metadata: AudioMetadata(
        title: m.title ?? '',
        artist: m.artist,
        album: m.album,
        albumArtist: extras?.albumArtist ?? mined.albumArtist,
        year: calendar.year,
        date: calendar.date,
        trackNumber: m.trackNumber,
        trackTotal: m.totalTracks,
        discNumber: m.discNumber,
        discTotal: m.totalDiscs,
        duration: _positive(m.duration),
        bitrateKbps: _kbps(m.bitrate),
        sampleRateHz: m.sampleRate,
        sortTitle: extras?.sortTitle ?? mined.sortTitle,
        sortArtist: extras?.sortArtist ?? mined.sortArtist,
        sortAlbum: extras?.sortAlbum ?? mined.sortAlbum,
        sortAlbumArtist: extras?.sortAlbumArtist ?? mined.sortAlbumArtist,
        genres: _names([m.genre]),
        lyrics: _text(m.lyrics),
        isrc: mined.isrc,
        barcode: mined.barcode,
        catalogNumber: mined.catalogNumber,
        label: mined.label,
        media: mined.media,
        mood: mined.mood,
        bpm: mined.bpm,
        originalYear: mined.originalYear,
        compilation: extras?.compilation ?? mined.compilation,
        codec: codec,
        lossless: codec == null ? null : codec == 'alac' || codec == 'pcm',
        chapters: [
          for (final chapter in m.chapters)
            ChapterMark(chapter.title, chapter.start),
        ],
        musicBrainz: mined.musicBrainz,
        acoustId: mined.acoustId,
        replayGain: mined.replayGain,
        extra: mined.extra,
      ),
      artwork: _artworkOf([?m.picture]),
    );
  }

  ExtractionResult _fromRiff(
    amr.RiffMetadata m,
    String path,
    String extension,
  ) {
    final isWav = extension == 'wav';
    final format = isWav ? readWavFormat(path) : null;
    final mined = _Mined()..keep(isWav ? 'ICOP' : '(c) ', _text(m.copyright));

    return ExtractionResult(
      metadata: AudioMetadata(
        title: m.title ?? '',
        artist: m.artist,
        album: m.album,
        year: m.year == null || m.year!.year == 0 ? null : m.year!.year,
        trackNumber: m.trackNumber,
        duration: _positive(m.duration),
        // RiffMetadata's "bitrate" is the byte rate the header declares.
        bitrateKbps: format?.bitrateKbps ?? _byteRateKbps(m.bitrate),
        sampleRateHz: format?.sampleRateHz ?? m.samplerate,
        channels: format?.channels,
        bitsPerSample: format?.bitsPerSample,
        genres: _names([m.genre]),
        comment: _text(m.comment),
        encoder: m.encoder,
        label: m.publisher,
        codec: format?.codec ?? 'pcm',
        lossless: true,
        extra: mined.extra,
      ),
      artwork: _artworkOf(m.pictures),
    );
  }

  ExtractionResult _fromApe(amr.ApeMetadata m, String path) {
    final mined = _Mined();
    m.unknowns.forEach((key, value) {
      if (!mined.claim(key, value)) mined.keep(key, _clean(value));
    });
    mined.keep('COPYRIGHT', _text(m.copyright));
    final calendar = _calendar(m.date);
    final credited = _names([?m.artist, ...m.performer]);

    return ExtractionResult(
      metadata: AudioMetadata(
        title: m.title ?? '',
        artist: m.artist,
        album: m.album,
        albumArtist: m.albumArtist ?? mined.albumArtist,
        artists: credited.length > 1 ? credited : const [],
        year: calendar.year,
        date: calendar.date,
        trackNumber: m.trackNumber,
        trackTotal: m.trackTotal,
        discNumber: m.discNumber,
        discTotal: m.discTotal,
        duration: _positive(m.duration),
        bitrateKbps: _kbps(m.bitrate),
        sampleRateHz: m.sampleRate,
        sortTitle: mined.sortTitle,
        sortArtist: mined.sortArtist,
        sortAlbum: mined.sortAlbum,
        sortAlbumArtist: mined.sortAlbumArtist,
        composers: _names([m.composer]),
        genres: _names(m.genres),
        comment: _text(m.comment),
        lyrics: _text(m.lyric),
        language: m.language.firstOrNull ?? mined.language,
        isrc: mined.isrc,
        barcode: mined.barcode,
        catalogNumber: mined.catalogNumber,
        label: mined.label,
        encoder: m.encodedBy,
        media: mined.media,
        mood: mined.mood,
        bpm: mined.bpm,
        originalYear: mined.originalYear,
        compilation: mined.compilation,
        musicBrainz: mined.musicBrainz,
        acoustId: mined.acoustId,
        replayGain: mined.replayGain,
        extra: mined.extra,
      ),
      artwork: _artworkOf(m.pictures),
    );
  }

  ExtractionResult _fromGeneric(amr.AudioMetadata m) {
    final calendar = _calendar(m.year);
    return ExtractionResult(
      metadata: AudioMetadata(
        title: m.title ?? '',
        artist: m.artist,
        album: m.album,
        artists: _names(m.performers),
        year: calendar.year,
        date: calendar.date,
        trackNumber: m.trackNumber,
        trackTotal: m.trackTotal,
        discNumber: m.discNumber,
        discTotal: m.totalDisc,
        duration: _positive(m.duration),
        bitrateKbps: _kbps(m.bitrate),
        sampleRateHz: m.sampleRate,
        genres: _names(m.genres),
        lyrics: _text(m.lyrics),
        language: m.language,
        chapters: [
          for (final chapter in m.chapters)
            ChapterMark(chapter.title, chapter.start),
        ],
      ),
      artwork: _artworkOf(m.pictures),
    );
  }

  /// When every parser has walked away, the header bytes still get their
  /// say — a FLAC or WAV with unreadable tags keeps its stream facts.
  ExtractionResult? _fromTechOnly(String path, String extension) {
    final info = switch (extension) {
      'flac' => readFlacStreamInfo(path),
      'wav' => readWavFormat(path),
      'mp3' => readMp3FrameHeader(path),
      _ => null,
    };
    if (info == null) return null;
    return ExtractionResult(
      metadata: AudioMetadata(
        title: '',
        sampleRateHz: info.sampleRateHz,
        channels: info.channels,
        bitsPerSample: info.bitsPerSample,
        bitrateKbps: info.bitrateKbps,
        codec: info.codec,
        lossless: extension == 'flac' || extension == 'wav',
      ),
    );
  }

  List<ExtractedArtwork> _artworkOf(Iterable<amr.Picture> pictures) => [
    for (final picture in pictures)
      if (picture.bytes.isNotEmpty)
        ExtractedArtwork(
          bytes: picture.bytes,
          mime: picture.mimetype.contains('/')
              ? picture.mimetype.trim()
              : sniffImageMime(picture.bytes),
          role: ArtworkRole.embedded,
        ),
  ];

  ReplayGain? _replayGain(amr.VorbisMetadata m, _Mined mined) {
    final trackGain =
        _decibels(m.replayGainTrackGain.firstOrNull) ?? mined.rgTrackGain;
    final trackPeak =
        _double(m.replayGainTrackPeak.firstOrNull) ?? mined.rgTrackPeak;
    final albumGain =
        _decibels(m.replayGainAlbumGain.firstOrNull) ?? mined.rgAlbumGain;
    final albumPeak =
        _double(m.replayGainAlbumPeak.firstOrNull) ?? mined.rgAlbumPeak;
    if (trackGain == null &&
        trackPeak == null &&
        albumGain == null &&
        albumPeak == null) {
      return null;
    }
    return ReplayGain(
      trackGain: trackGain,
      trackPeak: trackPeak,
      albumGain: albumGain,
      albumPeak: albumPeak,
    );
  }

  String _extensionOf(String path) {
    final extension = mediaPath.extension(path);
    return extension.isEmpty ? '' : extension.substring(1).toLowerCase();
  }
}

/// The typed homes for tags that arrive under many spellings. [claim]
/// files a key it recognizes and reports whether it did; unclaimed keys
/// are the caller's to [keep] in `extra`.
class _Mined {
  String? albumArtist;
  String? sortTitle;
  String? sortArtist;
  String? sortAlbum;
  String? sortAlbumArtist;
  String? conductor;
  String? remixer;
  String? grouping;
  String? language;
  String? isrc;
  String? barcode;
  String? catalogNumber;
  String? label;
  String? media;
  String? mood;
  String? date;
  String? acoustId;
  int? bpm;
  int? originalYear;
  bool? compilation;

  String? _recordingId;
  String? _trackId;
  String? _releaseId;
  String? _releaseGroupId;
  String? _artistId;
  String? _albumArtistId;
  String? _workId;

  double? rgTrackGain;
  double? rgTrackPeak;
  double? rgAlbumGain;
  double? rgAlbumPeak;

  final Map<String, Object?> extra = {};

  bool claim(String key, String value) {
    final text = _clean(value);
    if (text.isEmpty) return true;
    switch (key.toUpperCase().replaceAll(_notAlphanumeric, '')) {
      case 'MUSICBRAINZTRACKID' || 'MUSICBRAINZRECORDINGID':
        _recordingId ??= text;
      case 'MUSICBRAINZRELEASETRACKID':
        _trackId ??= text;
      case 'MUSICBRAINZALBUMID' || 'MUSICBRAINZRELEASEID':
        _releaseId ??= text;
      case 'MUSICBRAINZRELEASEGROUPID':
        _releaseGroupId ??= text;
      case 'MUSICBRAINZARTISTID':
        _artistId ??= text;
      case 'MUSICBRAINZALBUMARTISTID':
        _albumArtistId ??= text;
      case 'MUSICBRAINZWORKID':
        _workId ??= text;
      case 'ACOUSTIDID':
        acoustId ??= text;
      case 'REPLAYGAINTRACKGAIN':
        rgTrackGain ??= _decibels(text);
      case 'REPLAYGAINTRACKPEAK':
        rgTrackPeak ??= _double(text);
      case 'REPLAYGAINALBUMGAIN':
        rgAlbumGain ??= _decibels(text);
      case 'REPLAYGAINALBUMPEAK':
        rgAlbumPeak ??= _double(text);
      case 'ALBUMARTIST' || 'BAND':
        albumArtist ??= text;
      case 'TITLESORT' || 'SORTTITLE' || 'TITLESORTORDER':
        sortTitle ??= text;
      case 'ARTISTSORT' || 'SORTARTIST' || 'ARTISTSORTORDER':
        sortArtist ??= text;
      case 'ALBUMSORT' || 'SORTALBUM' || 'ALBUMSORTORDER':
        sortAlbum ??= text;
      case 'ALBUMARTISTSORT' || 'SORTALBUMARTIST' || 'ALBUMARTISTSORTORDER':
        sortAlbumArtist ??= text;
      case 'CONDUCTOR':
        conductor ??= text;
      case 'REMIXER' || 'MIXARTIST':
        remixer ??= text;
      case 'GROUPING' || 'CONTENTGROUP':
        grouping ??= text;
      case 'LANGUAGE':
        language ??= text;
      case 'ISRC':
        isrc ??= text;
      case 'BARCODE':
        barcode ??= text;
      case 'CATALOGNUMBER' || 'CATALOGUENUMBER' || 'LABELNO':
        catalogNumber ??= text;
      case 'LABEL' || 'ORGANIZATION' || 'PUBLISHER':
        label ??= text;
      case 'MEDIA':
        media ??= text;
      case 'MOOD':
        mood ??= text;
      case 'DATE':
        date ??= text;
      case 'BPM':
        bpm ??= _double(text)?.round();
      case 'ORIGINALYEAR':
        originalYear ??= int.tryParse(text);
      case 'ORIGINALDATE':
        originalYear ??= _leadingYear(text);
      case 'COMPILATION' || 'ITUNESCOMPILATION':
        compilation ??=
            const {'1', 'true', 'yes'} //
                .contains(text.toLowerCase());
      default:
        return false;
    }
    return true;
  }

  void keep(String key, String? value) {
    if (value != null && value.isNotEmpty) extra.putIfAbsent(key, () => value);
  }

  void keepAll(String key, List<String> values) {
    final cleaned = [
      for (final value in values)
        if (_clean(value).isNotEmpty) _clean(value),
    ];
    if (cleaned.isEmpty) return;
    extra.putIfAbsent(key, () => cleaned.length == 1 ? cleaned.first : cleaned);
  }

  MusicBrainzIds? get musicBrainz {
    if (_recordingId == null &&
        _trackId == null &&
        _releaseId == null &&
        _releaseGroupId == null &&
        _artistId == null &&
        _albumArtistId == null &&
        _workId == null) {
      return null;
    }
    return MusicBrainzIds(
      recordingId: _recordingId,
      trackId: _trackId,
      releaseId: _releaseId,
      releaseGroupId: _releaseGroupId,
      artistId: _artistId,
      albumArtistId: _albumArtistId,
      workId: _workId,
    );
  }

  ReplayGain? get replayGain {
    if (rgTrackGain == null &&
        rgTrackPeak == null &&
        rgAlbumGain == null &&
        rgAlbumPeak == null) {
      return null;
    }
    return ReplayGain(
      trackGain: rgTrackGain,
      trackPeak: rgTrackPeak,
      albumGain: rgAlbumGain,
      albumPeak: rgAlbumPeak,
    );
  }
}

final _notAlphanumeric = RegExp('[^A-Z0-9]');

/// Strips the stray NULs tag parsers leave behind, then the whitespace.
String _clean(String value) => value.replaceAll('\u0000', '').trim();

String? _text(String? value) {
  if (value == null) return null;
  final cleaned = _clean(value);
  return cleaned.isEmpty ? null : cleaned;
}

/// Distinct, cleaned, in arrival order — a credits list with no blanks.
List<String> _names(Iterable<String?> values) {
  final seen = <String>{};
  final names = <String>[];
  for (final value in values) {
    if (value == null) continue;
    final cleaned = _clean(value);
    if (cleaned.isNotEmpty && seen.add(cleaned)) names.add(cleaned);
  }
  return names;
}

/// Parses `-6.20 dB` and its unicode-minus cousins into plain decibels.
double? _decibels(String? value) {
  if (value == null) return null;
  var text = _clean(value).replaceAll('−', '-');
  final lower = text.toLowerCase();
  if (lower.endsWith('db')) text = text.substring(0, text.length - 2).trim();
  return double.tryParse(text);
}

double? _double(String? value) =>
    value == null ? null : double.tryParse(_clean(value));

int? _int(String? value) => value == null ? null : _double(value)?.round();

int? _leadingYear(String value) {
  final match = RegExp(r'^\d{4}').firstMatch(value);
  return match == null ? null : int.parse(match[0]!);
}

/// Splits a parsed DateTime back into the model's terms: a full `date`
/// string when the tag spoke in days, a bare `year` when it spoke in
/// years — a January 1st is read as the latter, the tagger's shorthand.
({String? date, int? year}) _calendar(DateTime? value) {
  if (value == null || value.year == 0) return (date: null, year: null);
  if (value.month == 1 && value.day == 1) return (date: null, year: value.year);
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return (date: '${value.year}-$month-$day', year: null);
}

Duration? _positive(Duration? value) =>
    value == null || value <= Duration.zero ? null : value;

int? _kbps(int? bitsPerSecond) => bitsPerSecond == null || bitsPerSecond <= 0
    ? null
    : (bitsPerSecond / 1000).round();

int? _byteRateKbps(int? bytesPerSecond) =>
    bytesPerSecond == null || bytesPerSecond <= 0
    ? null
    : (bytesPerSecond * 8 / 1000).round();
