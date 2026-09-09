import '../filesystem.dart';

import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:mime/mime.dart';

import '../database/database.dart';
import '../extract/extract.dart';
import '../extract/extractor.dart';
import '../extract/format.dart';
import '../extract/image_extractor.dart' as images;
import '../extract/sidecar.dart';
import '../kinds.dart';
import '../metadata.dart';
import '../repositories/scanner_repository.dart';
import '../tags.dart';
import 'hasher.dart';

import 'scan_jobs.dart';
import 'scan_policy.dart';

/// Builds an extractor within the injected filesystem scope.
typedef ExtractorBuilder = MediaExtractor Function();

/// Renders a thumbnail from image bytes, or admits defeat with null.
/// Matches [images.renderThumbnail], which is the default.
typedef ThumbnailRenderer =
    ExtractedArtwork? Function(List<int> bytes, {int longestSide});

/// Pairs media files with the sidecars that serve them. Matches
/// [associateSidecars], which is the default.
typedef SidecarAssociator =
    Map<String, List<SidecarMatch>> Function({
      required List<String> mediaFiles,
      required List<String> otherFiles,
    });

/// One thing that went wrong, pinned to the path it went wrong at. A scan
/// collects these and keeps walking; it never throws over a single file.
class ScanError {
  const ScanError(this.path, this.message);

  final String path;
  final String message;

  Map<String, Object?> toJson() => {'path': path, 'message': message};

  @override
  String toString() => 'ScanError($path: $message)';
}

/// The running tally of a scan: what it saw, what it did about it, and
/// what refused to cooperate. Counters move while the scan does, so a
/// status poll mid-flight reads honest numbers.
class ScanProgress {
  /// Media files the walk encountered.
  int seen = 0;

  /// Files the diff sent to the workers: new, or changed in size or
  /// mtime. Known once the walk is over; what [added] and [updated]
  /// climb towards. A scan of an unchanged library reads zero here and
  /// has nothing to announce.
  int changed = 0;

  /// Files the database had never met.
  int added = 0;

  /// Known files whose size or mtime had shifted, re-read in place.
  int updated = 0;

  /// Vanished paths recognised by their sha256 at a new address.
  int moved = 0;

  /// Files a previous scan knew that this one could not find.
  int missing = 0;

  /// Sidecar rows asserted: lyrics, subtitles, folder art.
  int sidecars = 0;

  /// Artwork rows landed, thumbnails included.
  int artwork = 0;

  /// Files noted and left alone: unknown extensions, loose images in
  /// libraries that don't collect them, sidecars serving nobody.
  int skipped = 0;

  /// Per-file failures, in the order they surfaced.
  final List<ScanError> errors = [];

  int get errorCount => errors.length;
}

/// Incremental library scanner. Extraction runs in bounded asynchronous batches
/// in the caller's filesystem scope; writes stay on the database owner.
/// Disappearing files are annotated, never deleted. Unavailable or unreadable
/// scopes are excluded from missing detection. Symlinks are skipped.
class LibraryScanner {
  LibraryScanner(
    this.db, {
    FileSystem? fileSystem,
    this.buildExtractor = defaultMediaExtractor,
    this.renderThumbnail = images.renderThumbnail,
    this.associate = associateSidecars,
    int? concurrency,
    this.batchSize = 8,
    this.policy = ScanPolicy.full,
    this.rootAvailable = _available,
  }) : fileSystem = fileSystem ?? mediaFileSystem,
       concurrency = concurrency ?? 2 {
    if (batchSize < 1 || this.concurrency < 1 || policy.thumbnailSide < 1) {
      throw ArgumentError("Scan budgets must be positive");
    }
  }

  final FileSystem fileSystem;

  static bool _available(String _) => true;
  final bool Function(String) rootAvailable;
  final MediaDatabase db;

  /// Hashing and artwork budget for this scan.
  final ScanPolicy policy;
  final ExtractorBuilder buildExtractor;
  final ThumbnailRenderer renderThumbnail;
  final SidecarAssociator associate;
  final int concurrency;

  /// Cancellation is cooperative between files during walking and batches during extraction.
  final int batchSize;

