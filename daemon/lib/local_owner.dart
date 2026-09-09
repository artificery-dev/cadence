import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Linux advisory flock, held across the entire SQLite connection lifetime.
/// Locks the database inode itself, so symlink and hard-link aliases share ownership.
/// External tools must never unlink/replace an open database.
class LocalOwner {
  LocalOwner._(this.fd, this.path);
  final int fd;
  final String path;
  static final _libc = DynamicLibrary.open('libc.so.6');
  static final _open = _libc
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32, Uint32),
        int Function(Pointer<Utf8>, int, int)
      >('open');
  static final _flock = _libc
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'flock',
      );
  static final _close = _libc
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  static final _chmod = _libc
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Uint32),
        int Function(Pointer<Utf8>, int)
      >('chmod');
  static void chmod(String path, int mode) {
    final ptr = path.toNativeUtf8();
    try {
      if (_chmod(ptr, mode) != 0)
        throw FileSystemException('chmod failed', path);
    } finally {
      malloc.free(ptr);
    }
  }

  static LocalOwner acquire(String databasePath) {
    final file = File(databasePath).absolute;
    file.parent.createSync(recursive: true);
    final canonical = file.existsSync()
        ? file.resolveSymbolicLinksSync()
        : '${file.parent.resolveSymbolicLinksSync()}/${file.uri.pathSegments.last}';
    final ptr = canonical.toNativeUtf8();
    final int fd;
    try {
      fd = _open(ptr, 2 | 64 | 131072 | 524288, 384);
    } finally {
      malloc.free(ptr);
    }
    if (fd < 0)
      throw FileSystemException('Cannot open ownership lock', canonical);
    if (_flock(fd, 2 | 4) != 0) {
      _close(fd);
      throw StateError('Database already owned: $canonical');
    }
    return LocalOwner._(fd, canonical);
  }

  void close() {
    _flock(fd, 8);
    _close(fd);
  }
}
