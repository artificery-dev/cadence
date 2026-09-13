import 'endpoint.dart';
import 'dart:async';
import 'dart:math';
import 'package:cadence_client/cadence_client.dart';
import 'package:cadence_media/cadence_media.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Variable, Value;
import 'package:sqlite3/sqlite3.dart' as sql;
import 'host.dart';
import 'volume_vfs.dart';
import 'root_access.dart';
import 'relocation.dart' show requireActiveDatastore;

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

/// The same relative-path datastore may live on a removable mount or in an
/// existing host directory (for example a user's home). Availability policy is
/// a platform concern; both use /.cadence and volume-relative POSIX media paths.
abstract interface class RootedStoreAttachment implements VolumeAttachment {
  bool get removable;
}

/// Optional local-player adapter. Returned paths are valid only while the
/// attachment generation is current; the player must close them before eject.
abstract interface class LocalPlaybackVolume {
  String playbackPath(String volumePath);
}

/// Local metadata storage with media roots anywhere in the injected filesystem.
/// The adapter owns the SQLite connection's exclusive OS lease and cache path.
abstract interface class LocalStoreAttachment implements VolumeAttachment {
  bool get databaseExists;
  String get cacheDirectory;
  sql.Database openDatabase();
}

/// Metadata storage is independent of the media filesystem's synthetic `/`.
/// Media paths retain the same meaning when metadata moves between home and SD.
abstract interface class RelativeMediaStoreAttachment
    implements LocalStoreAttachment {
  FileSystem get cacheFileSystem;
  String get declaredMediaRoot;
  String? get mediaMount;
  bool get removableMetadata;
  String get resolvedMediaRoot;
  void initializeConfiguration(sql.Database db);
}

typedef AttachVolume =
    Future<VolumeAttachment> Function({required bool initialize});

/// Keeps the endpoint alive across card removal. Attach is host-configured:
/// callers cannot supply a mount path. The same implementation is embeddable.
class ManagedLibraryHost implements MediaEndpoint {
  ManagedLibraryHost({
    required this.attach,
    this.initialize = false,
    this.policy = const ScanPolicy(artwork: ArtworkPolicy.deferred),
    this.nativeAvailable = false,
    this.reconcileOnAttach = true,
    this.buildExtractor = defaultMediaExtractor,
    this.hashFile = sampledSha256OfFile,
    this.hostRootAvailability = false,
    this.watch,
  });
  final AttachVolume attach;
  final bool hostRootAvailability;
  final LibraryWatchService Function(ScanCoordinator)? watch;
  bool _rootAvailabilityReady = true;
  String _storageKind = 'portable';
  String _pathStyle = 'volume-posix';
  List<RootObservation> _roots = [];
  bool _checkingRoots = false;
  final bool initialize;
  late bool _mayInitialize = initialize;
  final bool reconcileOnAttach;
  final bool nativeAvailable;
  final ScanPolicy policy;
  final ExtractorBuilder buildExtractor;

  /// The scanner's identity hash — [sampledSha256OfFile], or the native
  /// probe's when one is loaded.
  final Future<String> Function(String path) hashFile;