  /// Scans library [libraryId] and returns the tally. [progress] lets a
  /// caller hold the live counters (the coordinator does, for status
  /// polls); [shouldCancel] is consulted between batches; [onStage] hears
  /// the phase changes; [onlyDirs] narrows the scan to those directories,
  /// non-recursively — the watcher's incremental path.
  Future<ScanProgress> scan(
    int libraryId, {
    ScanProgress? progress,
    bool Function()? shouldCancel,
    void Function(ScanState stage)? onStage,
    Set<String>? onlyDirs,
  }) => withMediaFileSystem(
    fileSystem,
    () => _scan(
      libraryId,
      progress: progress,
      shouldCancel: shouldCancel,
      onStage: onStage,
      onlyDirs: onlyDirs,
    ),
  );

  Future<ScanProgress> _scan(
    int libraryId, {
    ScanProgress? progress,
    bool Function()? shouldCancel,
    void Function(ScanState stage)? onStage,
    Set<String>? onlyDirs,
  }) async {
    final out = progress ?? ScanProgress();
    final cancelled = shouldCancel ?? _never;
    final stage = onStage ?? _quietly;
    final repo = ScannerRepository(db);

    final library = await (db.select(
      db.libraries,
    )..where((l) => l.id.equals(libraryId))).getSingleOrNull();
    if (library == null) {
      throw ArgumentError.value(libraryId, 'libraryId', 'not a library');
    }
    final imagesAreItems = library.type == LibraryType.images;

    stage(ScanState.walking);
    final roots = await repo.rootsOf(libraryId);
    final rootPaths = [for (final root in roots) root.path];
    final unavailable = <String>{};
    // Both keyed by path, because nested or overlapping roots walk the
    // same ground twice and a file must land once no matter how many
    // roots claim it.
    final walked = <String, _WalkedFile>{};
    final others = <String>{};
    for (final root in roots) {
      if (!rootAvailable(root.path) ||
          !mediaFileSystem.directory(root.path).existsSync()) {
        unavailable.add(root.path);
      }
    }
    if (onlyDirs == null) {
      for (final root in roots) {
        final dir = mediaFileSystem.directory(root.path);
        if (!rootAvailable(root.path) || !dir.existsSync()) {
          unavailable.add(root.path);
          out.errors.add(ScanError(root.path, 'root directory is missing'));
          continue;
        }
        await _walk(
          dir,
          shouldCancel: cancelled,
          recurse: true,
          imagesAreItems: imagesAreItems,
          walked: walked,
          others: others,
          out: out,
        );
      }
    } else {
      for (final dirPath in onlyDirs) {
        if (!_inScope(dirPath, rootPaths) ||
            unavailable.any(
              (root) =>
                  mediaPath.equals(root, dirPath) ||
                  mediaPath.isWithin(root, dirPath),
            )) {
          continue;
        }
        final dir = mediaFileSystem.directory(dirPath);
        // A directory that vanished still matters: its rows fall through
        // to the missing set below.
        if (!dir.existsSync()) continue;
        await _walk(
          dir,
          shouldCancel: cancelled,
          recurse: false,
          imagesAreItems: imagesAreItems,
          walked: walked,
          others: others,
          out: out,
        );
      }
    }

    var known = await repo.filesUnderRoots(rootPaths);
    final unsafe = [...unavailable, ...out.errors.map((e) => e.path)];
    known = known
        .where(
          (row) => !unsafe.any(
            (path) =>
                mediaPath.equals(path, row.path) ||
                mediaPath.isWithin(path, row.path),
          ),
        )
        .toList();
    if (onlyDirs != null) {
      known = [
        for (final row in known)
          if (onlyDirs.any(
            (dir) => mediaPath.equals(dir, mediaPath.dirname(row.path)),
          ))
            row,
      ];
    }
    // Legacy sampled-only records must be indexed even when their stat is unchanged.
    final fullHashes = await (db.select(
      db.fileHashes,
    )..where((h) => h.kind.equalsValue(HashKind.sha256))).get();
    final fullyHashed = {for (final hash in fullHashes) hash.fileId};
    final knownByPath = {for (final row in known) row.path: row};
    final missingRows = {
      for (final row in known)
        if (!walked.containsKey(row.path)) row.id: row,
    };

    final jobs = <_ScanJob>[];
    final fileIdByPath = <String, int>{};
    for (final file in walked.values) {
      final row = knownByPath[file.path];
      if (row == null) {
        jobs.add(
          _ScanJob(
            path: file.path,
            kind: file.kind,
            sizeBytes: file.sizeBytes,
            modifiedAt: file.modifiedAt,
          ),
        );
      } else if (fullyHashed.contains(row.id) &&
          row.sizeBytes == file.sizeBytes &&
          _sameSecond(row.modifiedAt, file.modifiedAt)) {
        fileIdByPath[file.path] = row.id;
        if (row.missingSince != null) await repo.clearMissing(row.id);
      } else {
        jobs.add(
          _ScanJob(
            path: file.path,
            kind: file.kind,
            sizeBytes: file.sizeBytes,
            modifiedAt: file.modifiedAt,
            existingId: row.id,
          ),
        );
      }
    }

    out.changed = jobs.length;

    // Only full file hashes can establish identity for move matching.
    final missingBySha = <String, FileRow>{};
    if (missingRows.isNotEmpty) {
      final hashRows =
          await (db.select(db.fileHashes)..where(
                (h) =>
                    h.fileId.isIn(missingRows.keys) &
                    h.kind.equalsValue(HashKind.sha256),
              ))
              .get();
      for (final hash in hashRows) {
        final row = missingRows[hash.fileId];
        if (row != null) missingBySha[hash.value] = row;
      }
    }

    stage(ScanState.extracting);
    final batches = <List<_ScanJob>>[
      for (var i = 0; i < jobs.length; i += batchSize)
        jobs.sublist(i, math.min(i + batchSize, jobs.length)),
    ];
    final local = buildExtractor();
    var next = 0;
    Future<void> work(int lane) async {
      while (!cancelled() && next < batches.length) {
        final order = _WorkOrder(
          batches[next++],
          buildExtractor,
          renderThumbnail,
          policy,
        );
        final results = await _workWith(local, order);
        if (cancelled()) break;
        await _writeResults(
          repo,
          libraryId,
          results,
          out,
          fileIdByPath: fileIdByPath,
          missingRows: missingRows,
          missingBySha: missingBySha,
        );
        await Future<void>.delayed(Duration.zero);
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) work(i)]);

