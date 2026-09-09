import 'package:drift/drift.dart';

import '../database/database.dart';

/// History and resume: what was played, and where it was left.
class PlayLog {
  const PlayLog(this.db);

  final MediaDatabase db;

  Future<int> recordPlay(
    int itemId, {
    DateTime? startedAt,
    bool completed = false,
  }) => db
      .into(db.plays)
      .insert(
        PlaysCompanion.insert(
          itemId: itemId,
          startedAt: startedAt ?? DateTime.now(),
          completed: Value(completed),
        ),
      );

  Future<int> playCount(int itemId) async {
    final count = db.plays.id.count();
    final row =
        await (db.selectOnly(db.plays)
              ..addColumns([count])
              ..where(db.plays.itemId.equals(itemId)))
            .getSingle();
    return row.read(count) ?? 0;
  }

  Future<List<PlayRow>> recent({int limit = 50}) =>
      (db.select(db.plays)
            ..orderBy([(p) => OrderingTerm.desc(p.startedAt)])
            ..limit(limit))
          .get();

  /// Where the item was left off. Books and Shows live on this.
  Future<void> setProgress(int itemId, Duration position) => db
      .into(db.progressEntries)
      .insertOnConflictUpdate(
        ProgressEntriesCompanion.insert(
          itemId: Value(itemId),
          positionMs: position.inMilliseconds,
          updatedAt: DateTime.now(),
        ),
      );

  Future<Duration?> progressOf(int itemId) async {
    final row = await (db.select(
      db.progressEntries,
    )..where((p) => p.itemId.equals(itemId))).getSingleOrNull();
    return row == null ? null : Duration(milliseconds: row.positionMs);
  }
}