  /// How fast scans may read. Held here rather than by the host so the
  /// pace a client set survives the host being reopened on a new volume.
  final ScanBudget budget = ScanBudget();
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
      'draining': (_quiescing || !_rootAvailabilityReady) && _host != null,
    },
    'state': _state,
    'formatVersion': 1,
    'storageKind': _storageKind,
    'rootAvailabilityReady': _rootAvailabilityReady,
    'roots': [
      if (hostRootAvailability)
        for (final r in _roots)
          {
            'rootId': r.rootId,
            'path': r.path,
            'available':
                r.available &&
                (_attachment is! RootAccessAdapter ||
                    (_attachment as RootAccessAdapter).rootAvailable(r.path)),
            'mountPath': r.mountPath,
            'mountId': r.mountId,
            'sourceId': r.sourceId,
          },
    ],
    'quiescentRootIds': [
      if (hostRootAvailability && _rootAvailabilityReady)
        for (final r in _roots)
          if (!r.available) r.rootId,
    ],
    'quiescentMountPaths': [
      if (hostRootAvailability && _rootAvailabilityReady)
        for (final mount
            in _roots.map((r) => r.mountPath).whereType<String>().toSet())
          if (_roots
              .where((r) => r.mountPath == mount)
              .every((r) => !r.available))
            mount,
    ],
    'pathStyle': _pathStyle,
    if (_attachment case final RelativeMediaStoreAttachment store) ...{
      'mediaRoot': store.declaredMediaRoot,
      'mediaMount': store.mediaMount,
      'resolvedMediaRoot': store.resolvedMediaRoot,
    },
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
      final local = attachment is LocalStoreAttachment ? attachment : null;
      final relative = attachment is RelativeMediaStoreAttachment
          ? attachment
          : null;
      if (relative != null && !hostRootAvailability) {
        throw StateError(
          'Declared media stores require host root availability',
        );
      }
      _storageKind =
          local != null ||
              attachment is RootedStoreAttachment && !attachment.removable
          ? 'local'
          : 'portable';
      _pathStyle = local == null ? 'volume-posix' : 'host-absolute';
      if (relative != null) {
        _storageKind = relative.removableMetadata ? 'portable' : 'local';
        _pathStyle = 'volume-posix';
      }
      _rootAvailabilityReady = !hostRootAvailability;
      final stored = fs.file('/.cadence/library.sqlite');
      final exists =
          local?.databaseExists ??
          (stored.existsSync() && stored.lengthSync() > 0);
      if (!exists && !allowInitialize && (local == null || relative != null))
        throw StateError(
          'Uninitialized volume; explicit initialization required',
        );
      if (expectedId != null && !exists)
        throw StateError('Expected existing datastore');
      if (local != null) {
        connection = local.openDatabase();
      } else {
        final vfs = _vfs = VolumeVfs(
          fs,
          name: 'cadence-volume-$epoch-${++_revision}',
          syncDirectory: attachment.syncDirectory,
        );
        sql.sqlite3.registerVirtualFileSystem(vfs);
        connection = sql.sqlite3.open(
          '/.cadence/library.sqlite',
          vfs: vfs.name,
        );
      }
      requireActiveDatastore(connection);
      final hasIdentity = connection
          .select(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='cadence_volume'",
          )
          .isNotEmpty;
      if (exists && !hasIdentity) {
        throw MediaError(
          'unsupported_datastore_format',
          'Existing database is not a Cadence datastore',
          409,
        );
      }
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
        connection.execute('BEGIN IMMEDIATE');
        connection.execute(
          'CREATE TABLE cadence_volume (id TEXT PRIMARY KEY, format_version INTEGER NOT NULL)',
        );
        connection.execute('INSERT INTO cadence_volume VALUES (?, 1)', [id]);
        relative?.initializeConfiguration(connection);
        connection.execute('COMMIT');
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
          cacheDirectory: local?.cacheDirectory ?? '/.cadence/cache',
          cacheFileSystem: relative?.cacheFileSystem,
          requireRootAvailability: hostRootAvailability,
          watch: watch,
          policy: policy,
          buildExtractor: buildExtractor,
          hashFile: hashFile,
          budget: budget,
          nativeAvailable: nativeAvailable,
          autoStartJobs: false,
        );
      } catch (_) {
        await database.close();
        rethrow;
      }
      await database.customStatement(
        'CREATE TABLE IF NOT EXISTS daemon_root_mounts (root_id INTEGER PRIMARY KEY REFERENCES library_roots(id) ON DELETE CASCADE, mount_path TEXT NOT NULL)',
      );
      await database.customStatement(
        'CREATE TABLE IF NOT EXISTS daemon_root_sources (root_id INTEGER PRIMARY KEY REFERENCES library_roots(id) ON DELETE CASCADE, source_id TEXT)',
      );
      if (relative != null) {
        // Physical mount paths may differ on the next player. The declaration
        // supplies their current location; stable source IDs still gate reuse.
        await database.transaction(() async {
          await database.customStatement('DELETE FROM daemon_root_mounts');
          if (relative.mediaMount != null) {
            await database.customStatement(
              'INSERT INTO daemon_root_mounts SELECT id, ? FROM library_roots',
              [relative.mediaMount],
            );
          }
        });
      }
      final sourceRows = await database
          .customSelect('SELECT * FROM daemon_root_sources')
          .get();
      final sources = {
        for (final r in sourceRows)
          r.read<int>('root_id'): r.readNullable<String>('source_id'),
      };
      final mountRows = await database
          .customSelect('SELECT * FROM daemon_root_mounts')
          .get();
      final mounts = {
        for (final r in mountRows)
          r.read<int>('root_id'): r.read<String>('mount_path'),
      };
      _roots = [
        for (final r in await database.select(database.libraryRoots).get())
          RootObservation(
            r.id,
            r.path,
            false,
            mountPath: mounts[r.id],
            sourceId: sources[r.id],
          ),
      ];
      if (attachment is RootAccessAdapter) {
        _host!.rootAccessAvailable =
            (attachment as RootAccessAdapter).rootAvailable;
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
      if (_rootAvailabilityReady) await _resume();
      _monitor = Timer.periodic(const Duration(milliseconds: 250), (_) {
        final adapter = _attachment;
        if (!_checkingRoots &&
            _rootAvailabilityReady &&
            adapter is RootAccessAdapter &&
            _roots.any(
              (r) =>
                  r.available &&
                  !(adapter as RootAccessAdapter).rootAvailable(r.path),
            )) {
          _checkingRoots = true;
          unawaited(
            _exclusive(() async {
                  if (_closed || _host == null) return;
                  await _applyRoots([
                    for (final r in _roots)
                      RootObservation(
                        r.rootId,
                        r.path,
                        r.available &&
                            (adapter as RootAccessAdapter).rootAvailable(
                              r.path,
                            ),
                        mountPath: r.mountPath,
                        mountId: r.mountId,
                        sourceId: r.sourceId,
                      ),
                  ]);
                })
                .catchError((Object e) {
                  _error = '$e';
                  _changed();
                })
                .whenComplete(() => _checkingRoots = false),
          );
        }
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

  Future<void> _resume() async {
    final host = _host!;
    host.resumeJobs();
    await host.service.resumeBackground();
    if (reconcileOnAttach) {
      for (final library in await LibraryRepository(host.db).listLibraries()) {
        try {
          await host.request('post', '/libraries/${library.id}/scan');
        } on MediaError catch (e) {
          if (e.code != 'scan_conflict') rethrow;
        }
      }
    }
  }

  Future<void> _applyRoots(List<RootObservation> roots) async {
    final host = _host!;
    _rootAvailabilityReady = false;
    for (final root in roots) {
      host.availability[root.path] = false;
    }
    _changed();
    await host.pauseWork();
    final adapter = _attachment;
    try {
      if (adapter is RootAccessAdapter)
        (adapter as RootAccessAdapter).configureRoots(roots);
      else if (roots.any((r) => r.mountPath != null))
        throw UnsupportedError('No removable-root adapter');
      final invalidated = roots
          .where(
            (r) =>
                r.available &&
                r.mountPath != null &&
                (r.sourceId == null ||
                    !_roots.any(
                      (old) =>
                          old.rootId == r.rootId && old.sourceId == r.sourceId,
                    )),
          )
          .toList();
      if (invalidated.isNotEmpty) {
        final files = await host.db.select(host.db.files).get();
        final ids = [
          for (final file in files)
            if (invalidated.any(
              (r) => host.fileSystem.path.isWithin(r.path, file.path),
            ))
              file.id,
        ];
        for (var start = 0; start < ids.length; start += 500) {
          await (host.db.update(host.db.files)
                ..where((f) => f.id.isIn(ids.skip(start).take(500))))
              .write(const FilesCompanion(scannedAt: Value(null)));
        }
      }
      await host.setRootAvailability({
        for (final r in roots) r.rootId: r.available,
      });
      await host.db.transaction(() async {
        for (final r in roots) {
          await host.db.customStatement(
            'INSERT OR REPLACE INTO daemon_root_sources VALUES (?, ?)',
            [r.rootId, r.sourceId],
          );
          if (r.mountPath != null)
            await host.db.customStatement(
              'INSERT OR REPLACE INTO daemon_root_mounts VALUES (?, ?)',
              [r.rootId, r.mountPath],
            );
        }
      });
    } catch (e) {
      for (final root in roots) {
        host.availability[root.path] = false;
      }
      _error = '$e';
      _changed();
      throw MediaError('root_observation_failed', '$e', 409);
    }
    _roots = roots;
    _rootAvailabilityReady = true;
    _generation = '$epoch-${++_attachmentSequence}';
    _error = null;
    _changed();
    await _resume();
  }

  Future<void> _rootConfigurationChanged() async {
    if (!hostRootAvailability) return;
    _rootAvailabilityReady = false;
    final host = _host!;
    for (final path in host.availability.keys.toList()) {
      host.availability[path] = false;
    }
    await host.pauseWork();
    final adapter = _attachment;
    if (adapter is RootAccessAdapter)
      (adapter as RootAccessAdapter).configureRoots([]);
    _generation = '$epoch-${++_attachmentSequence}';
    _changed();
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
        'portableVolume': _storageKind == 'portable',
        'managedStore': true,
        'hostRootAvailability': hostRootAvailability,
        'volumeFormatVersion': 1,
        'pathStyle': _pathStyle,
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
    if (method == 'post' && path == '/volume/roots') {
      if (!hostRootAvailability)
        throw MediaError(
          'unsupported_capability',
          'Host root availability is not enabled',
          409,
        );
      if (body?['expectedId'] != _id ||
          body?['expectedGeneration'] != _generation)
        throw MediaError(
          'stale_generation',
          'Current datastore identity and generation required',
          409,
        );
      final roots = body?['roots'];
      if (roots is! List)
        throw MediaError(
          'invalid_request',
          'roots must be a complete list',
          400,
        );
      final configured = {
        for (final r in await host.db.select(host.db.libraryRoots).get())
          r.id: r,
      };
      final mounts = {
        for (final r
            in await host.db
                .customSelect('SELECT * FROM daemon_root_mounts')
                .get())
          r.read<int>('root_id'): r.read<String>('mount_path'),
      };
      final values = <int, RootObservation>{};
      for (final root in roots) {
        if (root is! Map ||
            root['rootId'] is! int ||
            root['available'] is! bool ||
            values.containsKey(root['rootId']) ||
            !configured.containsKey(root['rootId']))
          throw MediaError(
            'invalid_request',
            'Known unique rootId and boolean available required',
            400,
          );
        final row = configured[root['rootId']]!;
        final mount = root['mountPath'] ?? mounts[row.id];
        if (mount != null &&
            (mount is! String ||
                !host.fileSystem.path.isAbsolute(mount) ||
                !_mountContains(row.path, mount)))
          throw MediaError(
            'invalid_request',
            'mountPath must contain its configured root',
            400,
          );
        if (mount != null &&
            root['available'] == true &&
            root['mountId'] is! String)
          throw MediaError(
            'invalid_request',
            'Current mountId is required for available removable roots',
            400,
          );
        if (root['sourceId'] != null &&
            (root['sourceId'] is! String ||
                (root['sourceId'] as String).isEmpty))
          throw MediaError(
            'invalid_request',
            'sourceId must be a nonempty string',
            400,
          );
        if (root['mountId'] != null && root['mountId'] is! String)
          throw MediaError('invalid_request', 'mountId must be a string', 400);
        values[row.id] = RootObservation(
          row.id,
          row.path,
          root['available'] as bool,
          mountPath: mount as String?,
          mountId: root['mountId'] as String?,
          sourceId:
              root['sourceId'] as String? ??
              (root['available'] == false
                  ? _roots
                        .where((r) => r.rootId == row.id)
                        .firstOrNull
                        ?.sourceId
                  : null),
        );
      }
      if (values.length != configured.length)
        throw MediaError(
          'invalid_request',
          'Supply every configured root exactly once',
          400,
        );
      final observations = values.values.toList();
      for (final r in observations) {
        if (observations.any(
          (other) => other.path == r.path && other.available != r.available,
        ))
          throw MediaError(
            'invalid_request',
            'Shared root availability must agree',
            400,
          );
        if (r.available &&
            r.mountPath != null &&
            observations.any(
              (other) =>
                  other.available &&
                  other.mountPath == r.mountPath &&
                  other.mountId != r.mountId,
            ))
          throw MediaError(
            'invalid_request',
            'Mount identities must agree',
            400,
          );
      }
      await _applyRoots(observations);
      return status;
    }
    if (!_rootAvailabilityReady &&
        ((method == 'post' &&
                Uri.parse(path).pathSegments.lastOrNull == 'scan') ||
            path == '/media/resolve' ||
            path.startsWith('/artwork'))) {
      throw MediaError(
        'root_availability_required',
        'Provide /volume/roots before starting filesystem work',
        409,
      );
    }
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
      if (!host.fileAvailable(path))
        throw MediaError('root_unavailable', 'Media root is unavailable', 503);
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
    if (_pathStyle == 'volume-posix' &&
        method == 'post' &&
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
    final parts = Uri.parse(path).pathSegments;
    if (hostRootAvailability &&
        method == 'put' &&
        parts.length == 4 &&
        parts[2] == 'roots')
      throw MediaError(
        'use_root_snapshot',
        'Use /volume/roots for a draining availability update',
        409,
      );
    if (hostRootAvailability &&
        method == 'post' &&
        parts.length == 3 &&
        parts[2] == 'roots') {
      final rootPath = body?['path'];
      final mount =
          body?['mountPath'] ??
          (_attachment is RelativeMediaStoreAttachment
              ? (_attachment as RelativeMediaStoreAttachment).mediaMount
              : null);
      if (mount != null &&
          (mount is! String ||
              rootPath is! String ||
              !host.fileSystem.path.isAbsolute(mount) ||
              !_mountContains(rootPath, mount)))
        throw MediaError(
          'invalid_request',
          'mountPath must contain its root',
          400,
        );
      final result = await host.request(method, path, {
        ...?body,
        'available': false,
      });
      if (mount != null)
        await host.db.customStatement(
          'INSERT INTO daemon_root_mounts VALUES (?, ?)',
          [result['id'], mount],
        );
      await _rootConfigurationChanged();
      return result;
    }
    final result = await host.request(method, path, body);
    if (method == 'delete' &&
        parts.firstOrNull == 'libraries' &&
        (parts.length == 2 || parts.length == 4 && parts[2] == 'roots'))
      await _rootConfigurationChanged();
    if (method == 'get' &&
        (path == '/snapshot' || parts.lastOrNull == 'roots') &&
        result['roots'] is List) {
      final mounts = {
        for (final r
            in await host.db
                .customSelect('SELECT * FROM daemon_root_mounts')
                .get())
          r.read<int>('root_id'): r.read<String>('mount_path'),
      };
      result['roots'] = [
        for (final r in (result['roots'] as List).cast<Map>())
          {...r, 'mountPath': mounts[r['id']]},
      ];
    }
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
        'portableVolume': _storageKind == 'portable',
        'managedStore': true,
        'hostRootAvailability': hostRootAvailability,
        'localPlayback': _attachment is LocalPlaybackVolume,
        'volumeFormatVersion': 1,
        'pathStyle': _pathStyle,
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
      if (!_rootAvailabilityReady)
        throw MediaError(
          'root_availability_required',
          'Provide /volume/roots first',
          409,
        );
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

  bool _mountContains(String root, String mount) {
    final attachment = _attachment;
    if (attachment is RelativeMediaStoreAttachment)
      return attachment.mediaMount == mount;
    return root == mount || _host!.fileSystem.path.isWithin(mount, root);
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
