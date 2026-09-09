import '../filesystem.dart';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../database/database.dart';
import '../extract/extractor.dart';
import '../kinds.dart';
import '../metadata.dart';
import '../tags.dart';
import 'library_repository.dart';

/// The scanner's pen: every write a scan makes goes through here, so the
/// pipeline stays free of SQL and the search index never falls behind.
/// Scans update and annotate; nothing here deletes a file row.
class ScannerRepository {
  ScannerRepository(this.db) : _libraries = LibraryRepository(db);

  final MediaDatabase db;
  final LibraryRepository _libraries;

  /// The directories a library claims, oldest claim first.
  Future<List<LibraryRootRow>> rootsOf(int libraryId) =>
      (db.select(db.libraryRoots)
            ..where((r) => r.libraryId.equals(libraryId))
            ..orderBy([(r) => OrderingTerm.asc(r.id)]))
          .get();

  /// Claims [path] for the library and returns the root's id. Throws
  /// [StateError] when the library already claims it — the service reads
  /// that as a 409.
  Future<int> addRoot(int libraryId, String path) async {
    final existing =
        await (db.select(db.libraryRoots)..where(
              (r) => r.libraryId.equals(libraryId) & r.path.equals(path),
            ))
            .getSingleOrNull();
    if (existing != null) {
      throw StateError('already a root of library $libraryId: $path');
    }
    return db
        .into(db.libraryRoots)
        .insert(LibraryRootsCompanion.insert(libraryId: libraryId, path: path));
  }

  /// Releases a root. Files and items remain — the next scan decides what
  /// fell outside. Answers whether a row actually went away.
  Future<bool> removeRoot(int rootId) async {
    final gone = await (db.delete(
      db.libraryRoots,
    )..where((r) => r.id.equals(rootId))).go();
    return gone > 0;
  }

  /// The row at [path], or null when the database has never met it.
  Future<FileRow?> fileByPath(String path) => (db.select(
    db.files,
  )..where((f) => f.path.equals(path))).getSingleOrNull();

  /// Every file row living under any of [roots] — the scanner's diff base.
  /// Prefix matching is directory-honest: `/music` claims `/music/a.mp3`
  /// but not `/musical/b.mp3`.
  Future<List<FileRow>> filesUnderRoots(List<String> roots) async {
    if (roots.isEmpty) return const [];
    final rows = await db.select(db.files).get();
    return rows
        .where((row) => roots.any((root) => mediaPath.isWithin(root, row.path)))
        .toList();
  }

  /// Inserts the file, or refreshes it in place when the path is already
  /// known — the id, and with it items and their history, survives the
  /// update. A file just scanned is by definition present, so
  /// `missingSince` clears. Returns the file id.
  Future<int> upsertFileByPath({
    required String path,
    required int sizeBytes,
    required DateTime modifiedAt,
    required MediaMetadata metadata,
    DateTime? scannedAt,
  }) async {
    final existing = await fileByPath(path);
    if (existing == null) {
      return db
          .into(db.files)
          .insert(
            FilesCompanion.insert(
              path: path,
              sizeBytes: sizeBytes,
              modifiedAt: modifiedAt,
              kind: metadata.kind,
              metadata: jsonEncode(metadata.toJson()),
              scannedAt: Value.absentIfNull(scannedAt),
            ),
          );
    }
    await (db.update(db.files)..where((f) => f.id.equals(existing.id))).write(
      FilesCompanion(
        sizeBytes: Value(sizeBytes),
        modifiedAt: Value(modifiedAt),
        kind: Value(metadata.kind),
        metadata: Value(jsonEncode(metadata.toJson())),
        scannedAt: Value(scannedAt),
        missingSince: const Value(null),
      ),
    );
    return existing.id;
  }

  /// The file's fingerprints, wholesale: whatever was there goes, [hashes]
  /// lands.
  Future<void> replaceHashes(int fileId, Map<HashKind, String> hashes) =>
      db.transaction(() async {
        await (db.delete(
          db.fileHashes,
        )..where((h) => h.fileId.equals(fileId))).go();
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
      });

