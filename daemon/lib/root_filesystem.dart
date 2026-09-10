import 'dart:io' as io;
import 'dart:convert';
import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:cadence_media/src/filesystem.dart' show LocalMediaFiles;
import 'root_access.dart';

/// A host filesystem whose removable subtrees remain pinned to their mounts.
/// Mapped entities retain their own lease scope; replacing observations cannot
/// retarget an in-flight file object. The owner drains users before closing leases.
class RootFileSystem extends ForwardingFileSystem implements LocalMediaFiles {
  RootFileSystem(super.delegate);
  final Map<String, RootLease> leases = {};
  @override
  bool get isWatchSupported => false;
  _Scope? scope(dynamic value) {
    final name = path.normalize(path.absolute(getPath(value)));
    final matches =
        leases.keys
            .where((root) => root == name || path.isWithin(root, name))
            .toList()
          ..sort((a, b) => b.length.compareTo(a.length));
    return matches.isEmpty ? null : _Scope(this, leases[matches.first]!);
  }

  @override
  File file(dynamic value) {
    final scoped = scope(value);
    return scoped == null
        ? delegate.file(value)
        : _File(
            scoped,
            scoped.lease.fileSystem.file(scoped.relative(getPath(value))),
          );
  }

  @override
  Directory directory(dynamic value) {
    final scoped = scope(value);
    return scoped == null
        ? delegate.directory(value)
        : _Directory(
            scoped,
            scoped.lease.fileSystem.directory(scoped.relative(getPath(value))),
          );
  }

  @override
  Link link(dynamic value) {
    final scoped = scope(value);
    return scoped == null
        ? delegate.link(value)
        : _Link(
            scoped,
            scoped.lease.fileSystem.link(scoped.relative(getPath(value))),
          );
  }

  @override
  Future<FileStat> stat(String path) => file(path).stat();
  @override
  FileStat statSync(String path) => file(path).statSync();
  @override
  Future<FileSystemEntityType> type(
    String path, {
    bool followLinks = true,
  }) async => typeSync(path, followLinks: followLinks);
  @override
  FileSystemEntityType typeSync(String path, {bool followLinks = true}) {
    final scoped = scope(path);
    return scoped == null
        ? delegate.typeSync(path, followLinks: followLinks)
        : scoped.lease.fileSystem.typeSync(
            scoped.relative(path),
            followLinks: followLinks,
          );
  }

  @override
  Future<bool> identical(String first, String second) async =>
      identicalSync(first, second);
  @override
  bool identicalSync(String first, String second) {
    final a = scope(first), b = scope(second);
    if (a == null && b == null) return delegate.identicalSync(first, second);
    if (a == null || b == null || a.lease != b.lease) return false;
    return a.lease.fileSystem.identicalSync(
      a.relative(first),
      b.relative(second),
    );
  }

  @override
  String localMediaPath(String path) {
    final scoped = scope(path);
    if (scoped == null) {
      if (delegate is LocalMediaFiles)
        return (delegate as LocalMediaFiles).localMediaPath(path);
      if (delegate is! LocalFileSystem)
        throw UnsupportedError('No local-file capability for host filesystem');
      return delegate.file(path).absolute.path;
    }
    final fs = scoped.lease.fileSystem;
    if (fs is! LocalMediaFiles)
      throw UnsupportedError('No native-file capability for this root');
    return (fs as LocalMediaFiles).localMediaPath(scoped.relative(path));
  }
}

class _Scope {
  _Scope(this.fs, this.lease);
  final RootFileSystem fs;
  final RootLease lease;
  String relative(String path) =>
      '/${fs.path.relative(fs.path.absolute(path), from: lease.mountPath)}';
  String logical(String path) => fs.path.normalize(
    fs.path.join(
      lease.mountPath,
      lease.fileSystem.path.relative(path, from: '/'),
    ),
  );
  Never readOnly() => throw FileSystemException(
    'Removable media roots are read-only',
    lease.mountPath,
  );
}

