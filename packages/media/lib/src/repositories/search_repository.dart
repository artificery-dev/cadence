import 'dart:convert';

import 'package:drift/drift.dart';

import '../database/database.dart';
import '../metadata.dart';

/// The FTS5 index: fed on write by [LibraryRepository], asked on read here.
/// A full [rebuild] walks the database when the index and the world drift
/// apart.
class SearchRepository {
  const SearchRepository(this.db);

  final MediaDatabase db;

  /// Item ids matching [query], best first. FTS5 syntax is the caller's to
  /// wield; quotes are tamed so a stray one can't break the statement.
  Future<List<int>> search(String query) async {
    final cleaned = query.replaceAll('"', ' ').trim();
    if (cleaned.isEmpty) return const [];
    // Every token as a prefix query, so typing feels like filtering.
    final match = cleaned
        .split(RegExp(r'\s+'))
        .map((token) => '"$token"*')
        .join(' ');
    final rows = await db
        .customSelect(
          'SELECT item_id FROM search_index WHERE search_index MATCH ? '
          'ORDER BY rank',
          variables: [Variable(match)],
        )
        .get();
    return [for (final row in rows) row.read<int>('item_id')];
  }

  /// Writes one item's row, replacing whatever the index held for it.
  Future<void> indexItem(
    int itemId, {
    required String title,
    String? artist,
    String? album,
    Iterable<String> tags = const [],
  }) async {
    await removeItem(itemId);
    await db.customStatement(
      'INSERT INTO search_index (item_id, title, artist, album, tags) '
      'VALUES (?, ?, ?, ?, ?)',
      [itemId, title, artist ?? '', album ?? '', tags.join(' ')],
    );
  }

  Future<void> removeItem(int itemId) => db.customStatement(
    'DELETE FROM search_index WHERE item_id = ?',
    [itemId],
  );

  /// Drops the index and rebuilds it from the database — the escape hatch.
  Future<void> rebuild() async {
    await db.customStatement('DELETE FROM search_index');
    final rows = await (db.select(db.libraryItems).join([
      innerJoin(db.files, db.files.id.equalsExp(db.libraryItems.fileId)),
    ])).get();
    for (final row in rows) {
      final item = row.readTable(db.libraryItems);
      final file = row.readTable(db.files);
      final metadata = MediaMetadata.fromJson(
        file.kind,
        jsonDecode(file.metadata) as Map<String, Object?>,
      );
      final tagRows = await (db.select(
        db.itemTags,
      )..where((t) => t.itemId.equals(item.id))).get();
      final (title, artist, album) = switch (metadata) {
        AudioMetadata m => (m.title, m.artist, m.album),
        VideoMetadata m => (m.title, null, null),
        ImageMetadata m => (m.title ?? '', null, null),
        DocumentMetadata m => (m.title, m.author, null),
      };
      await indexItem(
        item.id,
        title: title,
        artist: artist,
        album: album,
        tags: [for (final t in tagRows) '${t.namespace}/${t.name}'],
      );
    }
  }
}
