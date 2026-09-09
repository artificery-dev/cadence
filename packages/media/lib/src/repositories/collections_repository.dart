import 'package:drift/drift.dart';

import '../database/database.dart';

/// Collections: ordered, person-made lists of items from any shelf — a
/// playlist, a reading order, a watch order — played in their laid
/// order, reordered freely, shuffled and looped when asked.
class CollectionsRepository {
  const CollectionsRepository(this.db);

  final MediaDatabase db;

  Future<int> create(String name) =>
      db.into(db.collections).insert(CollectionsCompanion.insert(name: name));

  Future<void> rename(int collectionId, String name) =>
      (db.update(db.collections)..where((c) => c.id.equals(collectionId)))
          .write(CollectionsCompanion(name: Value(name)));

  Future<void> delete(int collectionId) =>
      (db.delete(db.collections)..where((c) => c.id.equals(collectionId))).go();

  Future<List<CollectionRow>> listCollections() =>
      db.select(db.collections).get();

  Stream<List<CollectionRow>> watchCollections() =>
      db.select(db.collections).watch();

  /// The item ids, in play order.
  Future<List<int>> entries(int collectionId) async {
    final rows =
        await (db.select(db.collectionEntries)
              ..where((e) => e.collectionId.equals(collectionId))
              ..orderBy([(e) => OrderingTerm.asc(e.position)]))
            .get();
    return [for (final row in rows) row.itemId];
  }

  /// Replaces the whole order — reordering is a rewrite, which keeps
  /// positions dense and the logic honest.
  Future<void> setEntries(int collectionId, List<int> itemIds) =>
      db.transaction(() async {
        await (db.delete(
          db.collectionEntries,
        )..where((e) => e.collectionId.equals(collectionId))).go();
        for (final (position, itemId) in itemIds.indexed) {
          await db
              .into(db.collectionEntries)
              .insert(
                CollectionEntriesCompanion.insert(
                  collectionId: collectionId,
                  position: position,
                  itemId: itemId,
                ),
              );
        }
      });
}
