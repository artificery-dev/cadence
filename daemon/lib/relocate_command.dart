import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cadence_client/cadence_client.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sql;
import 'linux_volume.dart';
import 'relocation.dart';
import 'volume_vfs.dart';
import 'root_access.dart';

/// Product operation, run by a host supervisor after all service/player owners
/// have stopped. Locations are host-configured arguments, never API file paths.
/// stdout is newline-delimited JSON; exit 0 acknowledges a flushed active
/// destination, 64 is invalid invocation, 75 requires inspection/retry. SIGINT
/// and SIGTERM interrupt at the next chunk boundary without publishing success.
/// --check true opens existing databases read-only, never creates missing stores,
/// and returns relocation-preflight (exit 0 even when canRelocate is false).
/// Plans do not reserve a destination; execution revalidates under both leases.
/// On errors, cancelSafe permits clearing this intent and restarting the source;
/// false is conservative and must not be interpreted as permission to roll back.
Future<void> runRelocationCommand(List<String> args) async {
  const names = [
    '--source',
    '--source-kind',
    '--source-mount-id',
    '--destination',
    '--destination-kind',
    '--destination-mount-id',
    '--operation-id',
    '--expected-id',
    '--check',
  ];
  final options = <String, String>{};
  for (var i = 0; i < args.length; i += 2) {
    if (i + 1 == args.length ||
        !names.contains(args[i]) ||
        options.containsKey(args[i])) {
      stderr.writeln(
        'Usage: cadenced relocate --source PATH/.cadence --source-kind directory|mount --destination PATH/.cadence --destination-kind directory|mount --operation-id ID --expected-id UUID [--source-mount-id ID] [--destination-mount-id ID] [--check true|false]',
      );
      exitCode = 64;
      return;
    }
    options[args[i]] = args[i + 1];
  }
  void emit(Map<String, Object?> data) => stdout.writeln(jsonEncode(data));
  final handles = <_StoreHandle>[];
  final signals = <StreamSubscription<ProcessSignal>>[];
  var cancelled = false;
  var mutationStarted = false;
  _StoreHandle? source, destination;
  final checkOnly = options['--check'] == 'true';
  try {
    if (!Platform.isLinux)
      throw UnsupportedError('Linux relocation adapter required');
    if (options['--operation-id'] == null || options['--expected-id'] == null)
      throw ArgumentError('operation-id and expected-id required');
    if (options['--check'] != null &&
        !['true', 'false'].contains(options['--check']))
      throw ArgumentError('--check must be true or false');
    for (final prefix in ['source', 'destination']) {
      final location = options['--$prefix'];
      final kind = options['--$prefix-kind'];
      if (location == null ||
          !p.isAbsolute(location) ||
          p.normalize(location) != location ||
          p.basename(location) != '.cadence' ||
          !['directory', 'mount'].contains(kind))
        throw ArgumentError(
          'Canonical .cadence locations and storage kinds required',
        );
      if ((kind == 'mount') != options.containsKey('--$prefix-mount-id'))
        throw ArgumentError(
          'Each mount store requires its observed mount ID; directory stores do not accept one',
        );
      if (Directory(p.dirname(location)).resolveSymbolicLinksSync() !=
          p.dirname(location))
        throw ArgumentError(
          'Store parents must be canonical directories, not symbolic-link aliases',
        );
    }
    if (options['--source'] == options['--destination'])
      throw ArgumentError('Source and destination must differ');
    for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
      signals.add(signal.watch().listen((_) => cancelled = true));
    }
    _StoreHandle acquire(String prefix, bool initialize) {
      final location = options['--$prefix']!;
      final kind = options['--$prefix-kind']!;
      RootLease? root;
      if (checkOnly) {
        root = kind == 'mount'
            ? LinuxRootLease.acquire(
                p.dirname(location),
                options['--$prefix-mount-id']!,
              )
            : LinuxRootLease.acquireDirectory(p.dirname(location));
        try {
          final fs = root.fileSystem;
          final type = fs.typeSync('/.cadence', followLinks: false);
          if (type != FileSystemEntityType.notFound &&
              type != FileSystemEntityType.directory)
            throw StateError('Unsafe metadata directory');
          if (type == FileSystemEntityType.notFound ||
              fs.typeSync('/.cadence/library.sqlite', followLinks: false) ==
                  FileSystemEntityType.notFound) {
            final handle = _StoreHandle.empty(root, location, kind);
            handles.add(handle);
            return handle;
          }
        } catch (_) {
          root.close();
          rethrow;
        }
      }
      try {
        final lease = kind == 'mount'
            ? LinuxVolumeAttachment.acquire(
                p.dirname(location),
                initialize: initialize && !checkOnly,
                expectedMountId: options['--$prefix-mount-id'],
              )
            : LinuxVolumeAttachment.acquireDirectory(
                p.dirname(location),
                initialize: initialize && !checkOnly,
              );
        if (root != null && !root.available) {
          lease.release();
          throw StateError('Store root changed during inspection');
        }
        final handle = _StoreHandle(lease, location, kind, readOnly: checkOnly);
        handles.add(handle);
        return handle;
      } finally {
        root?.close();
      }
    }

    source = acquire('source', false);
    destination = acquire('destination', true);
    final result = await relocateDatastore(
      source: source.store,
      destination: destination.store,
      operationId: options['--operation-id']!,
      expectedId: options['--expected-id']!,
      cancelled: () => cancelled,
      progress: emit,
      checkOnly: checkOnly,
      onMutation: () => mutationStarted = true,
    );
    // Release OS ownership before the supervisor starts the destination service.
    for (final handle in handles.reversed) {
      handle.close();
    }
    handles.clear();
    emit(result);
  } catch (error) {
    exitCode = error is ArgumentError ? 64 : 75;
    final cancelSafe =
        source != null &&
        destination != null &&
        relocationCancelSafe(
          source: source.store,
          destination: destination.store,
          operationId: options['--operation-id']!,
          expectedId: options['--expected-id']!,
          mutationStarted: mutationStarted,
        );
    emit({
      'event': 'relocation-error',
      'operationId': options['--operation-id'],
      'state': 'failed',
      'retryWithSameOperationId': exitCode != 64 && !cancelSafe,
      'cancelSafe': cancelSafe,
      'checkOnly': checkOnly,
      'error': {
        'code': error is MediaError
            ? error.code
            : error is ArgumentError
            ? 'invalid_request'
            : 'relocation_failed',
        'message': '$error',
      },
    });
  } finally {
    for (final subscription in signals) {
      await subscription.cancel();
    }
    for (final handle in handles.reversed) {
      handle.close();
    }
  }
}

