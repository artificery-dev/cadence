import 'package:cadence_client/cadence_client.dart';
import 'package:cadence_media/src/filesystem.dart' show LocalMediaFiles;
import 'package:file/file.dart';
import 'package:file/chroot.dart';
import 'package:file/memory.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'root_access.dart';
import 'root_filesystem.dart';
import 'volume.dart';
import 'volume_vfs.dart';

typedef AcquireMediaRoot =
    RootLease Function(String root, String? mountPath, String? mountId);

/// One declared media base, independent of where /.cadence is stored. The host
/// observes real mounts, while scanners and clients see paths beneath virtual
/// `/`. Before an observation, that filesystem is empty and no job may run.
/// Metadata/cache always use the separately retained metadata attachment.
class DeclaredMediaStore
    implements
        RelativeMediaStoreAttachment,
        RootAccessAdapter,
        LocalPlaybackVolume {
  DeclaredMediaStore({
    required this.metadata,
    required this.metadataRoot,
    String? declaredMediaRoot,
    String? mediaMount,
    required this.acquireMediaRoot,
    required this.playerPath,
  }) : _requestedRoot = declaredMediaRoot,
       _requestedMount = mediaMount,
       fileSystem = RootFileSystem(MemoryFileSystem()) {
    _vfs = VolumeVfs(
      metadata.fileSystem,
      name: 'declared-store-${_sequence++}',
      syncDirectory: metadata.syncDirectory,
    );
    sql.sqlite3.registerVirtualFileSystem(_vfs);
  }
  static int _sequence = 0;
  final VolumeAttachment metadata;
  final String metadataRoot;
  final String? _requestedRoot, _requestedMount;
  @override
  late final String declaredMediaRoot;
  @override
  late final String resolvedMediaRoot;
  @override
  late final String? mediaMount;
  String? _mountDeclaration;
  final AcquireMediaRoot acquireMediaRoot;
  final String Function(String path) playerPath;
  late final VolumeVfs _vfs;
  bool _closed = false;
  List<RootObservation> _roots = [];
  @override
  final RootFileSystem fileSystem;
  @override
  FileSystem get cacheFileSystem => metadata.fileSystem;
  @override
  String get cacheDirectory => '/.cadence/cache';
  @override
  bool get removableMetadata =>
      metadata is! RootedStoreAttachment ||
      (metadata as RootedStoreAttachment).removable;
  @override
  bool get databaseExists =>
      metadata.fileSystem.file('/.cadence/library.sqlite').existsSync() &&
      metadata.fileSystem.file('/.cadence/library.sqlite').lengthSync() > 0;
  @override
  bool get isAttached => !_closed && metadata.isAttached;

  @override
  sql.Database openDatabase() {
    final db = sql.sqlite3.open('/.cadence/library.sqlite', vfs: _vfs.name);
    try {
      final hasIdentity = db
          .select("SELECT name FROM sqlite_master WHERE name='cadence_volume'")
          .isNotEmpty;
      final hasConfig = db
          .select(
            "SELECT name FROM sqlite_master WHERE name='cadence_media_base'",
          )
          .isNotEmpty;
      if (hasIdentity && !hasConfig)
        throw MediaError(
          'unsupported_datastore_format',
          'Declared media-base configuration is required; no automatic adoption',
          409,
        );
      if (hasConfig) {
        if (!db
            .select('PRAGMA table_info(cadence_media_base)')
            .any((r) => r['name'] == 'mount'))
          throw MediaError(
            'unsupported_datastore_format',
            'Current declared media-base configuration is required',
            409,
          );
        final rows = db.select('SELECT root,mount FROM cadence_media_base');
        if (rows.length != 1 ||
            (_requestedRoot != null && rows.single['root'] != _requestedRoot))
          throw MediaError(
            'media_root_mismatch',
            'Persisted media root differs; it cannot be retargeted at startup',
            409,
          );
        declaredMediaRoot = rows.single['root'] as String;
        _mountDeclaration = rows.single['mount'] as String?;
      } else {
        if (_requestedRoot == null)
          throw MediaError(
            'media_root_required',
            'New stores require an explicit declared media root',
            400,
          );
        declaredMediaRoot = _requestedRoot;
        _mountDeclaration = _requestedMount == metadataRoot
            ? '.'
            : _requestedMount;
      }
      final context = metadata.fileSystem.path;
      resolvedMediaRoot = declaredMediaRoot == '.'
          ? metadataRoot
          : declaredMediaRoot;
      mediaMount = _mountDeclaration == '.' ? metadataRoot : _mountDeclaration;
      if (!context.isAbsolute(resolvedMediaRoot) ||
          context.normalize(resolvedMediaRoot) != resolvedMediaRoot ||
          (mediaMount != null &&
              (!context.isAbsolute(mediaMount!) ||
                  context.normalize(mediaMount!) != mediaMount ||
                  !(mediaMount == resolvedMediaRoot ||
                      context.isWithin(mediaMount!, resolvedMediaRoot)))))
        throw MediaError(
          'invalid_media_base',
          'Invalid persisted media base or mount',
          409,
        );
      if (_requestedMount != null && _requestedMount != mediaMount)
        throw MediaError(
          'media_mount_mismatch',
          'Persisted media mount differs; it cannot be retargeted at startup',
          409,
        );
      // New databases are initialized by ManagedLibraryHost. Write configuration
      // only after identity initialization through initializeConfiguration().
      return db;
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  @override
  void initializeConfiguration(sql.Database db) {
    db.execute(
      'CREATE TABLE IF NOT EXISTS cadence_media_base (root TEXT NOT NULL, mount TEXT)',
    );
    if (db.select('SELECT root FROM cadence_media_base').isEmpty)
      db.execute('INSERT INTO cadence_media_base VALUES (?,?)', [
        declaredMediaRoot,
        _mountDeclaration,
      ]);
  }

  @override
  void configureRoots(List<RootObservation> roots) {
    final available = roots.where((r) => r.available).toList();
    RootLease? next;
    if (available.isNotEmpty) {
      if (available.any((r) => r.mountPath != mediaMount) ||
          (mediaMount != null &&
              (available.first.mountId == null ||
                  available.any(
                    (r) => r.mountId != available.first.mountId,
                  )))) {
        throw StateError('Observations must identify the declared media mount');
      }
      final lease = acquireMediaRoot(
        resolvedMediaRoot,
        mediaMount,
        available.first.mountId,
      );
      try {
        final context = lease.fileSystem.path;
        final relative = context.relative(
          resolvedMediaRoot,
          from: lease.mountPath,
        );
        if (relative == '..' || relative.startsWith('../'))
          throw StateError('Media base is outside the declared mount');
        next = _ProjectedLease(
          lease,
          relative == '.'
              ? lease.fileSystem
              : _MediaSubtree(lease.fileSystem, '/$relative'),
        );
      } catch (_) {
        lease.close();
        rethrow;
      }
    }
    for (final lease in fileSystem.leases.values) {
      lease.close();
    }
    fileSystem.leases.clear();
    if (next != null) fileSystem.leases['/'] = next;
    _roots = roots;
  }

  @override
  bool rootAvailable(String path) {
    if (fileSystem.leases['/']?.available != true) return false;
    final containing = _roots
        .where((r) => r.path == path || fileSystem.path.isWithin(r.path, path))
        .toList();
    return containing.isNotEmpty && containing.every((r) => r.available);
  }

  @override
  String playbackPath(String path) {
    if (!rootAvailable(path)) throw StateError('Media root unavailable');
    return playerPath(fileSystem.localMediaPath(path));
  }

  @override
  void syncDirectory() => metadata.syncDirectory();
  @override
  void flush() => metadata.flush();
  @override
  void release() {
    if (_closed) return;
    _closed = true;
    for (final lease in fileSystem.leases.values) {
      lease.close();
    }
    fileSystem.leases.clear();
    sql.sqlite3.unregisterVirtualFileSystem(_vfs);
    metadata.release();
  }
}

class _ProjectedLease implements RootLease {
  _ProjectedLease(this.delegate, this.fileSystem);
  final RootLease delegate;
  @override
  final FileSystem fileSystem;
  @override
  String get mountPath => '/';
  @override
  bool get available => delegate.available;
  @override
  void close() => delegate.close();
}

class _MediaSubtree extends ChrootFileSystem implements LocalMediaFiles {
  _MediaSubtree(super.delegate, super.root);
  @override
  String localMediaPath(String path) {
    if (delegate is! LocalMediaFiles)
      throw UnsupportedError('Media base has no native path capability');
    final resolved = file(path).resolveSymbolicLinksSync();
    return (delegate as LocalMediaFiles).localMediaPath(
      delegate.path.join(root, this.path.relative(resolved, from: '/')),
    );
  }
}