  /// Replaces the file's art in one [role]: rows of that role go, entries
  /// of that role among [artwork] land. Other roles are untouched — and
  /// other entries ignored — so the whole extraction haul can be handed
  /// over once per role.
  Future<void> replaceArtwork(
    int fileId,
    ArtworkRole role,
    List<ExtractedArtwork> artwork,
  ) => db.transaction(() async {
    await (db.delete(
      db.artworks,
    )..where((a) => a.fileId.equals(fileId) & a.role.equalsValue(role))).go();
    for (final art in artwork) {
      if (art.role != role) continue;
      await db
          .into(db.artworks)
          .insert(
            ArtworksCompanion.insert(
              fileId: fileId,
              role: role,
              mime: art.mime,
              data: Uint8List.fromList(art.bytes),
            ),
          );
    }
  });

  /// Remembers a sidecar beside a file; seeing it again refreshes the
  /// mtime and nothing else.
  Future<void> upsertSidecar({
    required int fileId,
    required String path,
    required SidecarKind kind,
    required DateTime modifiedAt,
  }) => db
      .into(db.sidecars)
      .insertOnConflictUpdate(
        SidecarsCompanion.insert(
          fileId: fileId,
          path: path,
          kind: kind,
          modifiedAt: modifiedAt,
        ),
      );

  /// Forgets a file's sidecars of one kind — the walk re-asserts whatever
  /// it still finds.
  Future<void> clearSidecars(int fileId, SidecarKind kind) => (db.delete(
    db.sidecars,
  )..where((s) => s.fileId.equals(fileId) & s.kind.equalsValue(kind))).go();

  /// Makes sure the file is an item of the library. A new item gets its
  /// automatic `kind/…` tag plus whatever [tags] the scanner brings (the
  /// `format/…` tag, typically); an existing one keeps its id and merely
  /// has the tags re-asserted. Either way the search index is refreshed —
  /// [LibraryRepository.addTag] re-indexes after every write, so a
  /// metadata update lands in FTS through the same door items entered by.
  Future<({int itemId, bool wasNew})> ensureItem(
    int libraryId,
    int fileId, {
    List<Tag> tags = const [],
  }) async {
    final file = await (db.select(
      db.files,
    )..where((f) => f.id.equals(fileId))).getSingle();
    final existing =
        await (db.select(db.libraryItems)..where(
              (i) => i.libraryId.equals(libraryId) & i.fileId.equals(fileId),
            ))
            .getSingleOrNull();
    final itemId =
        existing?.id ??
        await db
            .into(db.libraryItems)
            .insert(
              LibraryItemsCompanion.insert(
                libraryId: libraryId,
                fileId: fileId,
              ),
            );
    await _libraries.addTag(itemId, Tag.ofKind(file.kind));
    for (final tag in tags) {
      await _libraries.addTag(itemId, tag);
    }
    return (itemId: itemId, wasNew: existing == null);
  }

  /// Stamps [at] on files a scan could not find — only where no stamp is
  /// set, so the first absence is the one remembered.
  Future<void> markMissing(List<int> fileIds, DateTime at) async {
    if (fileIds.isEmpty) return;
    await (db.update(db.files)
          ..where((f) => f.id.isIn(fileIds) & f.missingSince.isNull()))
        .write(FilesCompanion(missingSince: Value(at)));
  }

  /// The file came back: the absence stamp goes.
  Future<void> clearMissing(int fileId) =>
      (db.update(db.files)..where((f) => f.id.equals(fileId))).write(
        const FilesCompanion(missingSince: Value(null)),
      );

  /// A move, recognized: the row keeps its id — and with it items, tags,
  /// history — while the path catches up. Being found again clears
  /// `missingSince`.
  Future<void> rewritePath(int fileId, String newPath) =>
      (db.update(db.files)..where((f) => f.id.equals(fileId))).write(
        FilesCompanion(path: Value(newPath), missingSince: const Value(null)),
      );
}
