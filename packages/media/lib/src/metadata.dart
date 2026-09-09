import 'kinds.dart';

/// What we know about a file's content, stored as the JSON `metadata`
/// column on the files table and typed here on the way in and out.
///
/// Sealed on [MediaKind]: the kind column says which shape the JSON is,
/// and [MediaMetadata.fromJson] dispatches on it. Every shape pairs its
/// typed fields with an [extra] map holding the raw tags an extractor saw
/// but didn't type. New fields arrive optional, always — rows written
/// before a field existed decode unchanged, and encode unchanged too.
sealed class MediaMetadata {
  const MediaMetadata();

  MediaKind get kind;

  /// Raw tags that found no typed field, keys exactly as the source wrote
  /// them (`MUSICBRAINZ_ALBUMID`, `TXXX:…`). Nothing an extractor read is
  /// thrown away; omitted from JSON when empty.
  Map<String, Object?> get extra;

  Map<String, Object?> toJson();

  static MediaMetadata fromJson(MediaKind kind, Map<String, Object?> json) =>
      switch (kind) {
        MediaKind.audio => AudioMetadata.fromJson(json),
        MediaKind.video => VideoMetadata.fromJson(json),
        MediaKind.image => ImageMetadata.fromJson(json),
        MediaKind.document => DocumentMetadata.fromJson(json),
      };
}

/// A named position inside a long recording — audiobooks navigate by
/// these, and concert films keep their setlists in them.
class ChapterMark {
  const ChapterMark(this.title, this.start);

  factory ChapterMark.fromJson(Map<String, Object?> json) => ChapterMark(
    json['title'] as String? ?? '',
    Duration(milliseconds: json['startMs'] as int? ?? 0),
  );

  final String title;
  final Duration start;

  Map<String, Object?> toJson() => {
    'title': title,
    'startMs': start.inMilliseconds,
  };

  @override
  bool operator ==(Object other) =>
      other is ChapterMark && other.title == title && other.start == start;

  @override
  int get hashCode => Object.hash(title, start);

  @override
  String toString() => 'ChapterMark($title @ $start)';
}

/// The MusicBrainz identifiers a well-tagged file carries — enough to
/// walk from a recording to its release, its artists, and the work behind
/// them without a lookup guessing by name.
class MusicBrainzIds {
  const MusicBrainzIds({
    this.recordingId,
    this.trackId,
    this.releaseId,
    this.releaseGroupId,
    this.artistId,
    this.albumArtistId,
    this.workId,
  });

  factory MusicBrainzIds.fromJson(Map<String, Object?> json) => MusicBrainzIds(
    recordingId: json['recordingId'] as String?,
    trackId: json['trackId'] as String?,
    releaseId: json['releaseId'] as String?,
    releaseGroupId: json['releaseGroupId'] as String?,
    artistId: json['artistId'] as String?,
    albumArtistId: json['albumArtistId'] as String?,
    workId: json['workId'] as String?,
  );

  final String? recordingId;
  final String? trackId;
  final String? releaseId;
  final String? releaseGroupId;
  final String? artistId;
  final String? albumArtistId;
  final String? workId;

  Map<String, Object?> toJson() => {
    if (recordingId != null) 'recordingId': recordingId,
    if (trackId != null) 'trackId': trackId,
    if (releaseId != null) 'releaseId': releaseId,
    if (releaseGroupId != null) 'releaseGroupId': releaseGroupId,
    if (artistId != null) 'artistId': artistId,
    if (albumArtistId != null) 'albumArtistId': albumArtistId,
    if (workId != null) 'workId': workId,
  };

  @override
  bool operator ==(Object other) =>
      other is MusicBrainzIds &&
      other.recordingId == recordingId &&
      other.trackId == trackId &&
      other.releaseId == releaseId &&
      other.releaseGroupId == releaseGroupId &&
      other.artistId == artistId &&
      other.albumArtistId == albumArtistId &&
      other.workId == workId;

  @override
  int get hashCode => Object.hash(
    recordingId,
    trackId,
    releaseId,
    releaseGroupId,
    artistId,
    albumArtistId,
    workId,
  );
}

/// Loudness as the tagger measured it: gains in decibels, peaks as linear
/// amplitude — track values for shuffle, album values for sitting through
/// a record the way it was cut.
class ReplayGain {
  const ReplayGain({
    this.trackGain,
    this.trackPeak,
    this.albumGain,
    this.albumPeak,
  });

  factory ReplayGain.fromJson(Map<String, Object?> json) => ReplayGain(
    trackGain: _double(json['trackGain']),
    trackPeak: _double(json['trackPeak']),
    albumGain: _double(json['albumGain']),
    albumPeak: _double(json['albumPeak']),
  );

