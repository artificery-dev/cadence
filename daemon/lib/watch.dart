import 'package:cadence_media/src/filesystem.dart' show mediaFileSystem;
import 'package:file/local.dart';
import 'package:cadence_media/src/watch_adapter.dart';
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

import 'package:cadence_media/src/database/database.dart';
import 'package:cadence_media/src/repositories/scanner_repository.dart';
import 'package:cadence_media/src/scan/scan_jobs.dart';

/// The between-scans lookout: one [DirectoryWatcher] per library root,
/// events gathered until two quiet seconds pass, then an incremental scan
/// of just the directories that stirred.
///
/// Watching is best-effort by design. A watcher that fails — inotify
/// limits, a root on flaky media — becomes a log line and stops, nothing
/// more; scans stay manual until someone asks again. The service turns
/// the whole thing on and off with the `scanner.watchFolders` setting.
class LocalLibraryWatchService implements LibraryWatchService {
  LocalLibraryWatchService(
    this.db,
    this.coordinator, {
    this.submit,
    this.debounce = const Duration(seconds: 2),
    void Function(String message)? log,
  }) : _log = log ?? _quietly;

  final Future<bool> Function(int, Set<String>)? submit;
  final MediaDatabase db;
  final ScanCoordinator coordinator;

  /// How long a library must stay quiet before its changes are scanned.
  final Duration debounce;

  final void Function(String message) _log;

  final _subscriptions = <StreamSubscription<WatchEvent>>[];
  final _pending = <int, Set<String>>{};
  final _timers = <int, Timer>{};
  bool _running = false;

  bool get running => _running;

  /// Reads every library's roots and posts a watcher on each. Roots that
  /// don't exist are logged and skipped; calling while already running
  /// changes nothing.
  Future<void> start() async {
    if (mediaFileSystem is! LocalFileSystem)
      throw UnsupportedError('Local watcher requires a local filesystem');
    if (_running) return;
    _running = true;
    final repo = ScannerRepository(db);
    final libraries = await db.select(db.libraries).get();
    for (final library in libraries) {
      for (final root in await repo.rootsOf(library.id)) {
        _watchRoot(library.id, root.path);
      }
    }
  }

  /// Takes the watchers down and forgets whatever was pending.
  Future<void> stop() async {
    _running = false;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _pending.clear();
    final subscriptions = List.of(_subscriptions);
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }

  /// Re-reads the roots and rewires — the move after a root is added or
  /// removed. Does nothing unless already running.
  Future<void> refresh() async {
    if (!_running) return;
    await stop();
    await start();
  }

  void _watchRoot(int libraryId, String rootPath) {
    if (!Directory(rootPath).existsSync()) {
      _log('not watching $rootPath: no such directory');
      return;
    }
    final watcher = DirectoryWatcher(rootPath);
    late final StreamSubscription<WatchEvent> subscription;
    subscription = watcher.events.listen(
      (event) => _onEvent(libraryId, rootPath, event),
      onError: (Object error) {
        // Degrade, don't crash: this root goes unwatched from here on.
        _log('watcher for $rootPath failed: $error');
        _subscriptions.remove(subscription);
        subscription.cancel();
      },
    );
    _subscriptions.add(subscription);
  }

  void _onEvent(int libraryId, String rootPath, WatchEvent event) {
    if (!_running) return;
    if (p.basename(event.path).startsWith('.')) return;
    final dir = p.dirname(event.path);
    if (!p.equals(dir, rootPath)) {
      final segments = p.split(p.relative(dir, from: rootPath));
      if (segments.any((segment) => segment.startsWith('.'))) return;
    }
    (_pending[libraryId] ??= {}).add(dir);
    _arm(libraryId);
  }

  void _arm(int libraryId) {
    _timers[libraryId]?.cancel();
    _timers[libraryId] = Timer(debounce, () => _fire(libraryId));
  }

  Future<void> _fire(int libraryId) async {
    if (!_running) return;
    final dirs = _pending.remove(libraryId);
    if (dirs == null || dirs.isEmpty) return;
    final accepted =
        await (submit?.call(libraryId, dirs) ??
            coordinator.startIncremental(libraryId, dirs: dirs));
    if (!accepted && _running) {
      // A scan is already on the floor — keep the debt and try after
      // another quiet spell.
      (_pending[libraryId] ??= {}).addAll(dirs);
      _arm(libraryId);
    }
  }

  static void _quietly(String _) {}
}
