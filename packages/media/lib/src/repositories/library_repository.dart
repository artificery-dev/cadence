import 'dart:convert';

import 'package:drift/drift.dart';

import '../database/database.dart';
import '../kinds.dart';
import '../metadata.dart';
import '../tags.dart';
import 'search_repository.dart';

/// An audio item the player can hold: the library row, its file, the typed
/// metadata, and the tags it wears.
class AudioItem {
  const AudioItem({
    required this.id,
    required this.fileId,
    required this.path,
    required this.metadata,
    required this.tags,
  });

  final int id;
  final int fileId;
  final String path;
  final AudioMetadata metadata;
  final List<Tag> tags;
}

/// Any item, whatever its kind: the library row, its file, the typed
/// metadata, and the tags it wears. [AudioItem] is the audio-only cousin
/// the player holds.
class MediaItem {
  const MediaItem({
    required this.id,
    required this.fileId,
    required this.path,
    required this.metadata,
    required this.tags,
  });

  final int id;
  final int fileId;
  final String path;
  final MediaMetadata metadata;
  final List<Tag> tags;
}

/// One track, as a list of thousands wants it: the handful of fields a
/// row shows and a shelf sorts by, and nothing else. An [AudioItem]
/// carries the whole [AudioMetadata], raw tags and all — tens of
/// kilobytes for a well-tagged FLAC — which is the right thing to hand a
/// detail screen and the wrong thing to hand a wheel walking six
/// thousand rows on a small machine. The service serves these compact,
/// and the player groups them into albums and artists itself.
class TrackSummary {
  const TrackSummary({
    required this.id,
    required this.fileId,
    required this.path,
    required this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.trackNumber,
    this.discNumber,
    this.duration,
    this.year,
    this.genre,
  });

  factory TrackSummary.fromJson(Map<String, Object?> json) => TrackSummary(
    id: json['id'] as int,
    fileId: json['fileId'] as int,
    path: json['path'] as String,
    title: json['title'] as String,
    artist: json['artist'] as String?,
    album: json['album'] as String?,
    albumArtist: json['albumArtist'] as String?,
    trackNumber: json['track'] as int?,
    discNumber: json['disc'] as int?,
    duration: switch (json['durationMs']) {
      final int ms => Duration(milliseconds: ms),
      _ => null,
    },
    year: json['year'] as int?,
    genre: json['genre'] as String?,
  );

  /// The library item.
  final int id;

  /// The file it plays from.
  final int fileId;
  final String path;
  final String title;
  final String? artist;
  final String? album;

  /// The album's own artist, when tagged; a shelf groups by this before
  /// [artist], so a compilation is one album and not twelve.
  final String? albumArtist;
  final int? trackNumber;
  final int? discNumber;
  final Duration? duration;
  final int? year;

  /// The first genre tagged.
  final String? genre;

  /// The artist an album shelf files under: the album artist, else the
  /// track's.
  String? get shelfArtist => albumArtist ?? artist;

  Map<String, Object?> toJson() => {
    'id': id,
    'fileId': fileId,
    'path': path,
    'title': title,
    if (artist != null) 'artist': artist,
    if (album != null) 'album': album,
    if (albumArtist != null) 'albumArtist': albumArtist,
    if (trackNumber != null) 'track': trackNumber,
    if (discNumber != null) 'disc': discNumber,
    if (duration != null) 'durationMs': duration!.inMilliseconds,
    if (year != null) 'year': year,
    if (genre != null) 'genre': genre,
  };

  /// The summary of a full item.
  static TrackSummary of({
    required int id,
    required int fileId,
    required String path,
    required AudioMetadata metadata,
  }) => TrackSummary(
    id: id,
    fileId: fileId,
    path: path,
    title: metadata.title,
    artist: metadata.artist,
    album: metadata.album,
    albumArtist: metadata.albumArtist,
    trackNumber: metadata.trackNumber,
    discNumber: metadata.discNumber,
    duration: metadata.duration,
    year: metadata.year,
    genre: metadata.genres.firstOrNull,
  );
}

/// Libraries and their items: the librarian. Writes keep the search index
/// fed; reads come typed.
class LibraryRepository {
  LibraryRepository(this.db) : _search = SearchRepository(db);

  final MediaDatabase db;
  final SearchRepository _search;

