import 'endpoint.dart';
import 'dart:async';
import 'dart:math';
import 'package:cadence_client/cadence_client.dart';
import 'package:cadence_media/cadence_media.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:sqlite3/sqlite3.dart' as sql;
import 'host.dart';
import 'volume_vfs.dart';

/// Platform-owned lease on a volume, not a reusable mount-directory pathname.
/// [fileSystem] exposes POSIX volume-relative paths rooted at `/`. All media,
/// metadata and cache I/O must stay on the leased volume after detach. The
/// adapter must hold exclusive ownership until [release], and sync directory
/// entries durably. Memory adapters may implement this without OS operations.
abstract interface class VolumeAttachment {
  FileSystem get fileSystem;
  bool get isAttached;
  void syncDirectory();

  /// Flush all attachment writes, including cache directory entries, before release.
  void flush();
  void release();
}

/// Optional local-player adapter. Returned paths are valid only while the
/// attachment generation is current; the player must close them before eject.
abstract interface class LocalPlaybackVolume {
  String playbackPath(String volumePath);
}

typedef AttachVolume =
    Future<VolumeAttachment> Function({required bool initialize});

/// Keeps the endpoint alive across card removal. Attach is host-configured:
/// callers cannot supply a mount path. The same implementation is embeddable.
class PortableVolumeHost implements MediaEndpoint {
  PortableVolumeHost({
    required this.attach,
    this.initialize = false,
    this.policy = const ScanPolicy(artwork: ArtworkPolicy.deferred),
    this.nativeAvailable = false,
    this.reconcileOnAttach = true,
    this.buildExtractor = defaultMediaExtractor,
  });
  final AttachVolume attach;
  final bool initialize;
  late bool _mayInitialize = initialize;
  final bool reconcileOnAttach;
  final bool nativeAvailable;
  final ScanPolicy policy;
  final ExtractorBuilder buildExtractor;
  VolumeAttachment? _attachment;
  VolumeVfs? _vfs;
  MediaHost? _host;
  StreamSubscription<Map<String, Object?>>? _subscription;
  final _events = StreamController<Map<String, Object?>>.broadcast();
  Future<void> _serial = Future.value();
  String? _id;
  String? _generation;
  int _attachmentSequence = 0;
  bool _quiescing = false;
  int _reads = 0, _writes = 0;
  String _state = 'detached';
  String? _error;
  bool _closed = false;
  Timer? _monitor;
  final String epoch = DateTime.now().microsecondsSinceEpoch.toString();
  int _revision = 0;
  Map<String, Object?> get status => {
    'id': _id,
    'generation': _generation,
    'activity': {
      'activeReadRequests': _reads,
      'activeWriteRequests': _writes,
      ...(_host?.activity ??
          const {
            'runningJobs': 0,
            'queuedJobs': 0,
            'artwork': {'running': false, 'pending': 0},
          }),
      'draining': _quiescing && _host != null,
    },
    'state': _state,
    'formatVersion': 1,
    'pathStyle': 'volume-posix',
    'readyToUnmount': _state == 'detached',
    'scope': 'cadenced',
    if (_error != null) 'error': _error,
  };
  void _emit(Map<String, Object?> value) => _events.add({
    ...value,
    'volumeId': _id,
    'generation': _generation,
    'epoch': epoch,
    'revision': ++_revision,
  });
  void _changed() => _emit({'type': 'volume-state-changed', ...status});
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