    if (cancelled()) return out;
    stage(ScanState.finishing);

    // A host may mark a root unavailable while extraction was in flight.
    missingRows.removeWhere(
      (_, row) => roots.any(
        (root) =>
            mediaPath.isWithin(root.path, row.path) &&
            (!rootAvailable(root.path) ||
                !mediaFileSystem.directory(root.path).existsSync()),
      ),
    );
    if (missingRows.isNotEmpty) {
      await repo.markMissing(missingRows.keys.toList(), DateTime.now());
      out.missing += missingRows.length;
    }

    // A file the diff left alone can still be a stranger to this library —
    // a root shared with another library, a library rebuilt over an
    // already-scanned corpus. Membership is asserted wherever it is absent;
    // files the batches just wrote brought their items with them.
    final itemRows = await (db.select(
      db.libraryItems,
    )..where((i) => i.libraryId.equals(libraryId))).get();
    final withItems = {for (final row in itemRows) row.fileId};
    for (final MapEntry(key: path, value: fileId) in fileIdByPath.entries) {
      if (withItems.contains(fileId)) continue;
      await repo.ensureItem(
        libraryId,
        fileId,
        tags: [Tag.ofFormat(formatTag(path))],
      );
    }

    final matches = associate(
      mediaFiles: walked.keys.toList(),
      otherFiles: others.toList(),
    );
    final claimed = {
      for (final list in matches.values)
        for (final match in list) match.path,
    };
    out.skipped += others.where((other) => !claimed.contains(other)).length;

    // The epilogue - sidecars and folder art - is a write per file, and
    // an unchanged library has thousands of files. So it runs only where
    // something moved: a directory with a new or changed file, or with a
    // sidecar that is new, changed, or gone since the last scan. The
    // rest of the library keeps what the last scan wrote.
    final dirty = <String>{for (final job in jobs) mediaPath.dirname(job.path)};
    if (onlyDirs != null) dirty.addAll(onlyDirs);
    final knownSidecars = <String, DateTime>{};
    final sidecarRows = await (db.select(db.sidecars).join([
      innerJoin(db.files, db.files.id.equalsExp(db.sidecars.fileId)),
    ])..where(db.files.path.isIn(walked.keys))).get();
    for (final row in sidecarRows) {
      final sidecar = row.readTable(db.sidecars);
      knownSidecars[sidecar.path] = sidecar.modifiedAt;
    }
    for (final path in claimed) {
      final known = knownSidecars[path];
      if (known == null) {
        dirty.add(mediaPath.dirname(path));
        continue;
      }
      final stat = mediaFileSystem.file(path).statSync();
      if (!_sameSecond(known, stat.modified)) {
        dirty.add(mediaPath.dirname(path));
      }
    }
    for (final path in knownSidecars.keys) {
      if (!claimed.contains(path)) dirty.add(mediaPath.dirname(path));
    }

