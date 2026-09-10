import 'dart:async';

import '../database/database.dart';
import 'scanner.dart';

/// Where a library's scan stands. The first three are a scan in motion;
/// the last four are how it ended — or, for [idle], that it never began.
enum ScanState {
  /// No scan has run since the service came up.
  idle,

  /// Walking roots and diffing against the database.
  walking,

  /// Full hashing and minimal, immediately browseable library insertion.
  discovering,

  /// Metadata enrichment of already discoverable files.
  extracting,

  /// Missing marks, sidecars, folder art — the epilogue.
  finishing,

  /// Finished whole.
  done,

  /// Threw rather than finished; the errors list holds the why.
  failed,

  /// Stopped on request. Whatever landed before the stop stays landed.
  cancelled;

  /// Whether a scan is actually in motion.
  bool get running =>
      this == walking ||
      this == discovering ||
      this == extracting ||
      this == finishing;
}

/// One look at a library's scan: the state, the counters, the clock. The
/// coordinator hands these out during a scan and keeps the last one after,
/// so a status poll always has something true to say.
class ScanSnapshot {
  const ScanSnapshot({
    required this.state,
    this.progress,
    this.startedAt,
    this.finishedAt,
  });

  /// What a never-scanned library reports.
  static const idle = ScanSnapshot(state: ScanState.idle);

  final ScanState state;

  /// Live during a scan, final after — null only for [idle].
  final ScanProgress? progress;

  final DateTime? startedAt;
  final DateTime? finishedAt;

  /// How long the scan has been at it — or took, once finished.
  Duration get elapsed {
    final startedAt = this.startedAt;
    if (startedAt == null) return Duration.zero;
    return (finishedAt ?? DateTime.now()).difference(startedAt);
  }

  /// The status body the service serves: state, counters, the first fifty
  /// errors, and the clock.
  Map<String, Object?> toJson() {
    final progress = this.progress;
    return {
      'state': state.name,
      if (state != ScanState.idle)
        'phase': switch (state) {
          ScanState.walking => 'scan',
          ScanState.discovering => 'discover',
          ScanState.extracting => 'metadata',
          ScanState.finishing => 'finish',
          _ => state.name,
        },
      if (progress != null) ...{
        'seen': progress.seen,
        'changed': progress.changed,
        'discovered': progress.discovered,
        'enriched': progress.enriched,
        'added': progress.added,
        'updated': progress.updated,
        'moved': progress.moved,
        'missing': progress.missing,
        'sidecars': progress.sidecars,
        'artwork': progress.artwork,
        'skipped': progress.skipped,
        'errorCount': progress.errorCount,
        'errors': [
          for (final error in progress.errors.take(50)) error.toJson(),
        ],
      },
      if (startedAt != null) 'startedAt': startedAt!.toIso8601String(),
      if (finishedAt != null) 'finishedAt': finishedAt!.toIso8601String(),
      if (startedAt != null) 'elapsedMs': elapsed.inMilliseconds,
    };
  }
}

/// The desk every scan is booked through: one active scan per library,
/// a queue for scanning everything, and the last outcome kept around for
/// whoever asks after the fact.
class ScanCoordinator {
  ScanCoordinator(this.db, {LibraryScanner? scanner, this.onFinished})
    : scanner = scanner ?? LibraryScanner(db);

  final MediaDatabase db;
  final LibraryScanner scanner;

  /// Told when a scan finishes whole — not cancelled, not failed — with
  /// the library it scanned: the artwork queue's cue to sweep.
  final void Function(int libraryId)? onFinished;

  bool _closed = false;

  /// Asks every running scan to stop and waits for it to. Scans already
  /// finished are not waited on: their futures completed on the clock
  /// they ran under, which a caller closing from elsewhere — a test's
  /// teardown, outside the fake clock the test ran on — may never see.
  Future<void> close() async {
    _closed = true;
    final running = <Future<void>>[];
    for (final scan in _scans.values) {
      scan.cancelRequested = true;
      if (scan.finishedAt == null) running.add(scan.done);
    }
    await Future.wait(running);
  }

  final _scans = <int, _ActiveScan>{};
  bool _draining = false;

  /// Starts a full scan of [libraryId] and returns at once with the first
  /// snapshot. Throws [StateError] when the library is already scanning —
  /// the service reads that as a 409 — and [ArgumentError] when there is
  /// no such library — a 404.
  Future<ScanSnapshot> start(int libraryId) async {
    if (_closed) throw StateError("Coordinator closed");
    await _requireLibrary(libraryId);
    return _launch(libraryId);
  }