  Future<void> open() => _exclusive(() => _open(null));
  Future<void> _open(String? expectedId) async {
    if (_closed) throw MediaError('closed', 'Volume host closed', 503);
    if (_host != null)
      throw MediaError('volume_attached', 'Eject before attaching', 409);
    _state = 'attaching';
    _error = null;
    _changed();
    sql.Database? connection;
    try {
      final allowInitialize = _mayInitialize && expectedId == null;
      final attachment = _attachment = await attach(
        initialize: allowInitialize,
      );
      if (!attachment.isAttached) throw StateError('Volume is unavailable');
      final fs = attachment.fileSystem;
      final stored = fs.file('/.cadence/library.sqlite');
      final exists = stored.existsSync() && stored.lengthSync() > 0;
      if (!exists && !allowInitialize)
        throw StateError(
          'Uninitialized volume; explicit initialization required',
        );
      if (expectedId != null && !exists)
        throw StateError('Expected existing volume');
      final vfs = _vfs = VolumeVfs(
        fs,
        name: 'cadence-volume-$epoch-${++_revision}',
        syncDirectory: attachment.syncDirectory,
      );
      sql.sqlite3.registerVirtualFileSystem(vfs);
      connection = sql.sqlite3.open('/.cadence/library.sqlite', vfs: vfs.name);
      // This VFS deliberately has no shared-memory API. All temporary tables
      // remain in memory, and every persistent write uses the volume lease.
      connection.execute('PRAGMA journal_mode = DELETE');
      connection.execute('PRAGMA synchronous = EXTRA');
      connection.execute('PRAGMA temp_store = MEMORY');
      if (!exists) {
        final random = Random.secure();
        final bytes = List<int>.generate(16, (_) => random.nextInt(256));
        bytes[6] = (bytes[6] & 15) | 64;
        bytes[8] = (bytes[8] & 63) | 128;
        final hex = bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        final id =
            '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
        connection.execute(
          'CREATE TABLE cadence_volume (id TEXT PRIMARY KEY, format_version INTEGER NOT NULL)',
        );
        connection.execute('INSERT INTO cadence_volume VALUES (?, 1)', [id]);
      }
      final rows = connection.select(
        'SELECT id, format_version FROM cadence_volume',
      );
      if (rows.length != 1 || rows.single['format_version'] != 1)
        throw StateError('Unsupported portable volume format');
      final id = rows.single['id'] as String;
      if (expectedId != null && expectedId != id)
        throw MediaError('volume_mismatch', 'Different card attached', 409);
      _id = id;
      _generation = '$epoch-${++_attachmentSequence}';
      final database = MediaDatabase(NativeDatabase.opened(connection));
      connection = null;
      try {
        _host = await MediaHost.open(
          database: database,
          fileSystem: fs,
          cacheDirectory: '/.cadence/cache',
          policy: policy,
          buildExtractor: buildExtractor,
          nativeAvailable: nativeAvailable,
          autoStartJobs: false,
        );
      } catch (_) {
        await database.close();
        rethrow;
      }
      _subscription = _host!.events.listen((e) {
        _emit(e);
        if (e['type'] == 'progress' || e['type'] == 'change')
          _emit({'type': 'volume-activity', ...status});
      });
      _mayInitialize = false;
      _quiescing = false;
      _state = 'attached';
      _changed();
      _host!.resumeJobs();
      if (reconcileOnAttach) {
        for (final library in await LibraryRepository(
          database,
        ).listLibraries()) {
          try {
            await _host!.request('post', '/libraries/${library.id}/scan');
          } on MediaError catch (e) {
            if (e.code != 'scan_conflict') rethrow;
          }
        }
      }
      _monitor = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (_attachment?.isAttached == false) {
          _monitor?.cancel();
          unawaited(_exclusive(() => _detach(lost: true)));
        }
      });
    } catch (e) {
      connection?.close();
      if (_host != null) {
        await _detach(lost: true);
      } else {
        _release();
      }
      _state = 'unavailable';
      _error = '$e';
      _changed();
      rethrow;
    }
  }

  void _release() {
    final vfs = _vfs;
    _vfs = null;
    if (vfs != null) sql.sqlite3.unregisterVirtualFileSystem(vfs);
    _attachment?.release();
    _attachment = null;
  }

  Future<void> _detach({bool lost = false}) async {
    _monitor?.cancel();
    _quiescing = true;
    _state = lost ? 'unavailable' : 'quiescing';
    _changed();
    if (lost) _vfs?.available = false;
    try {
      await _host?.close();
      if (!lost) _attachment?.flush();
    } catch (e) {
      _error = '$e';
    } finally {
      _host = null;
      await _subscription?.cancel();
      _subscription = null;
      _release();
      _state = lost || _error != null ? 'unavailable' : 'detached';
      _changed();
    }
  }

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) {
    if (_closed)
      return Future.error(MediaError('closed', 'Volume host closed', 503));
    if (method == 'get' && path == '/volume') return Future.value(status);
    if (method == 'post' && path == '/volume/eject') {
      if (body != null &&
          body.keys.any(
            (k) => k != 'expectedId' && k != 'expectedGeneration',
          )) {
        return Future.error(
          MediaError(
            'invalid_request',
            'Only expectedId and expectedGeneration accepted',
            400,
          ),
        );
      }
      if ((body?['expectedId'] != null && body!['expectedId'] != _id) ||
          (body?['expectedGeneration'] != null &&
              body!['expectedGeneration'] != _generation)) {
        return Future.error(
          MediaError('stale_generation', 'Attachment generation changed', 409),
        );
      }
      _quiescing = true;
      _state = 'quiescing';
      _changed();
    } else if (_quiescing &&
        path != '/volume/attach' &&
        path != '/snapshot' &&
        path != '/capabilities') {
      return Future.error(
        MediaError(
          'volume_quiescing',
          'Volume is quiescent; explicitly attach to resume',
          503,
        ),
      );
    }
    return _exclusive(() async {
      if (method == 'get') {
        _reads++;
      } else {
        _writes++;
      }
      _emit({'type': 'volume-activity', ...status});
      try {
        return await _route(method, path, body);
      } finally {
        if (method == 'get') {
          _reads--;
        } else {
          _writes--;
        }
        _emit({'type': 'volume-activity', ...status});
      }
    });
  }

  Future<Map<String, Object?>> _route(
    String method,
    String path,
    Map<String, Object?>? body,
  ) async {
    if (_closed) throw MediaError('closed', 'Volume host closed', 503);
    if (method == 'get' && path == '/volume') return status;
    if (method == 'post' && path == '/volume/attach') {
      if (body != null &&
          body.keys.any((k) => k != 'expectedId' && k != 'expectedGeneration'))
        throw MediaError(
          'invalid_request',
          'Only expectedId and expectedGeneration are accepted',
          400,
        );
      if (body?['expectedId'] != null && body!['expectedId'] is! String)
        throw MediaError('invalid_request', 'expectedId must be a string', 400);
      if (body?['expectedGeneration'] != null &&
          body!['expectedGeneration'] != _generation)
        throw MediaError(
          'stale_generation',
          'Attachment generation changed',
          409,
        );
      await _open(body?['expectedId'] as String?);
      return status;
    }
    if (method == 'post' && path == '/volume/eject') {
      if ((body?['expectedId'] != null && body!['expectedId'] != _id) ||
          (body?['expectedGeneration'] != null &&
              body!['expectedGeneration'] != _generation)) {
        throw MediaError(
          'stale_generation',
          'Attachment generation changed',
          409,
        );
      }
      await _detach();
      return status;
    }
    if (method == 'get' && path == '/snapshot' && _host == null)
      return {
        'epoch': epoch,
        'revision': _revision,
        'volume': status,
        'libraries': [],
        'jobs': [],
      };
    if (method == 'get' && path == '/capabilities' && _host == null) {
      return {
        'apiVersions': [1],
        'portableVolume': true,
        'volumeFormatVersion': 1,
        'pathStyle': 'volume-posix',
        'eventRecovery': 'snapshot-and-query',
        'localPlayback': true,
        'watch': false,
        'nativeExtraction': nativeAvailable,
      };
    }
    final host = _host;
    if (host == null || _attachment?.isAttached != true)
      throw MediaError(
        'volume_unavailable',
        'Attach the library volume first',
        503,
      );
    if (method == 'post' && path == '/media/resolve') {
      if (body?['libraryUuid'] is! String ||
          body?['itemId'] is! int ||
          body?['volumeId'] is! String ||
          body?['generation'] is! String) {
        throw MediaError(
          'invalid_request',
          'libraryUuid, itemId, volumeId and generation required',
          400,
        );
      }
      if (body!['volumeId'] != _id || body['generation'] != _generation)
        throw MediaError(
          'stale_generation',
          'Attachment generation changed',
          409,
        );
      final rows = await host.db
          .customSelect(
            'SELECT f.path FROM library_identities li JOIN library_items i ON i.library_id = li.library_id '
            'JOIN files f ON f.id = i.file_id WHERE li.uuid = ? AND i.id = ? AND f.missing_since IS NULL',
            variables: [
              Variable.withString(body['libraryUuid'] as String),
              Variable.withInt(body['itemId'] as int),
            ],
          )
          .get();
      if (rows.isEmpty)
        throw MediaError('not_found', 'Media item not found in library', 404);
      final attachment = _attachment;
      if (attachment is! LocalPlaybackVolume)
        throw MediaError(
          'unsupported_capability',
          'No local playback path adapter',
          501,
        );
      final path = rows.single.read<String>('path');
      if (!await host.fileSystem.file(path).exists())
        throw MediaError('not_found', 'Media file unavailable', 404);
      return {
        'libraryUuid': body['libraryUuid'],
        'itemId': body['itemId'],
        'volumeId': _id,
        'generation': _generation,
        'path': (attachment as LocalPlaybackVolume).playbackPath(path),
      };
    }
    if (method == 'post' &&
        Uri.parse(path).pathSegments.lastOrNull == 'roots') {
      final root = body?['path'];
      if (root is! String ||
          !root.startsWith('/') ||
          root.contains('\\') ||
          root.split('/').contains('..') ||
          host.fileSystem.path.normalize(root) == '/.cadence' ||
          host.fileSystem.path.normalize(root).startsWith('/.cadence/')) {
        throw MediaError(
          'invalid_request',
          'Use a volume-relative POSIX root outside /.cadence',
          400,
        );
      }
    }
    final result = await host.request(method, path, body);
    if (path == '/snapshot')
      return {
        ...result,
        'epoch': epoch,
        'revision': _revision,
        'volume': status,
      };
    if (path == '/capabilities')
      return {
        ...result,
        'portableVolume': true,
        'localPlayback': _attachment is LocalPlaybackVolume,
        'volumeFormatVersion': 1,
        'pathStyle': 'volume-posix',
      };
    return result;
  }

  @override
  Future<List<int>?> artwork(int id) {
    if (_quiescing)
      return Future.error(
        MediaError('volume_quiescing', 'Volume quiescent', 503),
      );
    return _exclusive(() async {
      if (_closed || _host == null || _attachment?.isAttached != true)
        throw MediaError('volume_unavailable', 'Volume unavailable', 503);
      _reads++;
      _emit({'type': 'volume-activity', ...status});
      try {
        return await _host!.artwork(id);
      } finally {
        _reads--;
        _emit({'type': 'volume-activity', ...status});
      }
    });
  }

  @override
  Stream<Map<String, Object?>> get events => _events.stream;
  @override
  Future<void> close() => _exclusive(() async {
    if (_closed) return;
    _closed = true;
    await _detach();
    await _events.close();
  });
}