class _StoreHandle {
  _StoreHandle(
    LinuxVolumeAttachment lease,
    String location,
    String kind, {
    bool readOnly = false,
  }) {
    release = lease.release;
    vfs = VolumeVfs(
      lease.fileSystem,
      name: 'relocate-${_sequence++}',
      syncDirectory: lease.syncDirectory,
    );
    sql.sqlite3.registerVirtualFileSystem(vfs!);
    try {
      db = sql.sqlite3.open(
        '/.cadence/library.sqlite',
        vfs: vfs!.name,
        mode: readOnly ? sql.OpenMode.readOnly : sql.OpenMode.readWriteCreate,
      );
    } catch (_) {
      sql.sqlite3.unregisterVirtualFileSystem(vfs!);
      lease.release();
      rethrow;
    }
    store = RelocationStore(
      database: db,
      fileSystem: lease.fileSystem,
      cacheDirectory: '/.cadence/cache',
      location: location,
      storageKind: kind == 'mount' ? 'portable' : 'local',
      available: () => lease.isAttached,
      flush: lease.flush,
    );
  }
  _StoreHandle.empty(RootLease root, String location, String kind) {
    release = root.close;
    db = sql.sqlite3.openInMemory();
    store = RelocationStore(
      database: db,
      fileSystem: root.fileSystem,
      cacheDirectory: '/.cadence/cache',
      location: location,
      storageKind: kind == 'mount' ? 'portable' : 'local',
      available: () => root.available,
      flush: () => throw StateError('Preflight cannot write'),
    );
  }
  static int _sequence = 0;
  late final void Function() release;
  VolumeVfs? vfs;
  late final sql.Database db;
  late final RelocationStore store;
  bool _closed = false;
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      db.close();
    } finally {
      if (vfs != null) sql.sqlite3.unregisterVirtualFileSystem(vfs!);
      release();
    }
  }
}