  final double? trackGain;
  final double? trackPeak;
  final double? albumGain;
  final double? albumPeak;

  Map<String, Object?> toJson() => {
    if (trackGain != null) 'trackGain': trackGain,
    if (trackPeak != null) 'trackPeak': trackPeak,
    if (albumGain != null) 'albumGain': albumGain,
    if (albumPeak != null) 'albumPeak': albumPeak,
  };

  @override
  bool operator ==(Object other) =>
      other is ReplayGain &&
      other.trackGain == trackGain &&
      other.trackPeak == trackPeak &&
      other.albumGain == albumGain &&
      other.albumPeak == albumPeak;

  @override
  int get hashCode => Object.hash(trackGain, trackPeak, albumGain, albumPeak);
}

/// A track's worth of knowledge: the display credits a player shows, the
/// sort keys and studio ephemera beneath them, and the technical truth of
/// the stream itself.
class AudioMetadata extends MediaMetadata {
  const AudioMetadata({
    required this.title,
    this.artist,
    this.album,
    this.albumArtist,
    int? year,
    this.trackNumber,
    this.duration,
    this.bitrateKbps,
    this.sortTitle,
    this.sortArtist,
    this.sortAlbum,
    this.sortAlbumArtist,
    this.artists = const [],
    this.composers = const [],
    this.lyricists = const [],
    this.genres = const [],
    this.conductor,
    this.remixer,
    this.grouping,
    this.comment,
    this.lyrics,
    this.language,
    this.initialKey,
    this.isrc,
    this.barcode,
    this.catalogNumber,
    this.label,
    this.encoder,
    this.media,
    this.mood,
    this.codec,
    this.date,
    this.trackTotal,
    this.discNumber,
    this.discTotal,
    this.bpm,
    this.sampleRateHz,
    this.channels,
    this.bitsPerSample,
    this.originalYear,
    this.rating,
    this.compilation,
    this.lossless,
    this.chapters = const [],
    this.musicBrainz,
    this.acoustId,
    this.replayGain,
    this.extra = const {},
  }) : _year = year; // ignore: prefer_initializing_formals

  factory AudioMetadata.fromJson(Map<String, Object?> json) => AudioMetadata(
    title: json['title'] as String? ?? '',
    artist: json['artist'] as String?,
    album: json['album'] as String?,
    albumArtist: json['albumArtist'] as String?,
    year: json['year'] as int?,
    trackNumber: json['trackNumber'] as int?,
    duration: _durationMs(json['durationMs']),
    bitrateKbps: json['bitrateKbps'] as int?,
    sortTitle: json['sortTitle'] as String?,
    sortArtist: json['sortArtist'] as String?,
    sortAlbum: json['sortAlbum'] as String?,
    sortAlbumArtist: json['sortAlbumArtist'] as String?,
    artists: _strings(json['artists']),
    composers: _strings(json['composers']),
    lyricists: _strings(json['lyricists']),
    genres: _strings(json['genres']),
    conductor: json['conductor'] as String?,
    remixer: json['remixer'] as String?,
    grouping: json['grouping'] as String?,
    comment: json['comment'] as String?,
    lyrics: json['lyrics'] as String?,
    language: json['language'] as String?,
    initialKey: json['initialKey'] as String?,
    isrc: json['isrc'] as String?,
    barcode: json['barcode'] as String?,
    catalogNumber: json['catalogNumber'] as String?,
    label: json['label'] as String?,
    encoder: json['encoder'] as String?,
    media: json['media'] as String?,
    mood: json['mood'] as String?,
    codec: json['codec'] as String?,
    date: json['date'] as String?,
    trackTotal: json['trackTotal'] as int?,
    discNumber: json['discNumber'] as int?,
    discTotal: json['discTotal'] as int?,
    bpm: json['bpm'] as int?,
    sampleRateHz: json['sampleRateHz'] as int?,
    channels: json['channels'] as int?,
    bitsPerSample: json['bitsPerSample'] as int?,
    originalYear: json['originalYear'] as int?,
    rating: json['rating'] as int?,
    compilation: json['compilation'] as bool?,
    lossless: json['lossless'] as bool?,
    chapters: _chapterMarks(json['chapters']),
    musicBrainz: switch (json['musicBrainz']) {
      final Map ids => MusicBrainzIds.fromJson(ids.cast<String, Object?>()),
      _ => null,
    },
    acoustId: json['acoustId'] as String?,
    replayGain: switch (json['replayGain']) {
      final Map gain => ReplayGain.fromJson(gain.cast<String, Object?>()),
      _ => null,
    },
    extra: _extraMap(json['extra']),
  );