  Future<int> createLibrary(String name, LibraryType type) => db
      .into(db.libraries)
      .insert(LibrariesCompanion.insert(name: name, type: type));

  Future<List<LibraryRow>> listLibraries() => db.select(db.libraries).get();

  Future<void> renameLibrary(int libraryId, String name) =>
      (db.update(db.libraries)..where((l) => l.id.equals(libraryId))).write(
        LibrariesCompanion(name: Value(name)),
      );

  /// Removes the library, its items (by cascade), and their search rows —
  /// the index has no foreign keys to lean on.
  Future<void> deleteLibrary(int libraryId) => db.transaction(() async {
    final items = await (db.select(
      db.libraryItems,
    )..where((i) => i.libraryId.equals(libraryId))).get();
    for (final item in items) {
      await _search.removeItem(item.id);
    }
    await (db.delete(db.libraries)..where((l) => l.id.equals(libraryId))).go();
  });

  Stream<List<LibraryRow>> watchLibraries() => db.select(db.libraries).watch();

  /// Files in, meaning on: inserts the file (with hashes), the item, its
  /// tags — the automatic `kind/…` tag always included — and its search
  /// row, in one transaction. Returns the item id.
  Future<int> addItem({
    required int libraryId,
    required String path,
    required int sizeBytes,
    required DateTime modifiedAt,
    required MediaMetadata metadata,
    Map<HashKind, String> hashes = const {},
    List<Tag> tags = const [],
    String? notes,
  }) => db.transaction(() async {
    final fileId = await db
        .into(db.files)
        .insert(
          FilesCompanion.insert(
            path: path,
            sizeBytes: sizeBytes,
            modifiedAt: modifiedAt,
            kind: metadata.kind,
            metadata: jsonEncode(metadata.toJson()),
          ),
        );
    for (final MapEntry(key: kind, value: value) in hashes.entries) {
      await db
          .into(db.fileHashes)
          .insert(
            FileHashesCompanion.insert(
              fileId: fileId,
              kind: kind,
              value: value,
            ),
          );
    }
    final itemId = await db
        .into(db.libraryItems)
        .insert(
          LibraryItemsCompanion.insert(
            libraryId: libraryId,
            fileId: fileId,
            notes: Value.absentIfNull(notes),
          ),
        );
    final allTags = {Tag.ofKind(metadata.kind), ...tags};
    for (final tag in allTags) {
      await db
          .into(db.itemTags)
          .insert(
            ItemTagsCompanion.insert(
              itemId: itemId,
              namespace: tag.namespace,
              name: tag.name,
            ),
          );
    }
    await _indexFromMetadata(itemId, metadata, allTags);
    return itemId;
  });

  Future<void> addTag(int itemId, Tag tag) async {
    await db
        .into(db.itemTags)
        .insert(
          ItemTagsCompanion.insert(
            itemId: itemId,
            namespace: tag.namespace,
            name: tag.name,
          ),
          mode: InsertMode.insertOrIgnore,
        );
    await _reindex(itemId);
  }

  Future<void> removeTag(int itemId, Tag tag) async {
    await (db.delete(db.itemTags)..where(
          (t) =>
              t.itemId.equals(itemId) &
              t.namespace.equals(tag.namespace) &
              t.name.equals(tag.name),
        ))
        .go();
    await _reindex(itemId);
  }

  /// The best picture on file for [fileId], tried in [roles] order —
  /// thumbnails first by default, since lists and grids are the usual
  /// askers. Null when the file sits bare.
  Future<ArtworkRow?> artworkOf(
    int fileId, {
    List<ArtworkRole> roles = const [
      ArtworkRole.thumbnail,
      ArtworkRole.embedded,
      ArtworkRole.folder,
    ],
  }) async {
    for (final role in roles) {
      final row =
          await (db.select(db.artworks)
                ..where(
                  (a) => a.fileId.equals(fileId) & a.role.equalsValue(role),
                )
                ..limit(1))
              .getSingleOrNull();
      if (row != null) return row;
    }
    return null;
  }

  Future<List<Tag>> tagsOf(int itemId) async {
    final rows = await (db.select(
      db.itemTags,
    )..where((t) => t.itemId.equals(itemId))).get();
    return [for (final row in rows) Tag(row.namespace, row.name)];
  }

