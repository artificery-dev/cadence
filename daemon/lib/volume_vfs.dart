import 'dart:typed_data';
import 'package:file/file.dart';
import 'package:sqlite3/sqlite3.dart';

/// SQLite I/O through the attachment filesystem. Never delegates path resolution
/// to SQLite's host VFS (which canonicalizes /proc/self/fd back to mount paths).
/// Requires exclusive attachment ownership for its entire lifetime. One SQLite
/// connection; rollback journals only, no WAL or external SQLite connections.
final class VolumeVfs extends BaseVirtualFileSystem {
  VolumeVfs(this.fs, {required super.name, required this.syncDirectory});
  final FileSystem fs;
  final void Function() syncDirectory;
  bool available = true;
  T io<T>(T Function() action) {
    if (!available) throw const VfsException(SqlError.SQLITE_IOERR);
    try {
      return action();
    } on FileSystemException {
      throw const VfsException(SqlError.SQLITE_IOERR);
    }
  }

  String checked(String path) {
    final name = fs.path.normalize(path);
    if (!fs.path.isAbsolute(name) || !fs.path.isWithin('/.cadence', name)) {
      throw const VfsException(SqlError.SQLITE_CANTOPEN);
    }
    // Database storage is flat; no symlink traversal or attached databases.
    if (fs.path.dirname(name) != '/.cadence' ||
        ![
          'library.sqlite',
          'library.sqlite-journal',
          'library.sqlite-wal',
        ].contains(fs.path.basename(name)) ||
        fs.typeSync(name, followLinks: false) == FileSystemEntityType.link) {
      throw const VfsException(SqlError.SQLITE_CANTOPEN);
    }
    return name;
  }

  @override
  XOpenResult xOpen(Sqlite3Filename path, int flags) => io(() {
    if (path.path == null || (flags & SqlFlag.SQLITE_OPEN_WAL) != 0)
      throw const VfsException(SqlError.SQLITE_CANTOPEN);
    final file = fs.file(checked(path.path!));
    if (!file.existsSync()) {
      if (flags & SqlFlag.SQLITE_OPEN_CREATE == 0) {
        throw const VfsException(SqlError.SQLITE_CANTOPEN);
      }
      file.createSync();
      syncDirectory();
    }
    return (
      outFlags: flags,
      file: _VolumeFile(this, file.openSync(mode: FileMode.append)),
    );
  });

  @override
  void xDelete(String path, int syncDir) => io(() {
    final file = fs.file(checked(path));
    if (file.existsSync()) file.deleteSync();
    if (syncDir != 0) syncDirectory();
  });
  @override
  int xAccess(String path, int flags) =>
      io(() => fs.file(checked(path)).existsSync() ? 1 : 0);
  @override
  String xFullPathName(String path) => checked(path);
  @override
  void xSleep(Duration duration) {} // Exclusive owner: never waits for other connections.
}

class _VolumeFile extends BaseVfsFile {
  _VolumeFile(this.vfs, this.file);
  final VolumeVfs vfs;
  final RandomAccessFile file;
  int lock = 0;
  @override
  void xClose() => file.closeSync();
  @override
  int readInto(Uint8List buffer, int offset) => vfs.io(() {
    file.setPositionSync(offset);
    return file.readIntoSync(buffer);
  });
  @override
  void xWrite(Uint8List buffer, int fileOffset) => vfs.io(() {
    file.setPositionSync(fileOffset);
    file.writeFromSync(buffer);
  });
  @override
  void xTruncate(int size) => vfs.io(() => file.truncateSync(size));
  @override
  void xSync(int flags) => vfs.io(() => file.flushSync());
  @override
  int xFileSize() => vfs.io(file.lengthSync);
  @override
  void xLock(int mode) {
    lock = mode;
  }

  @override
  void xUnlock(int mode) {
    lock = mode;
  }

  @override
  int xCheckReservedLock() => lock >= 2 ? 1 : 0;
}