  final String title;

  /// The display credit; [artists] holds every name on the sleeve.
  final String? artist;
  final String? album;
  final String? albumArtist;
  final int? _year;
  final int? trackNumber;
  final Duration? duration;
  final int? bitrateKbps;

  final String? sortTitle;
  final String? sortArtist;
  final String? sortAlbum;
  final String? sortAlbumArtist;

  final List<String> artists;
  final List<String> composers;
  final List<String> lyricists;
  final List<String> genres;

  final String? conductor;
  final String? remixer;
  final String? grouping;
  final String? comment;

  /// Unsynced lyrics as tagged; timed ones ride in as `.lrc` sidecars.
  final String? lyrics;
  final String? language;
  final String? initialKey;
  final String? isrc;
  final String? barcode;
  final String? catalogNumber;
  final String? label;
  final String? encoder;

  /// The medium the release shipped on: `CD`, `Vinyl`, `Digital Media`.
  final String? media;
  final String? mood;
  final String? codec;

  /// The full release date exactly as tagged (`2001-03-12`); [year]
  /// derives from it when the tag gave only the date.
  final String? date;

  final int? trackTotal;
  final int? discNumber;
  final int? discTotal;
  final int? bpm;
  final int? sampleRateHz;
  final int? channels;
  final int? bitsPerSample;
  final int? originalYear;

  /// Taste on a 0–100 scale, however the source expressed it.
  final int? rating;

  final bool? compilation;
  final bool? lossless;

  final List<ChapterMark> chapters;
  final MusicBrainzIds? musicBrainz;
  final String? acoustId;
  final ReplayGain? replayGain;

  @override
  final Map<String, Object?> extra;

  /// Release year: the tagged value, or the leading year of [date] when
  /// only the full date was written.
  int? get year => _year ?? _yearOf(date);

  @override
  MediaKind get kind => MediaKind.audio;

  @override
  Map<String, Object?> toJson() => {
    'title': title,
    if (artist != null) 'artist': artist,
    if (album != null) 'album': album,
    if (albumArtist != null) 'albumArtist': albumArtist,
    if (_year != null) 'year': _year,
    if (trackNumber != null) 'trackNumber': trackNumber,
    if (duration != null) 'durationMs': duration!.inMilliseconds,
    if (bitrateKbps != null) 'bitrateKbps': bitrateKbps,
    if (sortTitle != null) 'sortTitle': sortTitle,
    if (sortArtist != null) 'sortArtist': sortArtist,
    if (sortAlbum != null) 'sortAlbum': sortAlbum,
    if (sortAlbumArtist != null) 'sortAlbumArtist': sortAlbumArtist,
    if (artists.isNotEmpty) 'artists': artists,
    if (composers.isNotEmpty) 'composers': composers,
    if (lyricists.isNotEmpty) 'lyricists': lyricists,
    if (genres.isNotEmpty) 'genres': genres,
    if (conductor != null) 'conductor': conductor,
    if (remixer != null) 'remixer': remixer,
    if (grouping != null) 'grouping': grouping,
    if (comment != null) 'comment': comment,
    if (lyrics != null) 'lyrics': lyrics,
    if (language != null) 'language': language,
    if (initialKey != null) 'initialKey': initialKey,
    if (isrc != null) 'isrc': isrc,
    if (barcode != null) 'barcode': barcode,
    if (catalogNumber != null) 'catalogNumber': catalogNumber,
    if (label != null) 'label': label,
    if (encoder != null) 'encoder': encoder,
    if (media != null) 'media': media,
    if (mood != null) 'mood': mood,
    if (codec != null) 'codec': codec,
    if (date != null) 'date': date,
    if (trackTotal != null) 'trackTotal': trackTotal,
    if (discNumber != null) 'discNumber': discNumber,
    if (discTotal != null) 'discTotal': discTotal,
    if (bpm != null) 'bpm': bpm,
    if (sampleRateHz != null) 'sampleRateHz': sampleRateHz,
    if (channels != null) 'channels': channels,
    if (bitsPerSample != null) 'bitsPerSample': bitsPerSample,
    if (originalYear != null) 'originalYear': originalYear,
    if (rating != null) 'rating': rating,
    if (compilation != null) 'compilation': compilation,
    if (lossless != null) 'lossless': lossless,
    if (chapters.isNotEmpty)
      'chapters': [for (final mark in chapters) mark.toJson()],
    if (musicBrainz != null) 'musicBrainz': musicBrainz!.toJson(),
    if (acoustId != null) 'acoustId': acoustId,
    if (replayGain != null) 'replayGain': replayGain!.toJson(),
    if (extra.isNotEmpty) 'extra': extra,
  };
}

