import 'endpoint.dart';
import 'scan_queue.dart';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:cadence_media/cadence_media.dart';
import 'package:cadence_client/cadence_client.dart';

/// Embeddable owner. The application injects the database connection, filesystem,
/// extraction stack and optional watcher; standalone uses this exact host.
class MediaHost implements MediaEndpoint {
  MediaHost._(
    this.db,
    this.fileSystem,
    this.coordinator,
    this.service,
    this.availability,
    this.cacheDirectory,
    this.cacheFileSystem,
    this.policy,
    this.watchAvailable,
    this.nativeAvailable,
  );
  static final _owners = Expando<bool>();
  final String? cacheDirectory;
  final FileSystem cacheFileSystem;
  final ScanPolicy policy;
  bool _requireRootAvailability = false;
  bool Function(String path)? rootAccessAvailable;
  final bool watchAvailable, nativeAvailable;
  final MediaDatabase db;
  final FileSystem fileSystem;
  final ScanCoordinator coordinator;
  final MediaService service;
  final Map<String, bool> availability;
  late final PersistentScanQueue _queue;
  final _events = StreamController<Map<String, Object?>>.broadcast();
  final epoch = DateTime.now().microsecondsSinceEpoch.toString();
  int _sequence = 0;
  int _cacheSequence = 0;
  bool _closed = false;
  Timer? _timer;
  Future<void> _serial = Future.value();
  Map<String, Object?> get activity => {
    'runningJobs': _queue.snapshots
        .where((j) => j['finishedAt'] == null && j['state'] != 'queued')
        .length,
    'queuedJobs': _queue.snapshots.where((j) => j['state'] == 'queued').length,
    'artwork': service.artworkStatus,
  };
  void resumeJobs() => _queue.start();