abstract class _Entity<
  T extends FileSystemEntity,
  D extends io.FileSystemEntity
>
    extends ForwardingFileSystemEntity<T, D> {
  _Entity(this.scope, this.delegate);
  final _Scope scope;
  @override
  final D delegate;
  @override
  FileSystem get fileSystem => scope.fs;
  @override
  String get path => scope.logical(delegate.path);
  @override
  Uri get uri => Uri.file(path);
  @override
  Directory wrapDirectory(io.Directory value) => _Directory(scope, value);
  @override
  File wrapFile(io.File value) => _File(scope, value);
  @override
  Link wrapLink(io.Link value) => _Link(scope, value);
  @override
  Future<String> resolveSymbolicLinks() async =>
      scope.logical(await delegate.resolveSymbolicLinks());
  @override
  String resolveSymbolicLinksSync() =>
      scope.logical(delegate.resolveSymbolicLinksSync());
  @override
  Future<T> rename(String path) async => scope.readOnly();
  @override
  T renameSync(String path) => scope.readOnly();
  @override
  Future<T> delete({bool recursive = false}) async => scope.readOnly();
  @override
  void deleteSync({bool recursive = false}) => scope.readOnly();
}

class _File extends _Entity<File, io.File> with ForwardingFile {
  _File(super.scope, super.delegate);
  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async =>
      scope.readOnly();
  @override
  void createSync({bool recursive = false, bool exclusive = false}) =>
      scope.readOnly();
  @override
  Future<File> copy(String path) async => scope.readOnly();
  @override
  File copySync(String path) => scope.readOnly();
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) {
    if (mode != FileMode.read) scope.readOnly();
    return super.open(mode: mode);
  }

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) {
    if (mode != FileMode.read) scope.readOnly();
    return super.openSync(mode: mode);
  }

  @override
  IOSink openWrite({
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
  }) => scope.readOnly();
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async => scope.readOnly();
  @override
  void writeAsBytesSync(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => scope.readOnly();
  @override
  Future<File> writeAsString(
    String text, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async => scope.readOnly();
  @override
  void writeAsStringSync(
    String text, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => scope.readOnly();
  @override
  Future<void> setLastAccessed(DateTime time) async => scope.readOnly();
  @override
  void setLastAccessedSync(DateTime time) => scope.readOnly();
  @override
  Future<void> setLastModified(DateTime time) async => scope.readOnly();
  @override
  void setLastModifiedSync(DateTime time) => scope.readOnly();
}

class _Directory extends _Entity<Directory, io.Directory>
    with ForwardingDirectory<Directory> {
  _Directory(super.scope, super.delegate);
  @override
  Directory childDirectory(String basename) => wrapDirectory(
    scope.lease.fileSystem.directory(
      scope.lease.fileSystem.path.join(delegate.path, basename),
    ),
  );
  @override
  File childFile(String basename) => wrapFile(
    scope.lease.fileSystem.file(
      scope.lease.fileSystem.path.join(delegate.path, basename),
    ),
  );
  @override
  Link childLink(String basename) => wrapLink(
    scope.lease.fileSystem.link(
      scope.lease.fileSystem.path.join(delegate.path, basename),
    ),
  );
  @override
  Future<Directory> create({bool recursive = false}) async => scope.readOnly();
  @override
  void createSync({bool recursive = false}) => scope.readOnly();
  @override
  Future<Directory> createTemp([String? prefix]) async => scope.readOnly();
  @override
  Directory createTempSync([String? prefix]) => scope.readOnly();
}

class _Link extends _Entity<Link, io.Link> with ForwardingLink {
  _Link(super.scope, super.delegate);
  @override
  Future<Link> create(String target, {bool recursive = false}) async =>
      scope.readOnly();
  @override
  void createSync(String target, {bool recursive = false}) => scope.readOnly();
  @override
  Future<Link> update(String target) async => scope.readOnly();
  @override
  void updateSync(String target) => scope.readOnly();
}