/// Video, long-form or episodic — a movie stands alone; an episode names
/// its series and where it sits in it. The container's own truth (frame
/// size, codecs, chapters) rides alongside the story-shaped fields.
class VideoMetadata extends MediaMetadata {
  const VideoMetadata({
    required this.title,
    this.year,
    this.duration,
    this.series,
    this.season,
    this.episode,
    this.width,
    this.height,
    this.frameRate,
    this.videoCodec,
    this.audioCodec,
    this.container,
    this.date,
    this.genres = const [],
    this.comment,
    this.subtitleLanguages = const [],
    this.chapters = const [],
    this.extra = const {},
  });

  factory VideoMetadata.fromJson(Map<String, Object?> json) => VideoMetadata(
    title: json['title'] as String? ?? '',
    year: json['year'] as int?,
    duration: _durationMs(json['durationMs']),
    series: json['series'] as String?,
    season: json['season'] as int?,
    episode: json['episode'] as int?,
    width: json['width'] as int?,
    height: json['height'] as int?,
    frameRate: _double(json['frameRate']),
    videoCodec: json['videoCodec'] as String?,
    audioCodec: json['audioCodec'] as String?,
    container: json['container'] as String?,
    date: json['date'] as String?,
    genres: _strings(json['genres']),
    comment: json['comment'] as String?,
    subtitleLanguages: _strings(json['subtitleLanguages']),
    chapters: _chapterMarks(json['chapters']),
    extra: _extraMap(json['extra']),
  );

  final String title;
  final int? year;
  final Duration? duration;

  /// The show this belongs to, when it belongs to one.
  final String? series;
  final int? season;
  final int? episode;

  final int? width;
  final int? height;
  final double? frameRate;
  final String? videoCodec;
  final String? audioCodec;
  final String? container;

  /// The release date as written, when the tags spoke in more than a year.
  final String? date;

  final List<String> genres;
  final String? comment;

  /// Languages of the subtitle tracks inside the container; sidecar `.srt`
  /// files live in their own table.
  final List<String> subtitleLanguages;
  final List<ChapterMark> chapters;

  @override
  final Map<String, Object?> extra;

  @override
  MediaKind get kind => MediaKind.video;

  @override
  Map<String, Object?> toJson() => {
    'title': title,
    if (year != null) 'year': year,
    if (duration != null) 'durationMs': duration!.inMilliseconds,
    if (series != null) 'series': series,
    if (season != null) 'season': season,
    if (episode != null) 'episode': episode,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (frameRate != null) 'frameRate': frameRate,
    if (videoCodec != null) 'videoCodec': videoCodec,
    if (audioCodec != null) 'audioCodec': audioCodec,
    if (container != null) 'container': container,
    if (date != null) 'date': date,
    if (genres.isNotEmpty) 'genres': genres,
    if (comment != null) 'comment': comment,
    if (subtitleLanguages.isNotEmpty) 'subtitleLanguages': subtitleLanguages,
    if (chapters.isNotEmpty)
      'chapters': [for (final mark in chapters) mark.toJson()],
    if (extra.isNotEmpty) 'extra': extra,
  };
}

/// A picture: its dimensions, the camera that took it, how the shot was
/// made, and where the photographer stood.
class ImageMetadata extends MediaMetadata {
  const ImageMetadata({
    this.title,
    this.takenAt,
    this.width,
    this.height,
    this.cameraMake,
    this.cameraModel,
    this.lensModel,
    this.orientation,
    this.iso,
    this.exposureSeconds,
    this.fNumber,
    this.focalLengthMm,
    this.gpsLatitude,
    this.gpsLongitude,
    this.gpsAltitude,
    this.description,
    this.extra = const {},
  });

  factory ImageMetadata.fromJson(Map<String, Object?> json) => ImageMetadata(
    title: json['title'] as String?,
    takenAt: switch (json['takenAt']) {
      final String iso => DateTime.tryParse(iso),
      _ => null,
    },
    width: json['width'] as int?,
    height: json['height'] as int?,
    cameraMake: json['cameraMake'] as String?,
    cameraModel: json['cameraModel'] as String?,
    lensModel: json['lensModel'] as String?,
    orientation: json['orientation'] as int?,
    iso: json['iso'] as int?,
    exposureSeconds: _double(json['exposureSeconds']),
    fNumber: _double(json['fNumber']),
    focalLengthMm: _double(json['focalLengthMm']),
    gpsLatitude: _double(json['gpsLatitude']),
    gpsLongitude: _double(json['gpsLongitude']),
    gpsAltitude: _double(json['gpsAltitude']),
    description: json['description'] as String?,
    extra: _extraMap(json['extra']),
  );

