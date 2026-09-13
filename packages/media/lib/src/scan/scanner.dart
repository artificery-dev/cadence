import '../filesystem.dart';

import 'dart:convert';
import 'scan_work.dart';

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

import 'scan_budget.dart';
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

  int discovered = 0;
  int enriched = 0;

  /// Files the database had never met.
  int added = 0;

  /// Known files whose size or mtime had shifted, re-read in place.
  int updated = 0;

  /// Vanished paths recognised by their identity hash at a new address.
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

/// Incremental library scanner. Discovery and enrichment run with bounded concurrency
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
    this.onChange,
    this.hashFile = sampledSha256OfFile,
    ScanBudget? budget,
  }) : fileSystem = fileSystem ?? mediaFileSystem,
       budget = budget ?? ScanBudget(),
       concurrency = concurrency ?? 2 {
    if (batchSize < 1 || this.concurrency < 1 || policy.thumbnailSide < 1) {
      throw ArgumentError("Scan budgets must be positive");
    }
  }

  final FileSystem fileSystem;

  /// Post-commit change hints. Clients can re-query items after any notification.
  final void Function(Map<String, Object?> event)? onChange;
  void _notify(Map<String, Object?> event) {
    try {
      onChange?.call(event);
    } catch (_) {
      /* Observers cannot undo commits. */
    }
  }

  static bool _available(String _) => true;
  final bool Function(String) rootAvailable;
  final MediaDatabase db;
  final Future<String> Function(String path) hashFile;

  /// Hashing and artwork policy for this scan.
  final ScanPolicy policy;

  /// How fast the scan may read; shared with whatever else reads the
  /// library, so the host sets one pace for all of it.
  final ScanBudget budget;
  final ExtractorBuilder buildExtractor;
  final ThumbnailRenderer renderThumbnail;
  final SidecarAssociator associate;
  final int concurrency;

  /// Retained batch budget for API compatibility; items now commit individually.
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
    void stage(ScanState value) {
      onStage?.call(value);
      _notify({
        'type': 'scan-phase-changed',
        'libraryId': libraryId,
        'phase': switch (value) {
          ScanState.walking => 'scan',
          ScanState.discovering => 'discover',
          ScanState.extracting => 'metadata',
          ScanState.finishing => 'finish',
          _ => value.name,
        },
      });
    }

    final repo = ScannerRepository(db);
    final work = ScanWork(db);
    final pending = await work.pending(libraryId);

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
    // A file counts as read once an identity hash stands for it: the
    // sampled hash a scan writes today, or the full sha256 of a scan
    // before 0.11. Either keeps an unchanged file from being read again;
    // a row without one is indexed afresh whatever its stat says.
    final identityRows =
        await (db.select(db.fileHashes)..where(
              (h) =>
                  h.kind.isInValues([HashKind.sampledSha256, HashKind.sha256]),
            ))
            .get();
    final identified = {for (final hash in identityRows) hash.fileId};
    final knownByPath = {for (final row in known) row.path: row};
    final missingRows = {
      for (final row in known)
        if (!walked.containsKey(row.path)) row.id: row,
    };

    final jobs = <_ScanJob>[];
    final enrichment = <_ScanJob>[];
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
      } else if (row.scannedAt != null &&
          identified.contains(row.id) &&
          row.sizeBytes == file.sizeBytes &&
          _sameSecond(row.modifiedAt, file.modifiedAt) &&
          (pending[file.path] == null ||
              (pending[file.path]!.read<int>('modified_ms') ==
                      file.modifiedAt.millisecondsSinceEpoch &&
                  pending[file.path]!.read<int>('size_bytes') ==
                      file.sizeBytes))) {
        fileIdByPath[file.path] = row.id;
        if (row.missingSince != null) await repo.clearMissing(row.id);
        if (pending.containsKey(file.path)) {
          final job = _ScanJob(
            path: file.path,
            kind: file.kind,
            sizeBytes: file.sizeBytes,
            modifiedAt: file.modifiedAt,
            existingId: row.id,
          );
          if (pending[file.path]!.read<String>('stage') == 'metadata') {
            enrichment.add(job);
          } else {
            jobs.add(job);
          }
        }
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

    if (cancelled()) return out;
    // Finish Scan by journaling work. No file contents are read in this phase.
    await db.transaction(() async {
      for (final job in jobs) {
        await work.enqueue(
          libraryId,
          job.path,
          job.sizeBytes,
          job.modifiedAt,
          job.kind.name,
        );
      }
      for (final path in pending.keys) {
        if (!walked.containsKey(path) &&
            !unsafe.any(
              (root) =>
                  mediaPath.equals(root, path) ||
                  mediaPath.isWithin(root, path),
            ) &&
            (onlyDirs == null ||
                onlyDirs.any(
                  (dir) => mediaPath.equals(dir, mediaPath.dirname(path)),
                ))) {
          await work.complete(libraryId, path);
        }
      }
    });
    out.changed = jobs.length + enrichment.length;
    _notify({
      'type': 'scan-work-queued',
      'libraryId': libraryId,
      'discover': jobs.length,
      'metadata': enrichment.length,
    });

    // A missing file is recognised elsewhere by its identity hash. Only
    // the sampled kind can match: a legacy full sha256 is never computed
    // again, so a file it named is a stranger once it moves.
    final missingBySha = <String, FileRow>{};
    if (missingRows.isNotEmpty) {
      final hashRows =
          await (db.select(db.fileHashes)..where(
                (h) =>
                    h.fileId.isIn(missingRows.keys) &
                    h.kind.equalsValue(HashKind.sampledSha256),
              ))
              .get();
      for (final hash in hashRows) {
        final row = missingRows[hash.fileId];
        if (row != null) missingBySha[hash.value] = row;
      }
    }

    stage(ScanState.discovering);
    var next = 0;
    bool available(_ScanJob job) => roots.any(
      (root) =>
          mediaPath.isWithin(root.path, job.path) &&
          rootAvailable(root.path) &&
          mediaFileSystem.directory(root.path).existsSync(),
    );
    Future<void> discover() async {
      while (!cancelled() && next < jobs.length) {
        final job = jobs[next++];
        try {
          if (!available(job)) throw StateError('Root unavailable');
          final before = await mediaFileSystem.file(job.path).stat();
          final sha = await hashFile(job.path);
          await budget.charge(ScanBudget.discoverCost(job.sizeBytes));
          final after = await mediaFileSystem.file(job.path).stat();
          if (before.size != job.sizeBytes ||
              before.modified != job.modifiedAt ||
              after.size != before.size ||
              after.modified != before.modified) {
            throw StateError('File changed during hashing; retry on next scan');
          }
          if (cancelled()) return;
          if (!available(job)) throw StateError('Root unavailable');
          final old = await repo.fileByPath(job.path);
          final metadata =
              old?.metadata ??
              jsonEncode({
                'title': mediaPath.basenameWithoutExtension(job.path),
              });
          await _writeResults(
            repo,
            libraryId,
            [
              _JobResult.ok(
                job,
                identity: sha,
                metadataJson: (jsonDecode(metadata) as Map)
                    .cast<String, Object?>(),
                artwork: const [],
                hashes: const {},
              ),
            ],
            out,
            fileIdByPath: fileIdByPath,
            missingRows: missingRows,
            missingBySha: missingBySha,
          );
          out.discovered++;
          enrichment.add(job);
        } catch (error) {
          out.errors.add(ScanError(job.path, '$error'));
        }
        await Future<void>.delayed(Duration.zero);
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) discover()]);
    if (cancelled()) return out;

    stage(ScanState.extracting);
    final local = buildExtractor();
    next = 0;
    Future<void> enrich() async {
      while (!cancelled() && next < enrichment.length) {
        final job = enrichment[next++];
        if (!available(job)) {
          out.errors.add(ScanError(job.path, 'Root unavailable'));
          continue;
        }
        final results = await _workWith(
          local,
          _WorkOrder([job], buildExtractor, renderThumbnail, policy),
        );
        await budget.charge(ScanBudget.enrichCost(job.sizeBytes));
        if (cancelled()) return;
        final result = results.single;
        if (result.error != null) {
          out.errors.add(ScanError(job.path, result.error!));
          continue;
        }
        final stat = await mediaFileSystem.file(job.path).stat();
        if (!available(job) ||
            stat.size != job.sizeBytes ||
            stat.modified != job.modifiedAt) {
          out.errors.add(
            ScanError(
              job.path,
              'File changed or root unavailable during metadata extraction',
            ),
          );
          continue;
        }
        await _enrichResult(repo, libraryId, result, out);
        await Future<void>.delayed(Duration.zero);
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) enrich()]);

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
      final item = await repo.ensureItem(
        libraryId,
        fileId,
        tags: [Tag.ofFormat(formatTag(path))],
      );
      _notify({
        'type': 'media-item-added',
        'libraryId': libraryId,
        'itemId': item.itemId,
        'fileId': fileId,
        'path': path,
        'phase': 'finish',
      });
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

  /// Commits discovery results and metadata work atomically. Additions are
  /// announced only after their file, identity, item and search entry exist.
  Future<void> _writeResults(
    ScannerRepository repo,
    int libraryId,
    List<_JobResult> results,
    ScanProgress out, {
    required Map<String, int> fileIdByPath,
    required Map<int, FileRow> missingRows,
    required Map<String, FileRow> missingBySha,
  }) async {
    final events = <Map<String, Object?>>[];
    await db.transaction(() async {
      for (final result in results) {
        final job = result.job;
        if (result.error != null) {
          out.errors.add(ScanError(job.path, result.error!));
          continue;
        }
        var metadata = MediaMetadata.fromJson(job.kind, result.metadataJson!);
        final scannedAt = DateTime.now();

        FileRow? movedFrom;
        if (job.isNew) {
          final candidate = missingBySha.remove(result.identity);
          if (candidate != null &&
              mediaFileSystem.file(candidate.path).existsSync()) {
            // The bytes travelled but the original stayed — a copy, not a
            // move. Put the candidate back for a scan that misses it.
            missingBySha[result.identity!] = candidate;
          } else if (candidate != null) {
            movedFrom = candidate;
          }
        }

        final int fileId;
        if (movedFrom != null) {
          metadata = MediaMetadata.fromJson(
            job.kind,
            (jsonDecode(movedFrom.metadata) as Map).cast<String, Object?>(),
          );
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
          HashKind.sampledSha256: result.identity!,
        });
        final item = await repo.ensureItem(
          libraryId,
          fileId,
          tags: [Tag.ofFormat(formatTag(job.path))],
        );
        await ScanWork(db).discovered(libraryId, job.path, fileId);
        events.add({
          'type': item.wasNew ? 'media-item-added' : 'media-item-updated',
          'libraryId': libraryId,
          'itemId': item.itemId,
          'fileId': fileId,
          'path': job.path,
          'kind': job.kind.name,
          'metadata': metadata.toJson(),
          'phase': 'discover',
        });
      }
    });
    for (final event in events) {
      _notify(event);
    }
  }

  Future<void> _enrichResult(
    ScannerRepository repo,
    int libraryId,
    _JobResult result,
    ScanProgress out,
  ) async {
    final job = result.job;
    final events = <Map<String, Object?>>[];
    await db.transaction(() async {
      final before = await repo.fileByPath(job.path);
      if (before == null) throw StateError('Discovered file no longer exists');
      final metadata = MediaMetadata.fromJson(job.kind, result.metadataJson!);
      await repo.upsertFileByPath(
        path: job.path,
        sizeBytes: job.sizeBytes,
        modifiedAt: job.modifiedAt,
        metadata: metadata,
        scannedAt: DateTime.now(),
      );
      final oldArtwork =
          await (db.select(db.artworks)..where(
                (a) =>
                    a.fileId.equals(before.id) &
                    (a.role.equalsValue(ArtworkRole.embedded) |
                        a.role.equalsValue(ArtworkRole.thumbnail)),
              ))
              .get();
      await repo.replaceArtwork(
        before.id,
        ArtworkRole.embedded,
        result.artwork,
      );
      await repo.replaceArtwork(
        before.id,
        ArtworkRole.thumbnail,
        result.artwork,
      );
      final old = (jsonDecode(before.metadata) as Map).cast<String, Object?>();
      final updated = metadata.toJson();
      final fields = {
        for (final key in {...old.keys, ...updated.keys})
          if (jsonEncode(old[key]) != jsonEncode(updated[key]))
            key: updated[key],
      };
      final memberships = await (db.select(
        db.libraryItems,
      )..where((i) => i.fileId.equals(before.id))).get();
      for (final member in memberships) {
        await repo.ensureItem(
          member.libraryId,
          before.id,
          tags: [Tag.ofFormat(formatTag(job.path))],
        );
        if (fields.isNotEmpty) {
          events.add({
            'type': 'media-item-field-update',
            'libraryId': member.libraryId,
            'itemId': member.id,
            'fileId': before.id,
            'fields': fields,
            'phase': 'metadata',
          });
        }
      }
      await ScanWork(db).complete(libraryId, job.path);
      events.add({
        'type': 'media-item-enriched',
        'libraryId': libraryId,
        'fileId': before.id,
      });
      if (oldArtwork.isNotEmpty || result.artwork.isNotEmpty) {
        events.add({'type': 'media-artwork-updated', 'fileId': before.id});
      }
    });
    out.enriched++;
    out.artwork += result.artwork.length;
    for (final event in events) {
      _notify(event);
    }
  }

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
    final oldFolder =
        await (db.select(db.artworks)..where(
              (a) =>
                  a.fileId.equals(fileId) &
                  a.role.equalsValue(ArtworkRole.folder),
            ))
            .get();
    if (art.isEmpty || !policy.rendersThumbnails) {
      await repo.replaceArtwork(fileId, ArtworkRole.folder, const []);
      if (oldFolder.isNotEmpty) {
        _notify({'type': 'media-artwork-updated', 'fileId': fileId});
      }
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
    if (oldFolder.isNotEmpty || (kept && entries.isNotEmpty)) {
      _notify({'type': 'media-artwork-updated', 'fileId': fileId});
    }
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
    _notify({'type': 'media-artwork-updated', 'fileId': fileId});
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
    this.identity,
    required Map<String, Object?> this.metadataJson,
    required this.artwork,
    required this.hashes,
  }) : error = null;

  const _JobResult.failed(this.job, String this.error)
    : identity = null,
      metadataJson = null,
      artwork = const [],
      hashes = const {};

  final _ScanJob job;
  final String? error;

  /// The sampled identity hash, from the discover stage.
  final String? identity;
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
