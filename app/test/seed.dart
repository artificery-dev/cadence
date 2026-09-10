import 'package:cadence_media/cadence_media.dart';

/// Test furniture, retired from first-run duty now that the scanner fills
/// real shelves: one library of every [LibraryType], holding files of
/// every [MediaKind], poured through the real schema — metadata JSON,
/// automatic `kind`/`format` tags, hashes, and a starter playlist so the
/// collections plumbing shows.
Future<void> seedIfEmpty(MediaClient client) async {
  if ((await client.listLibraries()).isNotEmpty) return;

  final music = await client.createLibrary('Music', LibraryType.music);
  final itemIds = <int>[];
  for (final (album, tracks) in _albums) {
    for (final track in tracks) {
      itemIds.add(
        await client.addItem(
          libraryId: music,
          path:
              '/music/${_slug(album.artist)}/${_slug(album.title)}/'
              '${track.number.toString().padLeft(2, '0')}_${_slug(track.title)}'
              '.${track.format}',
          sizeBytes: track.duration.inSeconds * (track.kbps ~/ 8) * 1000,
          modifiedAt: DateTime.utc(album.year, 6, 1),
          metadata: AudioMetadata(
            title: track.title,
            artist: album.artist,
            album: album.title,
            albumArtist: album.artist,
            year: album.year,
            trackNumber: track.number,
            duration: track.duration,
            bitrateKbps: track.kbps,
          ),
          hashes: {
            // Honest-looking stand-ins until a scanner hashes real bytes.
            HashKind.sha256: _slug('${album.title}/${track.title}'),
          },
          tags: [Tag.ofFormat(track.format)],
        ),
      );
    }
  }

  // Two starter collections, so the plumbing shows.
  final roadTrip = await client.createCollection('Road Trip');
  await client.setCollectionEntries(roadTrip, [
    itemIds[5], // Mile Marker Zero
    itemIds[9], // Overnight, Overland
    itemIds[16], // High Score Heart
    itemIds[1], // Dial Slow, Dream Fast
    itemIds[26], // Choir of Static
  ]);
  final lateNight = await client.createCollection('Late Night Static');
  await client.setCollectionEntries(lateNight, [
    itemIds[4], // Signal Fade
    itemIds[13], // Halcyon Days
    itemIds[20], // Tape Hiss Lullaby
    itemIds[25], // Vertical Hold
  ]);

  await _seedPodcasts(client);
  await _seedShows(client);
  final film = await _seedVideos(client);
  final audiobook = await _seedBooks(client);
  final issue = await _seedComics(client);
  await _seedImages(client);

  // One collection that crosses the shelves — a comic, a film, and an
  // audiobook in reading-then-watching order, so the mixed plumbing
  // shows.
  final canon = await client.createCollection('Broadcast Canon');
  await client.setCollectionEntries(canon, [issue, film, audiobook]);
}

/// Comics: the longbox, two issues deep. Returns the first issue, for
/// the mixed collection to open with.
Future<int> _seedComics(MediaClient client) async {
  final comics = await client.createLibrary('Comics', LibraryType.comics);
  const series = 'Tales from the Test Card';
  const issues = [
    (1.0, 'The Vertical Hold-Up', 24),
    (2.0, 'Attack of the Colour Bars', 22),
  ];
  final ids = <int>[];
  for (final (number, title, pages) in issues) {
    ids.add(
      await _add(
        client,
        comics,
        dir: 'comics/${_slug(series)}',
        name: '${number.toInt().toString().padLeft(3, '0')}_$title',
        format: 'cbz',
        year: 1999,
        sizeBytes: 40 << 20,
        metadata: DocumentMetadata(
          title: title,
          author: 'Ray Cathode',
          authors: const ['Ray Cathode'],
          publisher: 'Bitrate Press',
          pageCount: pages,
          series: series,
          issueNumber: number,
        ),
      ),
    );
  }
  return ids.first;
}

/// Podcasts: episodic audio on a schedule — the radio hour's descendants.
Future<void> _seedPodcasts(MediaClient client) async {
  final podcasts = await client.createLibrary('Podcasts', LibraryType.podcasts);
  const show = 'The Hold Music Hour';
  const episodes = [
    (1, 'On Hold with the Phone Company', Duration(minutes: 43, seconds: 6)),
    (2, 'Elevator Music, Ranked', Duration(minutes: 47, seconds: 51)),
    (3, 'The Jingle Industrial Complex', Duration(minutes: 39, seconds: 28)),
  ];
  for (final (number, title, duration) in episodes) {
    await _add(
      client,
      podcasts,
      dir: 'podcasts/${_slug(show)}',
      name: 'ep0${number}_$title',
      format: 'mp3',
      year: 2001,
      metadata: AudioMetadata(
        title: title,
        artist: show,
        album: show,
        year: 2001,
        trackNumber: number,
        duration: duration,
        bitrateKbps: 96,
      ),
    );
  }
}