    // Directory by directory, so the cover bytes cached for an album's
    // tracks are let go before the next album's are read — folder art is
    // only ever shared within its own directory.
    final walkedByDir = <String, List<String>>{};
    for (final path in walked.keys) {
      final dir = mediaPath.dirname(path);
      if (!dirty.contains(dir)) continue;
      walkedByDir.putIfAbsent(dir, () => []).add(path);
    }
    for (final dirPaths in walkedByDir.values) {
      final coverCache = <String, List<int>>{};
      for (final path in dirPaths) {
        final fileId = fileIdByPath[path];
        if (fileId == null) continue;
        final byKind = <SidecarKind, List<SidecarMatch>>{};
        for (final match in matches[path] ?? const <SidecarMatch>[]) {
          byKind.putIfAbsent(match.kind, () => []).add(match);
        }
        for (final kind in SidecarKind.values) {
          await repo.clearSidecars(fileId, kind);
          for (final match in byKind[kind] ?? const <SidecarMatch>[]) {
            final stat = mediaFileSystem.file(match.path).statSync();
            if (stat.type == FileSystemEntityType.notFound) continue;
            await repo.upsertSidecar(
              fileId: fileId,
              path: match.path,
              kind: kind,
              modifiedAt: stat.modified,
            );
            out.sidecars++;
          }
        }
        await _ingestFolderArt(
          repo,
          fileId,
          byKind[SidecarKind.artwork] ?? const [],
          coverCache,
          out,
        );
      }
    }
    return out;
  }

  /// One directory's worth of walking: dotfiles and dot-directories are
  /// invisible (`.cadence` among them), symlinked directories are cycle
  /// bait and skipped, and a directory that refuses to list becomes an
  /// error entry rather than a crash.
  Future<void> _walk(
    Directory dir, {
    required bool Function() shouldCancel,
    required bool recurse,
    required bool imagesAreItems,
    required Map<String, _WalkedFile> walked,
    required Set<String> others,
    required ScanProgress out,
  }) async {
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (shouldCancel()) return;
        await Future<void>.delayed(Duration.zero);
        final name = mediaPath.basename(entity.path);
        if (name.startsWith('.')) continue;
        if (entity is Directory) {
          if (recurse) {
            await _walk(
              entity,
              shouldCancel: shouldCancel,
              recurse: true,
              imagesAreItems: imagesAreItems,
              walked: walked,
              others: others,
              out: out,
            );
          }
          continue;
        }
        final path = entity.path;
        if (entity is Link) continue;
        final kind = classify(path);
        if (kind == null || (kind == MediaKind.image && !imagesAreItems)) {
          // Not an item here — but perhaps a sidecar; association decides,
          // and whatever nobody claims is counted skipped.
          others.add(path);
          continue;
        }
        if (walked.containsKey(path)) continue;
        final stat = await mediaFileSystem.file(path).stat();
        if (stat.type == FileSystemEntityType.notFound) continue;
        walked[path] = _WalkedFile(path, kind, stat.size, stat.modified);
        out.seen++;
      }
    } on Object catch (error) {
      out.errors.add(ScanError(dir.path, '$error'));
    }
  }

  /// Whether an incremental target sits inside a root without hiding
  /// behind a dot-directory on the way.
  bool _inScope(String dir, List<String> rootPaths) {
    for (final root in rootPaths) {
      if (mediaPath.equals(root, dir)) return true;
      if (!mediaPath.isWithin(root, dir)) continue;
      final segments = mediaPath.split(mediaPath.relative(dir, from: root));
      return !segments.any((segment) => segment.startsWith('.'));
    }
    return false;
  }

  /// Lands one batch of worker results in a single transaction: moves
  /// recognised before rows are born, files upserted in place, hashes and
  /// artwork replaced, items ensured, the search index fed on the way.
  Future<void> _writeResults(
    ScannerRepository repo,
    int libraryId,
    List<_JobResult> results,
    ScanProgress out, {
    required Map<String, int> fileIdByPath,
    required Map<int, FileRow> missingRows,
    required Map<String, FileRow> missingBySha,
  }) => db.transaction(() async {
    for (final result in results) {
      final job = result.job;
      if (result.error != null) {
        out.errors.add(ScanError(job.path, result.error!));
        continue;
      }
      final metadata = MediaMetadata.fromJson(job.kind, result.metadataJson!);
      final scannedAt = DateTime.now();

      FileRow? movedFrom;
      if (job.isNew) {
        final candidate = missingBySha.remove(result.sha256);
        if (candidate != null &&
            mediaFileSystem.file(candidate.path).existsSync()) {
          // The bytes travelled but the original stayed — a copy, not a
          // move. Put the candidate back for a scan that misses it.
          missingBySha[result.sha256!] = candidate;
        } else if (candidate != null) {
          movedFrom = candidate;
        }
      }

      final int fileId;
      if (movedFrom != null) {
        await repo.rewritePath(movedFrom.id, job.path);
        fileId = await repo.upsertFileByPath(
          path: job.path,
          sizeBytes: job.sizeBytes,
          modifiedAt: job.modifiedAt,
          metadata: metadata,
          scannedAt: scannedAt,
        );
        missingRows.remove(movedFrom.id);
        out.moved++;
      } else {
        fileId = await repo.upsertFileByPath(
          path: job.path,
          sizeBytes: job.sizeBytes,
          modifiedAt: job.modifiedAt,
          metadata: metadata,
          scannedAt: scannedAt,
        );
        if (job.isNew) {
          out.added++;
        } else {
          out.updated++;
        }
      }
      fileIdByPath[job.path] = fileId;
      await repo.replaceHashes(fileId, {
        ...result.hashes,
        HashKind.sha256: result.sha256!,
      });
      // The worker has already dropped what the policy does not keep;
      // both roles are replaced regardless, so a policy change clears
      // what an earlier scan wrote.
      await repo.replaceArtwork(fileId, ArtworkRole.embedded, result.artwork);
      await repo.replaceArtwork(fileId, ArtworkRole.thumbnail, result.artwork);
      out.artwork += result.artwork.length;
      await repo.ensureItem(
        libraryId,
        fileId,
        tags: [Tag.ofFormat(formatTag(job.path))],
      );
    }
  });

  /// Attaches the directory's art to a file — and, when the file still has
  /// no thumbnail of its own, renders one from that art. A thumbnail
  /// already in place is left alone.
  Future<void> _ingestFolderArt(
    ScannerRepository repo,
    int fileId,
    List<SidecarMatch> art,
    Map<String, List<int>> cache,
    ScanProgress out,
  ) async {
    if (art.isEmpty || !policy.rendersThumbnails) {
      await repo.replaceArtwork(fileId, ArtworkRole.folder, const []);
      return;
    }
    final entries = <ExtractedArtwork>[];
    for (final match in art) {
      try {
        final bytes = cache[match.path] ??= mediaFileSystem
            .file(match.path)
            .readAsBytesSync();
        entries.add(
          ExtractedArtwork(
            bytes: bytes,
            mime: lookupMimeType(match.path) ?? 'application/octet-stream',
            role: ArtworkRole.folder,
          ),
        );
      } on Object catch (error) {
        out.errors.add(ScanError(match.path, '$error'));
      }
    }
    final kept = policy.keeps(ArtworkRole.folder);
    await repo.replaceArtwork(
      fileId,
      ArtworkRole.folder,
      kept ? entries : const [],
    );
    if (kept) out.artwork += entries.length;
    if (entries.isEmpty || await _hasThumbnail(fileId)) return;
    ExtractedArtwork? thumb;
    try {
      thumb = renderThumbnail(
        entries.first.bytes,
        longestSide: policy.thumbnailSide,
      );
    } on Object {
      thumb = null;
    }
    if (thumb == null) return;
    await repo.replaceArtwork(fileId, ArtworkRole.thumbnail, [thumb]);
    out.artwork++;
  }

  Future<bool> _hasThumbnail(int fileId) async {
    final rows =
        await (db.select(db.artworks)
              ..where(
                (a) =>
                    a.fileId.equals(fileId) &
                    a.role.equalsValue(ArtworkRole.thumbnail),
              )
              ..limit(1))
            .get();
    return rows.isNotEmpty;
  }
}