  final String? title;
  final DateTime? takenAt;
  final int? width;
  final int? height;

  final String? cameraMake;
  final String? cameraModel;
  final String? lensModel;

  /// EXIF orientation, 1–8 — which way is up, per the sensor.
  final int? orientation;
  final int? iso;
  final double? exposureSeconds;
  final double? fNumber;
  final double? focalLengthMm;

  final double? gpsLatitude;
  final double? gpsLongitude;
  final double? gpsAltitude;

  final String? description;

  @override
  final Map<String, Object?> extra;

  @override
  MediaKind get kind => MediaKind.image;

  @override
  Map<String, Object?> toJson() => {
    if (title != null) 'title': title,
    if (takenAt != null) 'takenAt': takenAt!.toIso8601String(),
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (cameraMake != null) 'cameraMake': cameraMake,
    if (cameraModel != null) 'cameraModel': cameraModel,
    if (lensModel != null) 'lensModel': lensModel,
    if (orientation != null) 'orientation': orientation,
    if (iso != null) 'iso': iso,
    if (exposureSeconds != null) 'exposureSeconds': exposureSeconds,
    if (fNumber != null) 'fNumber': fNumber,
    if (focalLengthMm != null) 'focalLengthMm': focalLengthMm,
    if (gpsLatitude != null) 'gpsLatitude': gpsLatitude,
    if (gpsLongitude != null) 'gpsLongitude': gpsLongitude,
    if (gpsAltitude != null) 'gpsAltitude': gpsAltitude,
    if (description != null) 'description': description,
    if (extra.isNotEmpty) 'extra': extra,
  };
}

/// Text-shaped media: books and papers, credited, shelved, and counted.
class DocumentMetadata extends MediaMetadata {
  const DocumentMetadata({
    required this.title,
    this.author,
    this.authors = const [],
    this.language,
    this.publisher,
    this.isbn,
    this.description,
    this.pageCount,
    this.series,
    this.issueNumber,
    this.extra = const {},
  });

  factory DocumentMetadata.fromJson(Map<String, Object?> json) =>
      DocumentMetadata(
        title: json['title'] as String? ?? '',
        author: json['author'] as String?,
        authors: _strings(json['authors']),
        language: json['language'] as String?,
        publisher: json['publisher'] as String?,
        isbn: json['isbn'] as String?,
        description: json['description'] as String?,
        pageCount: json['pageCount'] as int?,
        series: json['series'] as String?,
        issueNumber: _double(json['issueNumber']),
        extra: _extraMap(json['extra']),
      );

  final String title;

  /// The display credit; [authors] holds every name on the title page.
  final String? author;
  final List<String> authors;
  final String? language;
  final String? publisher;
  final String? isbn;
  final String? description;
  final int? pageCount;
  final String? series;

  /// Where this sits in [series] — a double, because comics number their
  /// annuals and one-shots 12.5 without blushing.
  final double? issueNumber;

  @override
  final Map<String, Object?> extra;

  @override
  MediaKind get kind => MediaKind.document;

  @override
  Map<String, Object?> toJson() => {
    'title': title,
    if (author != null) 'author': author,
    if (authors.isNotEmpty) 'authors': authors,
    if (language != null) 'language': language,
    if (publisher != null) 'publisher': publisher,
    if (isbn != null) 'isbn': isbn,
    if (description != null) 'description': description,
    if (pageCount != null) 'pageCount': pageCount,
    if (series != null) 'series': series,
    if (issueNumber != null) 'issueNumber': issueNumber,
    if (extra.isNotEmpty) 'extra': extra,
  };
}

Duration? _durationMs(Object? value) =>
    value is int ? Duration(milliseconds: value) : null;

double? _double(Object? value) => value is num ? value.toDouble() : null;

List<String> _strings(Object? value) =>
    value is List ? value.cast<String>() : const [];

List<ChapterMark> _chapterMarks(Object? value) => value is List
    ? [
        for (final entry in value)
          if (entry is Map) ChapterMark.fromJson(entry.cast<String, Object?>()),
      ]
    : const [];

Map<String, Object?> _extraMap(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const {};

int? _yearOf(String? date) {
  final match = date == null ? null : RegExp(r'^\d{4}').firstMatch(date);
  return match == null ? null : int.parse(match[0]!);
}
