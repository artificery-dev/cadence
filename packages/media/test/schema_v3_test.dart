import 'test_filesystem.dart';
import 'package:cadence_media/cadence_media.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart'
    hide test, setUp, tearDown, setUpAll, tearDownAll, addTearDown;

/// The schema as v2 shipped it — hand-written, because the whole point is
/// opening a database drift did not just create. Column names follow
/// drift's snake_case mapping; datetimes are unix seconds.
const _v2Schema = '''
CREATE TABLE files (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  path TEXT NOT NULL UNIQUE,
  size_bytes INTEGER NOT NULL,
  modified_at INTEGER NOT NULL,
  kind TEXT NOT NULL,
  metadata TEXT NOT NULL
);
CREATE TABLE file_hashes (
  file_id INTEGER NOT NULL REFERENCES files (id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  value TEXT NOT NULL,
  PRIMARY KEY (file_id, kind)
);
CREATE TABLE libraries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  type TEXT NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s', CURRENT_TIMESTAMP))
);
CREATE TABLE library_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  library_id INTEGER NOT NULL REFERENCES libraries (id) ON DELETE CASCADE,
  file_id INTEGER NOT NULL REFERENCES files (id) ON DELETE CASCADE,
  added_at INTEGER NOT NULL DEFAULT (strftime('%s', CURRENT_TIMESTAMP)),
  notes TEXT
);
CREATE TABLE item_tags (
  item_id INTEGER NOT NULL REFERENCES library_items (id) ON DELETE CASCADE,
  namespace TEXT NOT NULL,
  name TEXT NOT NULL,
  PRIMARY KEY (item_id, namespace, name)
);
CREATE TABLE settings (
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  PRIMARY KEY (key)
);
CREATE TABLE collections (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  library_id INTEGER NOT NULL REFERENCES libraries (id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  mode TEXT NOT NULL DEFAULT 'ordered',
  created_at INTEGER NOT NULL DEFAULT (strftime('%s', CURRENT_TIMESTAMP))
);
CREATE TABLE collection_entries (
  collection_id INTEGER NOT NULL REFERENCES collections (id) ON DELETE CASCADE,
  position INTEGER NOT NULL,
  item_id INTEGER NOT NULL REFERENCES library_items (id) ON DELETE CASCADE,
  PRIMARY KEY (collection_id, position)
);
CREATE TABLE plays (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  item_id INTEGER NOT NULL REFERENCES library_items (id) ON DELETE CASCADE,
  started_at INTEGER NOT NULL,
  completed INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE progress_entries (
  item_id INTEGER NOT NULL REFERENCES library_items (id) ON DELETE CASCADE,
  position_ms INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (item_id)
);
CREATE TABLE artworks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  file_id INTEGER NOT NULL REFERENCES files (id) ON DELETE CASCADE,
  role TEXT NOT NULL,
  mime TEXT NOT NULL,
  data BLOB NOT NULL
);
CREATE VIRTUAL TABLE search_index USING fts5(
  item_id UNINDEXED, title, artist, album, tags
);
''';

/// Opens an in-memory database already living at v2, with one library, one
/// file, one item, and one collection inside — then hands it to drift.
MediaDatabase openAtV2() {
  final raw = sqlite3.openInMemory();
  raw.execute(_v2Schema);
  raw.execute("INSERT INTO libraries (name, type) VALUES ('Music', 'audio')");
  raw.execute("INSERT INTO libraries (name, type) VALUES ('Movies', 'videos')");
  raw.execute(
    'INSERT INTO files (path, size_bytes, modified_at, kind, metadata) '
    "VALUES ('/music/old.mp3', 42, 0, 'audio', '{\"title\":\"Old\"}')",
  );
  raw.execute(
    'INSERT INTO library_items (library_id, file_id, added_at) '
    'VALUES (1, 1, 0)',
  );
  raw.execute("INSERT INTO collections (library_id, name) VALUES (1, 'Mix')");
  raw.execute('PRAGMA user_version = 2');
  return MediaDatabase(NativeDatabase.opened(raw));
}

