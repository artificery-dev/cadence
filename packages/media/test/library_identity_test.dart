import 'test_filesystem.dart';
import 'package:cadence_media/cadence_media.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart'
    hide test, setUp, tearDown, setUpAll, tearDownAll, addTearDown;

void main() => memoryTests(registerTests);

void registerTests() {
  test(
    'UUIDs are distinct, survive rename/reopen, and backfill v9 libraries',
    () async {
      final raw = sqlite3.openInMemory();
      var db = MediaDatabase(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      try {
        var repo = LibraryRepository(db);
        final first = await repo.createLibrary('Music', LibraryType.music);
        final second = await repo.createLibrary('Music', LibraryType.music);
        final uuid = await repo.uuidOf(first);
        expect(await repo.uuidOf(second), isNot(uuid));
        await repo.renameLibrary(first, 'Songs');
        expect(await repo.uuidOf(first), uuid);
        await db.close();
        db = MediaDatabase(
          NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
        );
        repo = LibraryRepository(db);
        expect(await repo.uuidOf(first), uuid);
        await db.customStatement('DROP TRIGGER library_identity_created');
        await db.customStatement('DROP TABLE library_identities');
        await db.customStatement('PRAGMA user_version = 9');
        await db.close();
        db = MediaDatabase(
          NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
        );
        repo = LibraryRepository(db);
        final migrated = await repo.uuidOf(first);
        expect(
          migrated,
          matches(
            RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
            ),
          ),
        );
        expect(await repo.uuidOf(second), isNot(migrated));
        expect((await repo.listLibraries()).map((l) => l.id), [first, second]);
        await repo.deleteLibrary(first);
        expect(
          await db.customSelect('SELECT * FROM library_identities').get(),
          hasLength(1),
        );
      } finally {
        await db.close();
        raw.close();
      }
    },
  );
}
