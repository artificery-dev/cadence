import 'package:drift/drift.dart';

import '../kinds.dart';

part 'database.g.dart';

/// What an artwork row is for.
enum ArtworkRole {
  /// Pulled from the file itself.
  embedded,

  /// A downscaled render for lists and grids.
  thumbnail,

  /// Art found beside the file rather than inside it.
  folder,
}

/// A file on disk (or wherever a source keeps them): the physical half of
/// the world. What it *means* to a library lives in [LibraryItems].
@DataClassName('FileRow')
class Files extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get path => text().unique()();
  IntColumn get sizeBytes => integer()();
  DateTimeColumn get modifiedAt => dateTime()();
  TextColumn get kind => textEnum<MediaKind>()();

  /// The [MediaMetadata] JSON, shaped by [kind].
  TextColumn get metadata => text()();

  /// When a scan last confirmed the file on disk.
  DateTimeColumn get scannedAt => dateTime().nullable()();

  /// When a scan first failed to find it — null while it is present.
  DateTimeColumn get missingSince => dateTime().nullable()();
}

/// A file's fingerprints — one row per algorithm, so a new [HashKind] is
/// data rather than schema.
@DataClassName('FileHashRow')
class FileHashes extends Table {
  IntColumn get fileId =>
      integer().references(Files, #id, onDelete: KeyAction.cascade)();
  TextColumn get kind => textEnum<HashKind>()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {fileId, kind};
}

/// A collection of items with a stated purpose — the [LibraryType].
@DataClassName('LibraryRow')
class Libraries extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get type => textEnum<LibraryType>()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// A directory a library claims — the ground the scanner walks. One
/// library may claim several; the same path may serve two libraries.
@DataClassName('LibraryRootRow')
class LibraryRoots extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get libraryId =>
      integer().references(Libraries, #id, onDelete: KeyAction.cascade)();
  TextColumn get path => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column>> get uniqueKeys => [
    {libraryId, path},
  ];
}

/// A companion file riding beside a media file: lyrics, subtitles, the
/// folder's cover art. Never an item in its own right.
@DataClassName('SidecarRow')
class Sidecars extends Table {
  IntColumn get fileId =>
      integer().references(Files, #id, onDelete: KeyAction.cascade)();
  TextColumn get path => text()();
  TextColumn get kind => textEnum<SidecarKind>()();
  DateTimeColumn get modifiedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {fileId, kind, path};
}

/// A file's membership in a library, and everything the library layers on
/// top of it: when it arrived, the notes, the tags (in [ItemTags]).
@DataClassName('LibraryItemRow')
class LibraryItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get libraryId =>
      integer().references(Libraries, #id, onDelete: KeyAction.cascade)();
  IntColumn get fileId =>
      integer().references(Files, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get addedAt => dateTime().withDefault(currentDateAndTime)();
  TextColumn get notes => text().nullable()();
}

/// Tags as rows, not JSON — the query planner is the whole point.
@DataClassName('ItemTagRow')
class ItemTags extends Table {
  IntColumn get itemId =>
      integer().references(LibraryItems, #id, onDelete: KeyAction.cascade)();
  TextColumn get namespace => text()();
  TextColumn get name => text()();

  @override
  Set<Column> get primaryKey => {itemId, namespace, name};
}

/// The app's key–value settings: dotted namespaced keys, JSON values.
@DataClassName('SettingRow')
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// An ordered, person-made list of items — a playlist, a reading order,
/// a watch order. App-level, not a library's: the entries may point into
/// any shelf, so one collection can compose across media kinds.
@DataClassName('CollectionRow')
class Collections extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

@DataClassName('CollectionEntryRow')
class CollectionEntries extends Table {
  IntColumn get collectionId =>
      integer().references(Collections, #id, onDelete: KeyAction.cascade)();
  IntColumn get position => integer()();
  IntColumn get itemId =>
      integer().references(LibraryItems, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {collectionId, position};
}

/// One sitting with an item — history, counts, and someday scrobbles.
@DataClassName('PlayRow')
class Plays extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get itemId =>
      integer().references(LibraryItems, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get startedAt => dateTime()();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();
}

/// Where an item was left off — what lets a Book or a Show resume.
@DataClassName('ProgressRow')
class ProgressEntries extends Table {
  IntColumn get itemId =>
      integer().references(LibraryItems, #id, onDelete: KeyAction.cascade)();
  IntColumn get positionMs => integer()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {itemId};
}

/// Art for a file: the embedded original, the thumbnail render.
@DataClassName('ArtworkRow')
class Artworks extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get fileId =>
      integer().references(Files, #id, onDelete: KeyAction.cascade)();
  TextColumn get role => textEnum<ArtworkRole>()();
  TextColumn get mime => text()();
  BlobColumn get data => blob()();
}

/// The database, connection injected: tests bring memory, the app brings a
/// file, a future scanner brings whatever it likes.
@DriftDatabase(
  tables: [
    Files,
    FileHashes,
    Libraries,
    LibraryRoots,
    Sidecars,
    LibraryItems,
    ItemTags,
    Settings,
    Collections,
    CollectionEntries,
    Plays,
    ProgressEntries,
    Artworks,
  ],
)
class MediaDatabase extends _$MediaDatabase {
  MediaDatabase(super.executor);

  @override
  int get schemaVersion => 8;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        // v2 added collections.mode — spelled raw now, because v5 took
        // the column back out of the Dart table and the walk must still
        // pass through here.
        await customStatement(
          "ALTER TABLE collections ADD COLUMN mode TEXT NOT NULL "
          "DEFAULT 'ordered'",
        );
      }
      if (from < 3) {
        // v3: the scanner arrives — roots to walk, sidecars to remember,
        // and files that know when they were seen (and since when they
        // weren't).
        await m.createTable(libraryRoots);
        await m.createTable(sidecars);
        await m.addColumn(files, files.scannedAt);
        await m.addColumn(files, files.missingSince);
        // Older generators dropped every REFERENCES clause, so databases
        // born before v3 have cascades in name only. Rebuild the
        // referencing tables to give them the constraints they were
        // always promised.
        await m.alterTable(TableMigration(fileHashes));
        await m.alterTable(TableMigration(libraryItems));
        await m.alterTable(TableMigration(itemTags));
        await m.alterTable(TableMigration(collections));
        await m.alterTable(TableMigration(collectionEntries));
        await m.alterTable(TableMigration(plays));
        await m.alterTable(TableMigration(progressEntries));
        await m.alterTable(TableMigration(artworks));
      }
      if (from < 4) {
        // v4: the audio library type grows up into music (podcasts took
        // the generic word's other half).
        await customStatement(
          "UPDATE libraries SET type = 'music' WHERE type = 'audio'",
        );
      }
      if (from < 5) {
        // v5: collections shed their mode — every collection plays in
        // its laid order, reorders freely, and shuffles when asked. The
        // rebuild drops the column by simply not copying it.
        await m.alterTable(TableMigration(collections));
      }
      if (from < 6) {
        // v6: collections leave their libraries — one list may hold any
        // shelf's items now (reading orders, watch orders), so the
        // library_id column goes the way mode went: not copied.
        await m.alterTable(TableMigration(collections));
      }
      if (from < 7) {
        // v7: the videos library type says what it holds — movies.
        await customStatement(
          "UPDATE libraries SET type = 'movies' WHERE type = 'videos'",
        );
      }
      if (from < 8) {
        // Samples are not identities. Preserve files/items; the scanner fills in
        // missing full hashes when their roots are next available.
        await customStatement(
          "DELETE FROM file_hashes WHERE kind = 'sampledSha256'",
        );
      }
    },
    onCreate: (m) async {
      await m.createAll();
      // The search index rides outside drift's table classes: FTS5 is a
      // virtual table, fed by the repositories on write.
      await customStatement(
        'CREATE VIRTUAL TABLE search_index USING fts5('
        'item_id UNINDEXED, title, artist, album, tags)',
      );
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