  /// The watcher's door: a narrow scan of [dirs] only. Answers false —
  /// rather than throwing — when a scan is already running, so the caller
  /// can simply try again later. A library that no longer exists answers
  /// true: there is nothing to scan and nothing worth retrying, so the
  /// caller should let the debt go.
  Future<bool> startIncremental(
    int libraryId, {
    required Set<String> dirs,
  }) async {
    if (dirs.isEmpty) return true;
    final current = _scans[libraryId];
    if (current != null && current.state.running) return false;
    try {
      await _requireLibrary(libraryId);
      _launch(libraryId, onlyDirs: dirs);
    } on ArgumentError {
      return true;
    } on StateError {
      return false;
    }
    return true;
  }

  /// Where the library's scan stands — the running one, the last one, or
  /// [ScanSnapshot.idle] if none ever ran.
  ScanSnapshot statusOf(int libraryId) => _snapshot(_scans[libraryId]);

  /// Asks a running scan to stop. Idempotent, and honest: true only when
  /// there was something to stop. Workers finish the batch they hold.
  bool cancel(int libraryId) {
    final scan = _scans[libraryId];
    if (scan == null || !scan.state.running) return false;
    scan.cancelRequested = true;
    return true;
  }

  /// Completes when the library has no scan in motion, answering with the
  /// snapshot it settled on.
  Future<ScanSnapshot> wait(int libraryId) async {
    final scan = _scans[libraryId];
    if (scan != null) await scan.done;
    return statusOf(libraryId);
  }

  /// Scans every library, one after another, and returns the ids queued —
  /// the drain runs behind the caller's back. A second call while the
  /// queue is draining changes nothing.
  Future<List<int>> scanAll() async {
    final libraries = await db.select(db.libraries).get();
    final ids = [for (final library in libraries) library.id];
    if (_draining) return ids;
    _draining = true;
    unawaited(_drain(ids));
    return ids;
  }

  Future<void> _drain(List<int> ids) async {
    try {
      for (final id in ids) {
        if (_closed) break;
        final current = _scans[id];
        if (current != null && current.state.running) {
          await current.done;
          continue;
        }
        try {
          await start(id);
        } on Object {
          // Deleted mid-queue, or raced into a scan — either way, move on.
          continue;
        }
        await wait(id);
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _requireLibrary(int libraryId) async {
    final row = await (db.select(
      db.libraries,
    )..where((l) => l.id.equals(libraryId))).getSingleOrNull();
    if (row == null) {
      throw ArgumentError.value(libraryId, 'libraryId', 'not a library');
    }
  }

  /// The synchronous heart of every start: check, book, launch. No awaits
  /// here, so two starts can never both slip past the running check.
  ScanSnapshot _launch(int libraryId, {Set<String>? onlyDirs}) {
    final current = _scans[libraryId];
    if (current != null && current.state.running) {
      throw StateError('library $libraryId is already scanning');
    }
    final scan = _ActiveScan();
    _scans[libraryId] = scan;
    scan.done = _run(libraryId, scan, onlyDirs);
    return _snapshot(scan);
  }

  Future<void> _run(
    int libraryId,
    _ActiveScan scan,
    Set<String>? onlyDirs,
  ) async {
    try {
      await scanner.scan(
        libraryId,
        progress: scan.progress,
        shouldCancel: () => scan.cancelRequested,
        onStage: (state) => scan.state = state,
        onlyDirs: onlyDirs,
      );
      scan.state = scan.cancelRequested ? ScanState.cancelled : ScanState.done;
    } on Object catch (error) {
      scan.progress.errors.add(ScanError('', '$error'));
      scan.state = ScanState.failed;
    } finally {
      scan.finishedAt = DateTime.now();
    }
    if (scan.state == ScanState.done) onFinished?.call(libraryId);
  }

  ScanSnapshot _snapshot(_ActiveScan? scan) => scan == null
      ? ScanSnapshot.idle
      : ScanSnapshot(
          state: scan.state,
          progress: scan.progress,
          startedAt: scan.startedAt,
          finishedAt: scan.finishedAt,
        );
}

/// A scan the coordinator is (or was) responsible for.
class _ActiveScan {
  _ActiveScan() : startedAt = DateTime.now();

  ScanState state = ScanState.walking;
  final ScanProgress progress = ScanProgress();
  final DateTime startedAt;
  DateTime? finishedAt;
  bool cancelRequested = false;
  late final Future<void> done;
}
