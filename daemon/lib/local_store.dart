import 'dart:ffi';
import 'dart:io' as io;
import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'volume.dart';
import 'local_owner.dart';
import 'linux_volume.dart';
import 'root_access.dart';
import 'root_filesystem.dart';

/// Host-owned metadata and cache; neither location may be removable storage.
/// Media may be anywhere under explicitly configured roots. Removable roots
/// require current mount observations when host availability is enabled.
class LinuxLocalStore
    implements LocalStoreAttachment, LocalPlaybackVolume, RootAccessAdapter {
  LinuxLocalStore._(
    this.owner,
    this.cacheDirectory,
    this.fileSystem,
    this.databaseExists,
  );
  final LocalOwner owner;
  bool _closed = false;
  @override
  final String cacheDirectory;
  @override
  final FileSystem fileSystem;
  @override
  final bool databaseExists;
  List<RootObservation> _roots = [];
  static LinuxLocalStore acquire(
    String databasePath,
    String cachePath, {
    bool hostAvailability = false,
  }) {
    final exists =
        io.File(databasePath).existsSync() &&
        io.File(databasePath).lengthSync() > 0;
    final owner = LocalOwner.acquire(databasePath);
    try {
      io.Directory(cachePath).createSync(recursive: true);
      LocalOwner.chmod(cachePath, 448);
      return LinuxLocalStore._(
        owner,
        io.Directory(cachePath).absolute.path,
        hostAvailability
            ? RootFileSystem(const LocalFileSystem())
            : const LocalFileSystem(),
        exists,
      );
    } catch (_) {
      owner.close();
      rethrow;
    }
  }

  @override
  bool get isAttached => !_closed;
  @override
  sql.Database openDatabase() => sql.sqlite3.open(owner.path);
  static final _syncfs = DynamicLibrary.process()
      .lookupFunction<Int32 Function(Int32), int Function(int)>('syncfs');
  @override
  void syncDirectory() {
    if (_closed || _syncfs(owner.fd) != 0)
      throw io.FileSystemException('Cannot flush local datastore');
  }

  @override
  void flush() {
    syncDirectory();
    // Cache may be on a different internal filesystem. Flush its open inode too.
    final cacheOwner = LocalOwner.acquire(
      fileSystem.path.join(cacheDirectory, '.flush'),
    );
    try {
      if (_syncfs(cacheOwner.fd) != 0)
        throw io.FileSystemException('Cannot flush local cache');
    } finally {
      cacheOwner.close();
    }
  }

  @override
  void configureRoots(List<RootObservation> roots) {
    final fs = fileSystem;
    if (fs is! RootFileSystem)
      throw StateError('Host root availability is disabled');
    final next = <String, RootLease>{};
    try {
      for (final root in roots) {
        final mount = root.mountPath;
        if (!root.available || mount == null || next.containsKey(mount))
          continue;
        next[mount] = LinuxRootLease.acquire(mount, root.mountId!);
      }
    } catch (_) {
      for (final lease in next.values) {
        lease.close();
      }
      rethrow;
    }
    for (final lease in fs.leases.values) {
      lease.close();
    }
    fs.leases
      ..clear()
      ..addAll(next);
    _roots = roots;
  }

  @override
  bool rootAvailable(String path) {
    final fs = fileSystem;
    if (fs is! RootFileSystem) return true;
    final roots = _roots
        .where((r) => r.path == path || fs.path.isWithin(r.path, path))
        .toList();
    if (roots.isEmpty) return false;
    return roots.every(
      (r) =>
          r.available &&
          (r.mountPath == null || fs.leases[r.mountPath]?.available == true),
    );
  }

  @override
  String playbackPath(String path) {
    if (!rootAvailable(path)) throw StateError('Root unavailable');
    final fs = fileSystem;
    if (fs is RootFileSystem)
      return fs
          .localMediaPath(path)
          .replaceFirst('/proc/self/', '/proc/${io.pid}/');
    return fileSystem.file(path).absolute.path;
  }

  @override
  void release() {
    if (_closed) return;
    _closed = true;
    final fs = fileSystem;
    if (fs is RootFileSystem) {
      for (final lease in fs.leases.values) {
        lease.close();
      }
      fs.leases.clear();
    }
    owner.close();
  }
}