void main() => memoryTests(registerTests);
void registerTests() {
  group('migrating v2 up', () {
    late MediaDatabase db;

    setUp(() => db = openAtV2());
    tearDown(() => db.close());

    test('lands on the current version', () async {
      final row = await db.customSelect('PRAGMA user_version').getSingle();
      expect(row.read<int>('user_version'), 7);
    });

    test('the audio library type grows up into music', () async {
      final library = await (db.select(
        db.libraries,
      )..where((l) => l.name.equals('Music'))).getSingle();
      expect(library.type, LibraryType.music);
    });

    test('the videos library type says movies', () async {
      final library = await (db.select(
        db.libraries,
      )..where((l) => l.name.equals('Movies'))).getSingle();
      expect(library.type, LibraryType.movies);
    });

    test('old file rows read back, new columns null', () async {
      final file = await db.select(db.files).getSingle();
      expect(file.path, '/music/old.mp3');
      expect(file.kind, MediaKind.audio);
      expect(file.scannedAt, isNull);
      expect(file.missingSince, isNull);
    });

    test('mode and library_id came and went; the collection stands', () async {
      // v2 added collections.mode, v5 took it back, and v6 cut the tie
      // to a library — an old database walks through all three and its
      // collection survives, modeless and free to hold any shelf's items.
      final collection = await db.select(db.collections).getSingle();
      expect(collection.name, 'Mix');
      final columns = await db
          .customSelect("SELECT name FROM pragma_table_info('collections')")
          .get();
      final names = [for (final row in columns) row.read<String>('name')];
      expect(names, isNot(contains('mode')));
      expect(names, isNot(contains('library_id')));
    });

    test('library roots exist, unique per library', () async {
      await db
          .into(db.libraryRoots)
          .insert(LibraryRootsCompanion.insert(libraryId: 1, path: '/music'));
      final root = await db.select(db.libraryRoots).getSingle();
      expect(root.libraryId, 1);
      expect(root.path, '/music');
      await expectLater(
        db
            .into(db.libraryRoots)
            .insert(LibraryRootsCompanion.insert(libraryId: 1, path: '/music')),
        throwsA(isA<Exception>()),
      );
    });

    test('sidecars exist, keyed by file, kind, and path', () async {
      final companion = SidecarsCompanion.insert(
        fileId: 1,
        path: '/music/old.lrc',
        kind: SidecarKind.lyrics,
        modifiedAt: DateTime.utc(2001),
      );
      await db.into(db.sidecars).insert(companion);
      // The same key again is an update, not a second row.
      await db
          .into(db.sidecars)
          .insertOnConflictUpdate(
            SidecarsCompanion.insert(
              fileId: 1,
              path: '/music/old.lrc',
              kind: SidecarKind.lyrics,
              modifiedAt: DateTime.utc(2002),
            ),
          );
      final rows = await db.select(db.sidecars).get();
      expect(rows, hasLength(1));
      expect(rows.single.modifiedAt.toUtc(), DateTime.utc(2002));
    });

    test('deleting a library cascades to its roots', () async {
      await db
          .into(db.libraryRoots)
          .insert(LibraryRootsCompanion.insert(libraryId: 1, path: '/music'));
      await (db.delete(db.libraries)..where((l) => l.id.equals(1))).go();
      expect(await db.select(db.libraryRoots).get(), isEmpty);
    });
  });

  group('a fresh v3 database', () {
    late MediaDatabase db;

    setUp(() => db = MediaDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('creates the new tables and columns from nothing', () async {
      final libraryId = await LibraryRepository(
        db,
      ).createLibrary('Music', LibraryType.music);
      await db
          .into(db.libraryRoots)
          .insert(
            LibraryRootsCompanion.insert(libraryId: libraryId, path: '/music'),
          );
      expect(await db.select(db.libraryRoots).get(), hasLength(1));
      final row = await db.customSelect('PRAGMA user_version').getSingle();
      expect(row.read<int>('user_version'), 7);
    });
  });
}
