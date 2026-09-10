import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cadence_client/cadence_client.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sql;
import 'linux_volume.dart';
import 'relocation.dart';
import 'volume_vfs.dart';

/// Product operation, run by a host supervisor after all service/player owners
/// have stopped. Locations are host-configured arguments, never API file paths.
/// stdout is newline-delimited JSON; exit 0 acknowledges a flushed active
/// destination, 64 is invalid invocation, 75 requires inspection/retry. SIGINT
/// and SIGTERM interrupt at the next chunk boundary without publishing success.
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
  ];
  final options = <String, String>{};
  for (var i = 0; i < args.length; i += 2) {
    if (i + 1 == args.length ||
        !names.contains(args[i]) ||
        options.containsKey(args[i])) {
      stderr.writeln(
        'Usage: cadenced relocate --source PATH/.cadence --source-kind directory|mount --destination PATH/.cadence --destination-kind directory|mount --operation-id ID --expected-id UUID [--source-mount-id ID] [--destination-mount-id ID]',
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
  try {
    if (!Platform.isLinux)
      throw UnsupportedError('Linux relocation adapter required');
    if (options['--operation-id'] == null || options['--expected-id'] == null)
      throw ArgumentError('operation-id and expected-id required');
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
      final lease = kind == 'mount'
          ? LinuxVolumeAttachment.acquire(
              p.dirname(location),
              initialize: initialize,
              expectedMountId: options['--$prefix-mount-id'],
            )
          : LinuxVolumeAttachment.acquireDirectory(
              p.dirname(location),
              initialize: initialize,
            );
      final handle = _StoreHandle(lease, location, kind);
      handles.add(handle);
      return handle;
    }

    final source = acquire('source', false);
    final destination = acquire('destination', true);
    final result = await relocateDatastore(
      source: source.store,
      destination: destination.store,
      operationId: options['--operation-id']!,
      expectedId: options['--expected-id']!,
      cancelled: () => cancelled,
      progress: emit,
    );
    // Release OS ownership before the supervisor starts the destination service.
    for (final handle in handles.reversed) {
      handle.close();
    }
    handles.clear();
    emit(result);
  } catch (error) {
    exitCode = error is ArgumentError ? 64 : 75;
    emit({
      'event': 'relocation-error',
      'operationId': options['--operation-id'],
      'state': 'failed',
      'retryWithSameOperationId': exitCode != 64,
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
  _StoreHandle(this.lease, String location, String kind) {
    vfs = VolumeVfs(
      lease.fileSystem,
      name: 'relocate-${_sequence++}',
      syncDirectory: lease.syncDirectory,
    );
    sql.sqlite3.registerVirtualFileSystem(vfs);
    try {
      db = sql.sqlite3.open('/.cadence/library.sqlite', vfs: vfs.name);
    } catch (_) {
      sql.sqlite3.unregisterVirtualFileSystem(vfs);
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
  static int _sequence = 0;
  final LinuxVolumeAttachment lease;
  late final VolumeVfs vfs;
  late final sql.Database db;
  late final RelocationStore store;
  bool _closed = false;
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      db.close();
    } finally {
      sql.sqlite3.unregisterVirtualFileSystem(vfs);
      lease.release();
    }
  }
}