  /// Every item of a library, whatever its kind, in added order.
  Future<List<MediaItem>> mediaItems(int libraryId) async {
    final rows =
        await (db.select(db.libraryItems).join([
                innerJoin(
                  db.files,
                  db.files.id.equalsExp(db.libraryItems.fileId),
                ),
              ])
              ..where(db.libraryItems.libraryId.equals(libraryId))
              ..orderBy([OrderingTerm.asc(db.libraryItems.id)]))
            .get();
    final items = <MediaItem>[];
    for (final row in rows) {
      final item = row.readTable(db.libraryItems);
      final file = row.readTable(db.files);
      items.add(
        MediaItem(
          id: item.id,
          fileId: file.id,
          path: file.path,
          metadata: MediaMetadata.fromJson(
            file.kind,
            jsonDecode(file.metadata) as Map<String, Object?>,
          ),
          tags: await tagsOf(item.id),
        ),
      );
    }
    return items;
  }

  /// The audio items of a library, in added order.
  Future<List<AudioItem>> audioItems(int libraryId) async {
    final rows = await _audioQuery(libraryId).get();
    return _toAudioItems(rows);
  }

  /// The audio items of a library, compact — a row per track, in added
  /// order, tags and raw metadata left behind. Files marked missing are
  /// left out: a shelf lists what can play.
  Future<List<TrackSummary>> trackSummaries(int libraryId) async {
    final rows = await (_audioQuery(
      libraryId,
    )..where(db.files.missingSince.isNull())).get();
    return [
      for (final row in rows)
        () {
          final item = row.readTable(db.libraryItems);
          final file = row.readTable(db.files);
          return TrackSummary.of(
            id: item.id,
            fileId: file.id,
            path: file.path,
            metadata: AudioMetadata.fromJson(
              jsonDecode(file.metadata) as Map<String, Object?>,
            ),
          );
        }(),
    ];
  }

  /// The same list, live: re-emits when items, files, or tags move.
  Stream<List<AudioItem>> watchAudioItems(int libraryId) {
    // Tag edits must wake the stream too, so the query touches itemTags
    // even though rows are read per item afterwards.
    return _audioQuery(libraryId).watch().asyncMap(_toAudioItems);
  }

  JoinedSelectStatement _audioQuery(int libraryId) =>
      (db.select(db.libraryItems).join([
          innerJoin(db.files, db.files.id.equalsExp(db.libraryItems.fileId)),
        ])
        ..where(
          db.libraryItems.libraryId.equals(libraryId) &
              db.files.kind.equalsValue(MediaKind.audio),
        )
        ..orderBy([OrderingTerm.asc(db.libraryItems.id)]));

  Future<List<AudioItem>> _toAudioItems(List<TypedResult> rows) async {
    final items = <AudioItem>[];
    for (final row in rows) {
      final item = row.readTable(db.libraryItems);
      final file = row.readTable(db.files);
      items.add(
        AudioItem(
          id: item.id,
          fileId: file.id,
          path: file.path,
          metadata: AudioMetadata.fromJson(
            jsonDecode(file.metadata) as Map<String, Object?>,
          ),
          tags: await tagsOf(item.id),
        ),
      );
    }
    return items;
  }

  Future<void> _reindex(int itemId) async {
    final row = await (db.select(db.libraryItems).join([
      innerJoin(db.files, db.files.id.equalsExp(db.libraryItems.fileId)),
    ])..where(db.libraryItems.id.equals(itemId))).getSingleOrNull();
    if (row == null) return;
    final file = row.readTable(db.files);
    await _indexFromMetadata(
      itemId,
      MediaMetadata.fromJson(
        file.kind,
        jsonDecode(file.metadata) as Map<String, Object?>,
      ),
      await tagsOf(itemId),
    );
  }

  Future<void> _indexFromMetadata(
    int itemId,
    MediaMetadata metadata,
    Iterable<Tag> tags,
  ) {
    final (title, artist, album) = switch (metadata) {
      AudioMetadata m => (m.title, m.artist, m.album),
      VideoMetadata m => (m.title, null, null),
      ImageMetadata m => (m.title ?? '', null, null),
      DocumentMetadata m => (m.title, m.author, null),
    };
    return _search.indexItem(
      itemId,
      title: title,
      artist: artist,
      album: album,
      tags: [for (final tag in tags) tag.canonical],
    );
  }
}