/// Drift stores datetimes to the second; comparing any finer would call
/// every file changed on every scan.
bool _sameSecond(DateTime a, DateTime b) =>
    a.millisecondsSinceEpoch ~/ 1000 == b.millisecondsSinceEpoch ~/ 1000;

bool _never() => false;

void _quietly(ScanState _) {}

/// A file the walk found and stat'd, waiting for the diff.
class _WalkedFile {
  const _WalkedFile(this.path, this.kind, this.sizeBytes, this.modifiedAt);

  final String path;
  final MediaKind kind;
  final int sizeBytes;
  final DateTime modifiedAt;
}

/// One file's worth of work for the pool: where it is, what it is, and —
/// when the database already knows the path — whose row to refresh.
class _ScanJob {
  const _ScanJob({
    required this.path,
    required this.kind,
    required this.sizeBytes,
    required this.modifiedAt,
    this.existingId,
  });

  final String path;
  final MediaKind kind;
  final int sizeBytes;
  final DateTime modifiedAt;
  final int? existingId;

  bool get isNew => existingId == null;
}

/// A batch and the recipes it travels with. Everything here crosses the
/// port; nothing here holds a database or a loaded library.
class _WorkOrder {
  const _WorkOrder(
    this.jobs,
    this.buildExtractor,
    this.renderThumbnail,
    this.policy,
  );