/// One item, the ceremony folded away: path and hash derived from the
/// pieces, the format tag riding along.
Future<int> _add(
  MediaClient client,
  int libraryId, {
  required String dir,
  required String name,
  required String format,
  required int year,
  required MediaMetadata metadata,
  int sizeBytes = 1 << 22,
}) => client.addItem(
  libraryId: libraryId,
  path: '/$dir/${_slug(name)}.$format',
  sizeBytes: sizeBytes,
  modifiedAt: DateTime.utc(year, 6, 1),
  metadata: metadata,
  hashes: {HashKind.sha256: _slug('$dir/$name')},
  tags: [Tag.ofFormat(format)],
);

/// Shows: episodic both ways — a public-access TV run on video, and an
/// audio-only radio hour, the podcast before the word.
Future<void> _seedShows(MediaClient client) async {
  final shows = await client.createLibrary('Shows', LibraryType.shows);

  const series = 'Test Pattern After Dark';
  const episodes = [
    (1, 'The Sign-On Ceremony', Duration(minutes: 22, seconds: 40)),
    (2, 'Adjust Your Set', Duration(minutes: 24, seconds: 5)),
    (3, 'Vertical Hold', Duration(minutes: 23, seconds: 18)),
  ];
  for (final (number, title, duration) in episodes) {
    await _add(
      client,
      shows,
      dir: 'shows/${_slug(series)}/season_1',
      name: 'e0${number}_$title',
      format: 'mkv',
      year: 1999,
      sizeBytes: 350 << 20,
      metadata: VideoMetadata(
        title: title,
        year: 1999,
        duration: duration,
        series: series,
        season: 1,
        episode: number,
      ),
    );
  }

  const hour = 'The Midnight Dial Radio Hour';
  const broadcasts = [
    (1, 'Signals from the Overpass', Duration(minutes: 58, seconds: 30)),
    (2, 'Songs for Empty Diners', Duration(minutes: 61, seconds: 12)),
  ];
  for (final (number, title, duration) in broadcasts) {
    await _add(
      client,
      shows,
      dir: 'shows/${_slug(hour)}',
      name: 'ep0${number}_$title',
      format: 'mp3',
      year: 2000,
      metadata: AudioMetadata(
        title: title,
        artist: 'The Midnight Dial',
        album: hour,
        year: 2000,
        trackNumber: number,
        duration: duration,
        bitrateKbps: 128,
      ),
    );
  }
}

/// Videos: the long-form standalones. Returns the first film, for the
/// mixed collection's watch order.
Future<int> _seedVideos(MediaClient client) async {
  final videos = await client.createLibrary('Movies', LibraryType.movies);
  const films = [
    ('Neon Interstate: The Concert Film', 2000, Duration(minutes: 96)),
    ('Static Bloom: Live at the Loop', 1998, Duration(minutes: 74)),
  ];
  final ids = <int>[];
  for (final (title, year, duration) in films) {
    ids.add(
      await _add(
        client,
        videos,
        dir: 'videos',
        name: title,
        format: 'mp4',
        year: year,
        sizeBytes: 1400 << 20,
        metadata: VideoMetadata(
          title: title,
          year: year,
          duration: duration,
          // The concert film knows its set list; the deck's scene hops
          // read these.
          chapters: title.startsWith('Neon Interstate')
              ? const [
                  ChapterMark('Overture', Duration.zero),
                  ChapterMark('First Set', Duration(minutes: 12)),
                  ChapterMark('Encore', Duration(minutes: 80)),
                ]
              : const [],
        ),
      ),
    );
  }
  return ids.first;
}

/// Books: an audiobook, and the one document in the house — liner notes as
/// a stand-in until ebooks are real. Returns the audiobook, for the
/// mixed collection's one playable row.
Future<int> _seedBooks(MediaClient client) async {
  final books = await client.createLibrary('Books', LibraryType.books);
  final audiobook = await _add(
    client,
    books,
    dir: 'books',
    name: 'The Carrier Tone',
    format: 'm4b',
    year: 2001,
    sizeBytes: 220 << 20,
    metadata: const AudioMetadata(
      title: 'The Carrier Tone',
      artist: 'Ada Winters',
      year: 2001,
      duration: Duration(hours: 9, minutes: 41),
      bitrateKbps: 64,
      // An audiobook keeps its chapters; the deck's outer buttons hop
      // them instead of tracks.
      chapters: [
        ChapterMark('The Dial Tone', Duration.zero),
        ChapterMark('Static on the Line', Duration(hours: 3)),
        ChapterMark('The Last Exchange', Duration(hours: 7)),
      ],
    ),
  );
  await _add(
    client,
    books,
    dir: 'books',
    name: 'Static Bloom — Liner Notes',
    format: 'pdf',
    year: 1997,
    sizeBytes: 3 << 20,
    metadata: const DocumentMetadata(
      title: 'Static Bloom — Liner Notes',
      author: 'Velvet Modem',
      pageCount: 12,
    ),
  );
  return audiobook;
}