  static Future<MediaHost> open({
    required MediaDatabase database,
    required FileSystem fileSystem,
    String? cacheDirectory,
    FileSystem? cacheFileSystem,
    bool nativeAvailable = false,
    bool autoStartJobs = true,
    bool requireRootAvailability = false,
    ScanPolicy policy = const ScanPolicy(artwork: ArtworkPolicy.deferred),
    ExtractorBuilder buildExtractor = defaultMediaExtractor,
    Future<String> Function(String path) hashFile = sha256OfFile,
    LibraryWatchService Function(ScanCoordinator)? watch,
  }) async {
    if (_owners[database] == true)
      throw StateError('Database already owned by a host');
    _owners[database] = true;
    return withMediaFileSystem(fileSystem, () async {
      final availability = <String, bool>{};
      MediaHost? activeHost;
      void changed(Map<String, Object?> event) =>
          activeHost?._emit(event['type'] as String, event);

      final artwork = ArtworkQueue(
        database,
        buildExtractor: buildExtractor,
        thumbnailSide: policy.thumbnailSide,
        fileAvailable: (path) =>
            activeHost?.fileAvailable(path) ?? !requireRootAvailability,
        onArtworkChanged: (fileId) =>
            changed({'type': 'media-artwork-updated', 'fileId': fileId}),
      );
      final coordinator = ScanCoordinator(
        database,
        scanner: LibraryScanner(
          database,
          buildExtractor: buildExtractor,
          hashFile: hashFile,
          policy: policy,
          onChange: changed,
          rootAvailable: (path) =>
              (availability[path] ?? !requireRootAvailability) &&
              (activeHost?.rootAccessAvailable?.call(path) ?? true),
        ),
        onFinished: (id) => unawaited(artwork.sweep(id)),
      );
      final service = MediaService(
        database,
        coordinator: coordinator,
        artwork: artwork,
        watch: watch?.call(coordinator),
      );
      final host = MediaHost._(
        database,
        fileSystem,
        coordinator,
        service,
        availability,
        cacheDirectory,
        cacheFileSystem ?? fileSystem,
        policy,
        watch != null,
        nativeAvailable,
      );
      activeHost = host;
      host._requireRootAvailability = requireRootAvailability;
      await database.customStatement(
        'CREATE TABLE IF NOT EXISTS daemon_jobs (id TEXT PRIMARY KEY, body TEXT NOT NULL)',
      );
      await database.customStatement(
        'CREATE TABLE IF NOT EXISTS daemon_roots (path TEXT PRIMARY KEY, available INTEGER NOT NULL)',
      );
      for (final row
          in await database.customSelect('SELECT * FROM daemon_roots').get()) {
        availability[row.read<String>('path')] =
            row.read<int>('available') != 0;
      }
      if (requireRootAvailability) {
        for (final root in await database.select(database.libraryRoots).get()) {
          availability[root.path] = false;
        }
      }
      host._queue = PersistentScanQueue(
        database,
        coordinator,
        fileSystem,
        epoch: host.epoch,
        policy: policy,
        onChange: () => host._emit('change'),
      );
      await host._queue.restore();
      if (!requireRootAvailability) await service.syncWatchers();
      host._timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!host._closed && (host._queue.hasPending || artwork.running))
          host._emit('progress');
      });
      if (autoStartJobs) host.resumeJobs();
      return host;
    });
  }

  Future<void> pauseWork() async {
    await Future.wait([_queue.pause(), service.pauseBackground()]);
  }

  bool fileAvailable(String path) {
    if (rootAccessAvailable?.call(path) == false) return false;
    final matching = availability.entries.where(
      (e) => e.key == path || fileSystem.path.isWithin(e.key, path),
    );
    if (matching.isEmpty) return !_requireRootAvailability;
    // An unavailable parent beats an available child on a removed device.
    return matching.every((e) => e.value);
  }

  Future<void> setRootAvailability(Map<int, bool> values) async {
    final roots = await db.select(db.libraryRoots).get();
    if (values.length != roots.length ||
        roots.any((r) => !values.containsKey(r.id)))
      throw MediaError(
        'invalid_request',
        'Supply every configured root exactly once',
        400,
      );
    final replacement = <String, bool>{};
    for (final root in roots) {
      final available = values[root.id]!;
      if (replacement.containsKey(root.path) &&
          replacement[root.path] != available)
        throw MediaError(
          'invalid_request',
          'Shared root availability must agree',
          400,
        );
      replacement[root.path] = available;
    }
    availability
      ..clear()
      ..addAll(replacement);
    await db.transaction(() async {
      await db.customStatement('DELETE FROM daemon_roots');
      for (final entry in replacement.entries) {
        await db.customStatement('INSERT INTO daemon_roots VALUES (?,?)', [
          entry.key,
          entry.value ? 1 : 0,
        ]);
      }
    });
  }

  void _emit(String type, [Map<String, Object?> data = const {}]) {
    if (!_events.isClosed)
      _events.add({
        ...data,
        'type': type,
        'epoch': epoch,
        'revision': ++_sequence,
      });
  }

  /// A client owns its connection, never this host's lifetime.
  MediaTransport connect() => _EmbeddedConnection(this);
  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) {
    final completion = Completer<Map<String, Object?>>();
    _serial = _serial.then((_) async {
      try {
        if (_closed) throw MediaError('closed', 'Host closing', 503);
        completion.complete(
          await withMediaFileSystem(
            fileSystem,
            () => _route(method, path, body),
          ),
        );
      } catch (e, st) {
        final error = e is MediaError
            ? e
            : MediaError(
                e is ArgumentError || e is TypeError || e is FormatException
                    ? 'invalid_request'
                    : 'internal_error',
                '$e',
                e is ArgumentError || e is TypeError || e is FormatException
                    ? 400
                    : 500,
              );
        completion.completeError(error, st);
      }
    });
    return completion.future;
  }

  Future<Map<String, Object?>> _route(
    String method,
    String path,
    Map<String, Object?>? body,
  ) async {
    if (method == 'get' && path == '/capabilities')
      return {
        'apiVersions': [1],
        'transport': ['embedded', 'http-unix'],
        'jobs': true,
        'watch': watchAvailable,
        'nativeExtraction': nativeAvailable,
        'policy': {
          'identity': 'full',
          'artwork': policy.artwork.name,
          'thumbnailSide': policy.thumbnailSide,
        },
        'restart': 'automatic-incremental-retry',
        'scanQueue': 'durable-fifo',
        'scanPhases': ['scan', 'discover', 'metadata', 'finish'],
        'itemEvents': [
          'media-item-added',
          'media-item-updated',
          'media-item-field-update',
          'media-item-enriched',
          'media-artwork-updated',
        ],
        'eventRecovery': 'snapshot-and-query',
        'artwork': 'binary',
        'notifications': 'snapshot-invalidation',
      };
    if (method == 'get' && path == '/snapshot') {
      final libraries = await service.handle(
        const ServiceRequest(
          id: 0,
          method: ServiceMethod.get,
          path: '/libraries',
        ),
      );
      return {
        'epoch': epoch,
        'revision': _sequence,
        'jobs': _queue.snapshots,
        'queue': _queue.status,
        'pendingWork': [
          for (final row
              in await db
                  .customSelect(
                    'SELECT library_id,path,stage,file_id FROM scan_work ORDER BY library_id,path',
                  )
                  .get())
            {
              'libraryId': row.read<int>('library_id'),
              'path': row.read<String>('path'),
              'stage': row.read<String>('stage'),
              'fileId': row.readNullable<int>('file_id'),
            },
        ],
        ...libraries.body,
        'roots': [
          for (final root in await db.select(db.libraryRoots).get())
            {
              'id': root.id,
              'libraryId': root.libraryId,
              'path': root.path,
              'available': availability[root.path] != false,
            },
        ],
      };
    }
    final parts = Uri.parse(path).pathSegments;
    if (method == 'put' &&
        path == '/settings/scanner.watchFolders' &&
        !watchAvailable) {
      throw MediaError(
        'unsupported_capability',
        'No watcher adapter installed',
        501,
      );
    }
    if (parts.length == 2 && parts.first == 'jobs') {
      if (method == 'get') return _queue.snapshot(parts[1]);
      if (method == 'delete') return _queue.cancel(parts[1]);
      throw MediaError('method_not_allowed', 'Use get or delete', 405);
    }

    if (method == 'post' &&
        parts.length == 3 &&
        parts[0] == 'libraries' &&
        parts[2] == 'roots' &&
        body?['available'] == false) {
      final path = fileSystem.path.normalize(body!['path'] as String);
      if (!fileSystem.path.isAbsolute(path))
        throw MediaError('invalid_request', 'Root must be absolute', 400);
      final type = fileSystem.typeSync(path, followLinks: false);
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.notFound) {
        throw MediaError('invalid_request', 'Root must be a directory', 400);
      }
      if (_queue.hasPending && !_queue.isPaused)
        throw MediaError('scan_conflict', 'Wait for current scan', 409);
      final id = await ScannerRepository(db).addRoot(int.parse(parts[1]), path);
      availability[path] = false;
      await db.customStatement(
        'INSERT OR REPLACE INTO daemon_roots(path, available) VALUES (?,0)',
        [path],
      );
      _emit('change');
      return {'id': id};
    }
    if (parts.length == 4 &&
        parts[0] == 'libraries' &&
        parts[2] == 'roots' &&
        method == 'put') {
      if (body?['available'] is! bool)
        throw MediaError('invalid_request', 'available must be boolean', 400);
      final roots = await ScannerRepository(db).rootsOf(int.parse(parts[1]));
      final root = roots.where((r) => r.id == int.parse(parts[3])).firstOrNull;
      if (root == null) throw MediaError('not_found', 'Unknown root', 404);
      availability[root.path] = body!['available'] as bool;
      await db.customStatement(
        'INSERT OR REPLACE INTO daemon_roots(path, available) VALUES (?,?)',
        [root.path, availability[root.path]! ? 1 : 0],
      );
      return {'available': availability[root.path]};
    }
    if (parts.length == 3 &&
        parts[0] == 'libraries' &&
        parts[2] == 'scan' &&
        method == 'post') {
      return _queue.submit(int.parse(parts[1]));
    }
    if (parts.length == 3 && parts[0] == 'libraries' && parts[2] == 'scan') {
      final library = int.parse(parts[1]);
      final latest = _queue.latest(library);
      if (method == 'get')
        return latest ?? coordinator.statusOf(library).toJson();
      if (method == 'delete') {
        if (latest == null || latest['finishedAt'] != null)
          return {'cancelled': false};
        await _queue.cancel(latest['jobId'] as String);
        return {'cancelled': true};
      }
    }
    if (method != 'get' &&
        _queue.hasPending &&
        !(_queue.isPaused && parts.length >= 3 && parts[2] == 'roots') &&
        !(parts.length == 3 && parts[2] == 'scan' && method == 'delete') &&
        parts.firstOrNull != 'artwork') {
      throw MediaError(
        'scan_conflict',
        'Wait for the active scan before changing library configuration',
        409,
      );
    }
    if (parts.length == 3 && parts[0] == 'items' && parts[2] == 'tags') {
      final repo = LibraryRepository(db);
      final item = int.parse(parts[1]);
      if (method == 'get')
        return {
          'tags': [for (final tag in await repo.tagsOf(item)) tag.canonical],
        };
      final tag = Tag.parse(body!['tag'] as String);
      if (method == 'post') {
        await repo.addTag(item, tag);
      } else if (method == 'delete') {
        await repo.removeTag(item, tag);
      } else {
        throw MediaError('method_not_allowed', 'Use get, post or delete', 405);
      }
      _emit('change');
      return {};
    }
    if (parts.length == 2 && parts[0] == 'collections') {
      final repo = CollectionsRepository(db);
      if (method == 'put') {
        await repo.rename(int.parse(parts[1]), body!['name'] as String);
        return {};
      }
      if (method == 'delete') {
        await repo.delete(int.parse(parts[1]));
        return {};
      }
    }
    if (parts.length == 3 && parts[0] == 'files' && parts[2] == 'artwork') {
      throw MediaError(
        'binary_required',
        'Use the transport artwork method',
        400,
      );
    }
    // No arbitrary path insertion or global unjournaled scan routes on v1.
    if (path == '/scan' || (method == 'post' && parts.lastOrNull == 'items')) {
      throw MediaError(
        'unsupported',
        'Use configured roots and scan jobs',
        405,
      );
    }
    final response = await service.handle(
      ServiceRequest(
        id: 0,
        method: ServiceMethod.values.byName(method),
        path: path,
        body: body,
      ),
    );
    if (!response.ok)
      throw MediaError(
        response.status == 500 ? 'internal_error' : 'request_failed',
        '${response.body['error'] ?? 'Request failed'}',
        response.status,
      );
    if (method != 'get') _emit('change');
    return response.body;
  }

  @override
  Future<List<int>?> artwork(int fileId) async => withMediaFileSystem(
    fileSystem,
    () async {
      final row = await service.artwork(fileId);
      if (row == null) return null;
      final cache = cacheDirectory;
      if (cache == null) return row.data;
      final key = sha256.convert(row.data).toString();
      final file = cacheFileSystem.file(cacheFileSystem.path.join(cache, key));
      if (!await file.exists()) {
        await file.parent.create(recursive: true);
        final temp = cacheFileSystem.file(
          '${file.path}.$epoch.${++_cacheSequence}.tmp',
        );
        try {
          await temp.writeAsBytes(row.data, flush: true);
          await temp.rename(file.path);
        } finally {
          if (await temp.exists()) await temp.delete();
        }
      }
      return file.readAsBytes();
    },
  );
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    await _serial;
    try {
      await withMediaFileSystem(fileSystem, () async {
        try {
          await _queue.close();
        } finally {
          await service.close();
        }
      });
    } finally {
      await _events.close();
      _owners[db] = false;
    }
  }
}

class _EmbeddedConnection implements MediaTransport {
  _EmbeddedConnection(this.host);
  final MediaHost host;
  bool closed = false;
  void check() {
    if (closed) throw StateError('Connection closed');
  }

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) {
    check();
    return host.request(method, path, body);
  }

  @override
  Future<List<int>?> artwork(int id) {
    check();
    return host.artwork(id);
  }

  @override
  Stream<Map<String, Object?>> get events {
    check();
    return host.events;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