  final List<_ScanJob> jobs;
  final ExtractorBuilder buildExtractor;
  final ThumbnailRenderer renderThumbnail;
  final ScanPolicy policy;
}

/// What a worker sends home for one file: plain data only — the metadata
/// as JSON, artwork as bytes, hashes as strings. Or the failure, named.
class _JobResult {
  const _JobResult.ok(
    this.job, {
    required String this.sha256,
    required Map<String, Object?> this.metadataJson,
    required this.artwork,
    required this.hashes,
  }) : error = null;

  const _JobResult.failed(this.job, String this.error)
    : sha256 = null,
      metadataJson = null,
      artwork = const [],
      hashes = const {};

  final _ScanJob job;
  final String? error;
  final String? sha256;
  final Map<String, Object?>? metadataJson;
  final List<ExtractedArtwork> artwork;
  final Map<HashKind, String> hashes;
}

Future<List<_JobResult>> _workWith(
  MediaExtractor extractor,
  _WorkOrder order,
) async {
  final results = <_JobResult>[];
  final policy = order.policy;
  for (final job in order.jobs) {
    try {
      final sha = await sha256OfFile(job.path);
      final extracted = await extractor.extract(job.path, job.kind);
      final artwork = List<ExtractedArtwork>.of(extracted.artwork);
      if (policy.rendersThumbnails &&
          !artwork.any((a) => a.role == ArtworkRole.thumbnail)) {
        final thumb = _thumbnailFor(
          job,
          artwork,
          order.renderThumbnail,
          policy.thumbnailSide,
        );
        if (thumb != null) artwork.add(thumb);
      }
      results.add(
        _JobResult.ok(
          job,
          sha256: sha,
          metadataJson: extracted.metadata.toJson(),
          artwork: [
            for (final art in artwork)
              if (policy.keeps(art.role)) art,
          ],
          hashes: extracted.hashes,
        ),
      );
    } on Object catch (error) {
      results.add(_JobResult.failed(job, '$error'));
    }
  }
  return results;
}

/// Where a file's thumbnail comes from: the image itself when the file is
/// one, otherwise its embedded art. Folder art waits for the finishing
/// phase — the walk knows the directory, the worker doesn't.
ExtractedArtwork? _thumbnailFor(
  _ScanJob job,
  List<ExtractedArtwork> artwork,
  ThumbnailRenderer render,
  int longestSide,
) {
  List<int>? source;
  if (job.kind == MediaKind.image) {
    source = mediaFileSystem.file(job.path).readAsBytesSync();
  } else {
    for (final art in artwork) {
      if (art.role == ArtworkRole.embedded) {
        source = art.bytes;
        break;
      }
    }
  }
  if (source == null) return null;
  try {
    return render(source, longestSide: longestSide);
  } on Object {
    return null;
  }
}
