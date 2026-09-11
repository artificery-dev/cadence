import 'dart:async';
import 'dart:convert';
import 'package:cadence_media/cadence_media.dart';
import 'package:cadence_client/cadence_client.dart';

/// Durable FIFO of logical scans. Attempts reconcile the library again; committed
/// batches are retained. Only explicit cancellation makes shutdown work terminal.
///
/// A job's `state` is the wire's scan state: always `ScanState.<x>.name`,
/// never a literal, so what a client parses with `ScanState.values.byName`
/// is by construction a member — the queue's own `queued` and
/// `interrupted` included.
class PersistentScanQueue {
  PersistentScanQueue(
    this.db,
    this.coordinator,
    this.fileSystem, {
    required this.epoch,
    required this.policy,
    required this.onChange,
  });
  final MediaDatabase db;
  final ScanCoordinator coordinator;
  final FileSystem fileSystem;
  final String epoch;
  final ScanPolicy policy;
  final void Function() onChange;
  final _jobs = <String, Map<String, Object?>>{};
  int _order = 0;
  String? _active;
  bool _enabled = false, _closing = false;
  Object? _failure;
  Future<void> _serial = Future.value();
  Future<void>? _runner;

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _serial = _serial.then((_) async {
      try {
        result.complete(await action());
      } catch (e, st) {
        result.completeError(e, st);
      }
    });
    return result.future;
  }

  Future<void> _save(Map<String, Object?> job) => db.customStatement(
    'INSERT OR REPLACE INTO daemon_jobs(id,body) VALUES (?,?)',
    [job['jobId'], jsonEncode(job)],
  );
  static const _progressKeys = [
    'startedAt',
    'finishedAt',
    'elapsedMs',
    'seen',
    'phase',
    'discovered',
    'enriched',
    'changed',
    'added',
    'updated',
    'moved',
    'missing',
    'sidecars',
    'artwork',
    'skipped',
    'errorCount',
    'errors',
    'error',
    'effectivePolicy',
  ];
  static Map<String, Object?> _copy(Map<String, Object?> value) =>
      (jsonDecode(jsonEncode(value)) as Map).cast<String, Object?>();
  void _recordAttempt(Map<String, Object?> job, Map<String, Object?> outcome) {
    final history = List<Object?>.of(job['attempts'] as List? ?? []);
    history.add({
      'attempt': job['attemptCount'] ?? 1,
      for (final key in _progressKeys)
        if (job.containsKey(key)) key: job[key],
      ...outcome,
    });
    job['attempts'] = history;
  }

  void _requeue(Map<String, Object?> job) {
    for (final key in _progressKeys) {
      job.remove(key);
    }
    job['state'] = ScanState.queued.name;
  }

  Future<void> restore() async {
    await db.customStatement(
      'CREATE TABLE IF NOT EXISTS daemon_jobs (id TEXT PRIMARY KEY, body TEXT NOT NULL)',
    );
    final rows = await db
        .customSelect('SELECT body FROM daemon_jobs ORDER BY rowid')
        .get();
    final jobs = rows
        .map(
          (row) => (jsonDecode(row.read<String>('body')) as Map)
              .cast<String, Object?>(),
        )
        .toList();
    for (final job in jobs) {
      final order = job['queueOrder'] as int? ?? 0;
      if (order > _order) _order = order;
    }
    for (final job in jobs) {
      if ((job['journalVersion'] as int? ?? 1) > 2)
        throw StateError('Unsupported job journal version');
      job['journalVersion'] = 2;
      job['queueOrder'] ??= ++_order;
      job['attemptCount'] ??= job['state'] == ScanState.queued.name ? 0 : 1;
      job['attempts'] ??= <Object?>[];
      // Also migrate interrupted records produced by the initial no-resume host.
      if (job['finishedAt'] == null ||
          job['state'] == ScanState.interrupted.name) {
        if (job['state'] != ScanState.queued.name) {
          _recordAttempt(job, {
            'state': job['cancelRequested'] == true
                ? ScanState.cancelled.name
                : ScanState.interrupted.name,
            'finishedAt':
                job['finishedAt'] ?? DateTime.now().toUtc().toIso8601String(),
            'reason': 'process_restart',
            'progressLost': true,
          });
        }
        if (job['cancelRequested'] == true) {
          job['state'] = ScanState.cancelled.name;
          job['finishedAt'] = DateTime.now().toUtc().toIso8601String();
        } else {
          _requeue(job);
        }
      }
      await _save(job);
      _jobs[job['jobId'] as String] = job;
    }
  }

  bool get isPaused => !_enabled && _active == null;
  bool get hasPending => _jobs.values.any((j) => j['finishedAt'] == null);
  List<Map<String, Object?>> get snapshots {
    final ordered = _jobs.values.toList()
      ..sort(
        (a, b) => (a['queueOrder'] as int).compareTo(b['queueOrder'] as int),
      );
    return ordered.map((j) => snapshot(j['jobId'] as String)).toList();
  }

  Map<String, Object?> snapshot(String id) {
    final job = _jobs[id];
    if (job == null) throw MediaError('not_found', 'Unknown job', 404);
    final result = _copy(job);
    if (id == _active && job['finishedAt'] == null) {
      final status = coordinator.statusOf(job['libraryId'] as int);
      // Never publish completion before its journal write has succeeded.
      if (status.state.running) result.addAll(status.toJson());
    }
    return result;
  }

  Map<String, Object?>? latest(int library) {
    final jobs = snapshots.where((j) => j['libraryId'] == library);
    return jobs.isEmpty ? null : jobs.last;
  }

  Future<Map<String, Object?>> submit(int library) => _exclusive(() async {
    if (_closing || _failure != null)
      throw MediaError('queue_unavailable', 'Scan queue unavailable', 503);
    if (_jobs.values.any(
      (j) => j['libraryId'] == library && j['finishedAt'] == null,
    )) {
      throw MediaError(
        'scan_conflict',
        'This library already has an unfinished job',
        409,
      );
    }
    final exists = await (db.select(
      db.libraries,
    )..where((l) => l.id.equals(library))).getSingleOrNull();
    if (exists == null) throw MediaError('not_found', 'Unknown library', 404);
    final order = ++_order;
    final job = <String, Object?>{
      'journalVersion': 2,
      'jobId': '$epoch-$order',
      'libraryId': library,
      'queueOrder': order,
      'state': ScanState.queued.name,
      'attemptCount': 0,
      'attempts': <Object?>[],
      'submittedAt': DateTime.now().toUtc().toIso8601String(),
    };
    await _save(job);
    _jobs[job['jobId'] as String] = job;
    onChange();
    _kick();
    return _copy(job);
  });

  Future<Map<String, Object?>> cancel(String id) => _exclusive(() async {
    final existing = _jobs[id];
    if (existing == null) throw MediaError('not_found', 'Unknown job', 404);
    if (existing['finishedAt'] != null) return _copy(existing);
    final job = _copy(existing)..['cancelRequested'] = true;
    if (_active != id) {
      job['state'] = ScanState.cancelled.name;
      job['finishedAt'] = DateTime.now().toUtc().toIso8601String();
    }
    // Persist intent before signalling the scanner or acknowledging cancellation.
    await _save(job);
    _jobs[id] = job;
    if (_active == id) coordinator.cancel(job['libraryId'] as int);
    onChange();
    return snapshot(id);
  });

  void start() {
    _enabled = true;
    _kick();
  }

  void _kick() {
    if (!_enabled ||
        _closing ||
        _failure != null ||
        _runner != null ||
        !hasPending)
      return;
    _runner = withMediaFileSystem(fileSystem, _drain)
        .catchError((Object error) {
          // A journal failure halts the queue. Never acknowledge undurable success.
          _failure = error;
          onChange();
        })
        .whenComplete(() {
          _runner = null;
          _kick();
        });
  }

  Future<void> _drain() async {
    while (!_closing && _enabled) {
      final id = await _exclusive<String?>(() async {
        if (_closing || !_enabled) return null;
        final queued =
            _jobs.values
                .where((j) => j['state'] == ScanState.queued.name)
                .toList()
              ..sort(
                (a, b) =>
                    (a['queueOrder'] as int).compareTo(b['queueOrder'] as int),
              );
        if (queued.isEmpty) return null;
        final job = _copy(queued.first);
        final id = job['jobId'] as String;
        job['state'] = ScanState.walking.name;
        job['attemptCount'] = (job['attemptCount'] as int) + 1;
        job['startedAt'] = DateTime.now().toUtc().toIso8601String();
        job['effectivePolicy'] = {
          'identity': 'full',
          'artwork': policy.artwork.name,
          'thumbnailSide': policy.thumbnailSide,
        };
        await _save(job);
        _jobs[id] = job;
        _active = id;
        try {
          await coordinator.start(job['libraryId'] as int);
        } catch (error) {
          final failed = _copy(job)
            ..addAll({
              'state': ScanState.failed.name,
              'finishedAt': DateTime.now().toUtc().toIso8601String(),
              'error': {'code': 'scan_failed', 'message': '$error'},
            });
          _recordAttempt(failed, {'state': ScanState.failed.name});
          await _save(failed);
          _jobs[id] = failed;
          _active = null;
        }
        onChange();
        return id;
      });
      if (id == null) return;
      if (_active != id) continue;
      final status = await coordinator.wait(_jobs[id]!['libraryId'] as int);
      await _exclusive(() async {
        final job = _copy(_jobs[id]!)..addAll(status.toJson());
        final suspend =
            (_closing || !_enabled) &&
            job['cancelRequested'] != true &&
            status.state == ScanState.cancelled;
        _recordAttempt(job, {
          'state': suspend ? ScanState.interrupted.name : status.state.name,
          if (suspend) 'reason': _closing ? 'host_shutdown' : 'roots_quiescing',
        });
        if (suspend) _requeue(job);
        await _save(job);
        _jobs[id] = job;
        _active = null;
        onChange();
      });
    }
  }

  Map<String, Object?> get status => {
    'enabled': _enabled,
    'runningJobId': _active,
    if (_failure != null)
      'error': {
        'code': 'journal_failure',
        'message':
            'Scan queue halted; restore database writability and restart',
      },
  };
  Future<void> pause() async {
    _enabled = false;
    await _serial;
    final active = _active;
    if (active != null) coordinator.cancel(_jobs[active]!['libraryId'] as int);
    await _runner;
  }

  Future<void> close() async {
    _closing = true;
    await _serial;
    final active = _active;
    if (active != null) coordinator.cancel(_jobs[active]!['libraryId'] as int);
    await _runner;
  }
}
