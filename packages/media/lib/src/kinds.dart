/// What a library holds.
///
/// A library's type says what it is *for*, not strictly what formats live in
/// it — a [music] library holds music videos too (played headless, or with
/// the video standing in for the visualizer), and a [podcasts] episode may
/// bring video along.
enum LibraryType {
  /// Music and spoken content in tracks: albums, comedy records, music
  /// videos riding along. (Stored as `music`; databases born before v4
  /// wrote `audio` and are migrated.)
  music('Music'),

  /// Episodic audio on a schedule — video episodes ride along. Feeds are
  /// a Later; today the scanner fills them from folders like anything
  /// else.
  podcasts('Podcasts'),

  /// Episodic, usually seasonal content — with or without video.
  shows('Shows'),

  /// Long-form standalone video: movies, specials. (Stored as `movies`;
  /// databases born before v7 wrote `videos` and are migrated.)
  movies('Movies'),

  /// Audiobooks. Ebooks are a Later.
  books('Books'),

  /// Sequential reading in pictures: comic archives (cbz today, cbr
  /// recognised), page-position resume someday.
  comics('Comics'),

  /// Galleries — wallpapers now; temporal and geographic groupings later.
  images('Images');

  const LibraryType(this.label);

  /// How the type reads in chrome.
  final String label;
}

/// What a file is, at the container level.
enum MediaKind { audio, video, image, document }

/// The hash algorithms a file may be fingerprinted with. Hashes are stored
/// as rows keyed by this kind, so growing the set is data, not schema.
enum HashKind {
  /// Content identity: the same bytes, the same hash.
  sha256,

  /// Perceptual similarity, for images and eventually audio — near is near.
  perceptual,

  /// A 64-bit SimHash of a document's normalized text, hex — prose that
  /// merely re-flowed still hashes close.
  textSimhash,
}

/// What a file lying beside a media file is for. Sidecars ride along with
/// the file they serve; they are never library items themselves.
enum SidecarKind {
  /// Synced lyrics — an `.lrc` sharing the track's basename.
  lyrics,

  /// Subtitles — `.srt`, language infix and all.
  subtitles,

  /// Folder art — `cover.jpg` and its aliases, serving the whole directory.
  artwork,
}
