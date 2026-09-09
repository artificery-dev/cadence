import 'package:drift/drift.dart';
import '../database/database.dart';

/// Durable per-file work. A discovery commit advances the work to metadata in
/// the same transaction as the minimal item. A later scan reconciles it against
/// the filesystem before retrying; unavailable roots remain pending.
class ScanWork {
  ScanWork(this.db);
  final MediaDatabase db;

  Future<Map<String, QueryRow>> pending(int library) async => {
    for (final row
        in await db
            .customSelect(
              'SELECT * FROM scan_work WHERE library_id = ?',
              variables: [Variable(library)],
            )
            .get())
      row.read<String>('path'): row,
  };

  Future<void> enqueue(
    int library,
    String path,
    int size,
    DateTime modified,
    String kind,
  ) => db.customStatement(
    'INSERT INTO scan_work(library_id,path,size_bytes,modified_ms,kind,stage) '
    "VALUES (?,?,?,?,?,'discover') ON CONFLICT(library_id,path) DO UPDATE SET "
    "size_bytes=excluded.size_bytes,modified_ms=excluded.modified_ms,kind=excluded.kind,stage='discover',file_id=NULL",
    [library, path, size, modified.millisecondsSinceEpoch, kind],
  );

  Future<void> discovered(
    int library,
    String path,
    int file,
  ) => db.customStatement(
    "UPDATE scan_work SET stage='metadata',file_id=? WHERE library_id=? AND path=?",
    [file, library, path],
  );
  Future<void> complete(int library, String path) => db.customStatement(
    'DELETE FROM scan_work WHERE library_id=? AND path=?',
    [library, path],
  );
}
