import 'dart:ffi';
import 'dart:io' as io;
import 'package:ffi/ffi.dart';
import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:file/chroot.dart';
import 'volume.dart';
import 'package:cadence_media/src/filesystem.dart' show LocalMediaFiles;

/// Linux mount lease. Directory descriptors pin the actual mount even after a
/// lazy unmount; subsequent opens cannot fall through to the mount directory.
/// Requires an existing mountpoint, never creates one. No subprocess required.
class LinuxVolumeAttachment implements VolumeAttachment, LocalPlaybackVolume {
  LinuxVolumeAttachment._(
    this._rootFd,
    this._metadataFd,
    this._lockFd,
    this.mountPath,
    this.mountId,
  ) : fileSystem = _LinuxVolumeFileSystem('/proc/self/fd/$_rootFd');
  final int _rootFd, _metadataFd, _lockFd;
  final String mountPath, mountId;
  bool _released = false;
  @override
  final FileSystem fileSystem;
  static final _libc = DynamicLibrary.open('libc.so.6');
  static final _open = _libc
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32, Uint32),
        int Function(Pointer<Utf8>, int, int)
      >('open');
  static final _openat = _libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Int32, Uint32),
        int Function(int, Pointer<Utf8>, int, int)
      >('openat');
  static final _mkdirat = _libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Uint32),
        int Function(int, Pointer<Utf8>, int)
      >('mkdirat');
  static final _close = _libc
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  static final _fsync = _libc
      .lookupFunction<Int32 Function(Int32), int Function(int)>('fsync');
  static final _syncfs = _libc
      .lookupFunction<Int32 Function(Int32), int Function(int)>('syncfs');
  static final _flock = _libc
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'flock',
      );
  static const _directory =
      65536 | 131072 | 524288; // DIRECTORY|NOFOLLOW|CLOEXEC
  static T _string<T>(String value, T Function(Pointer<Utf8>) action) {
    final ptr = value.toNativeUtf8();
    try {
      return action(ptr);
    } finally {
      malloc.free(ptr);
    }
  }

  static String _unescape(String value) => value.replaceAllMapped(
    RegExp(r'\\([0-7]{3})'),
    (m) => String.fromCharCode(int.parse(m[1]!, radix: 8)),
  );
  static bool _mounted(String path, String id) =>
      io.File('/proc/self/mountinfo').readAsLinesSync().any((line) {
        final fields = line.split(' ');
        return fields.length > 5 &&
            fields[0] == id &&
            _unescape(fields[4]) == path;
      });
  static LinuxVolumeAttachment acquire(String path, {bool initialize = false}) {
    if (!io.Platform.isLinux)
      throw UnsupportedError('Linux mount adapter required');
    final canonical = io.Directory(path).resolveSymbolicLinksSync();
    final root = _string(canonical, (p) => _open(p, _directory, 0));
    if (root < 0) throw io.FileSystemException('Cannot acquire volume', path);
    var metadata = -1, lock = -1;
    try {
      final info = io.File('/proc/self/fdinfo/$root').readAsLinesSync();
      final id = info
          .firstWhere((l) => l.startsWith('mnt_id:'))
          .split(':')
          .last
          .trim();
      if (!_mounted(canonical, id))
        throw StateError('Volume path must be an attached mountpoint');
      if (initialize) {
        _string('.cadence', (p) => _mkdirat(root, p, 448));
        if (_fsync(root) != 0) throw StateError('Cannot sync volume directory');
      }
      metadata = _string('.cadence', (p) => _openat(root, p, _directory, 0));
      if (metadata < 0)
        throw StateError('Missing or unsafe .cadence directory');
      lock = _string(
        'library.sqlite',
        (p) => _openat(
          metadata,
          p,
          2 | (initialize ? 64 : 0) | 131072 | 524288,
          384,
        ),
      );
      if (lock < 0 || _flock(lock, 2 | 4) != 0)
        throw StateError('Volume already owned or cannot be locked');
      if (!_mounted(canonical, id))
        throw StateError('Volume detached during attachment');
      return LinuxVolumeAttachment._(root, metadata, lock, canonical, id);
    } catch (_) {
      if (lock >= 0) _close(lock);
      if (metadata >= 0) _close(metadata);
      _close(root);
      rethrow;
    }
  }

  @override
  bool get isAttached {
    if (_released) return false;
    try {
      if (!_mounted(mountPath, mountId)) return false;
      final current = _string(mountPath, (p) => _open(p, _directory, 0));
      if (current < 0) return false;
      try {
        return io.File('/proc/self/fdinfo/$current')
                .readAsLinesSync()
                .firstWhere((l) => l.startsWith('mnt_id:'))
                .split(':')
                .last
                .trim() ==
            mountId;
      } finally {
        _close(current);
      }
    } catch (_) {
      return false;
    }
  }

  @override
  String playbackPath(String volumePath) {
    if (!isAttached) throw StateError('Volume detached');
    final path = (fileSystem as LocalMediaFiles).localMediaPath(volumePath);
    return path.replaceFirst('/proc/self/', '/proc/${io.pid}/');
  }

  @override
  void syncDirectory() {
    if (_released || _fsync(_metadataFd) != 0 || _fsync(_rootFd) != 0)
      throw io.FileSystemException('Cannot sync volume');
  }

  @override
  void flush() {
    syncDirectory();
    if (_syncfs(_rootFd) != 0)
      throw io.FileSystemException('Cannot flush volume writes');
  }

  @override
  void release() {
    if (_released) return;
    _released = true;
    _close(_lockFd);
    _close(_metadataFd);
    _close(_rootFd);
  }
}

class _LinuxVolumeFileSystem extends ChrootFileSystem
    implements LocalMediaFiles {
  _LinuxVolumeFileSystem(String root) : super(const LocalFileSystem(), root);
  @override
  String localMediaPath(String path) {
    final resolved = file(path).resolveSymbolicLinksSync();
    return delegate.path.join(root, this.path.relative(resolved, from: '/'));
  }
}