/// Images: the wallpaper crate.
Future<void> _seedImages(MediaClient client) async {
  final images = await client.createLibrary('Images', LibraryType.images);
  // Spread across months, so the timeline has something to group.
  const walls = [
    ('Neon Grid Sunset', 'png', 3840, 2160, (1999, 4, 2)),
    ('Cathode Bloom', 'png', 2560, 1440, (2000, 11, 23)),
    ('Overpass at 2AM', 'jpg', 3840, 1600, (2001, 10, 14)),
  ];
  for (final (title, format, width, height, (year, month, day)) in walls) {
    await _add(
      client,
      images,
      dir: 'images/wallpapers',
      name: title,
      format: format,
      year: year,
      sizeBytes: 8 << 20,
      metadata: ImageMetadata(
        title: title,
        takenAt: DateTime.utc(year, month, day),
        width: width,
        height: height,
      ),
    );
  }
}

String _slug(String text) =>
    text.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '_');

class _Album {
  const _Album(this.title, this.artist, this.year);

  final String title;
  final String artist;
  final int year;
}

class _Track {
  const _Track(this.number, this.title, this.duration, {this.kbps = 320})
    : format = kbps >= 320 ? 'flac' : 'mp3';

  final int number;
  final String title;
  final Duration duration;
  final int kbps;
  final String format;
}

const _albums = <(_Album, List<_Track>)>[
  (
    _Album('Static Bloom', 'Velvet Modem', 1997),
    [
      _Track(1, 'Carrier Tone', Duration(minutes: 4, seconds: 12)),
      _Track(2, 'Dial Slow, Dream Fast', Duration(minutes: 3, seconds: 48)),
      _Track(3, 'Handshake', Duration(minutes: 5, seconds: 2)),
      _Track(
        4,
        'Bloom (56k Mix)',
        Duration(minutes: 6, seconds: 11),
        kbps: 192,
      ),
      _Track(5, 'Signal Fade', Duration(minutes: 4, seconds: 39)),
    ],
  ),
  (
    _Album('Neon Interstate', 'The Midnight Dial', 1999),
    [
      _Track(1, 'Mile Marker Zero', Duration(minutes: 3, seconds: 21)),
      _Track(2, 'Sodium Lights', Duration(minutes: 4, seconds: 55)),
      _Track(3, 'Exit 9', Duration(minutes: 2, seconds: 58), kbps: 256),
      _Track(4, 'FM Ghost', Duration(minutes: 5, seconds: 24)),
      _Track(5, 'Overnight, Overland', Duration(minutes: 6, seconds: 2)),
    ],
  ),
  (
    _Album('Basement Frequencies', 'DJ Halcyon', 1998),
    [
      _Track(1, 'Break the Break', Duration(minutes: 4, seconds: 44)),
      _Track(
        2,
        'Low End Theory Club',
        Duration(minutes: 5, seconds: 37),
        kbps: 192,
      ),
      _Track(3, 'Vinyl Weather', Duration(minutes: 3, seconds: 12)),
      _Track(4, 'Halcyon Days', Duration(minutes: 7, seconds: 3)),
      _Track(
        5,
        'Last Call at the Loop',
        Duration(minutes: 4, seconds: 26),
        kbps: 128,
      ),
    ],
  ),
  (
    _Album('Glass Arcade', 'Polar Youth Club', 2000),
    [
      _Track(1, 'Insert Coin', Duration(minutes: 2, seconds: 49)),
      _Track(2, 'High Score Heart', Duration(minutes: 3, seconds: 33)),
      _Track(3, 'Polar Nights', Duration(minutes: 4, seconds: 18)),
      _Track(4, 'Continue?', Duration(minutes: 3, seconds: 57), kbps: 256),
      _Track(5, 'Attract Mode', Duration(minutes: 5, seconds: 45)),
    ],
  ),
  (
    _Album('Analog Heart', 'June & the Satellites', 1996),
    [
      _Track(1, 'Tape Hiss Lullaby', Duration(minutes: 4, seconds: 5)),
      _Track(2, 'Orbit & Fall', Duration(minutes: 3, seconds: 41)),
      _Track(3, 'Side B Forever', Duration(minutes: 5, seconds: 19)),
      _Track(4, 'Rewind Me', Duration(minutes: 2, seconds: 54), kbps: 192),
    ],
  ),
  (
    _Album('Last Transmission', 'Cathode Ray Choir', 2001),
    [
      _Track(1, 'Test Pattern', Duration(minutes: 3, seconds: 16)),
      _Track(2, 'Vertical Hold', Duration(minutes: 4, seconds: 47)),
      _Track(3, 'Choir of Static', Duration(minutes: 6, seconds: 28)),
      _Track(4, 'Sign-Off', Duration(minutes: 5, seconds: 8)),
    ],
  ),
];
