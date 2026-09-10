import '../filesystem.dart';
import 'dart:convert';

import '../database/database.dart';
import '../kinds.dart';
import '../metadata.dart';
import '../repositories/collections_repository.dart';
import '../repositories/library_repository.dart';
import '../repositories/play_log.dart';
import '../repositories/scanner_repository.dart';
import '../repositories/search_repository.dart';
import '../repositories/settings_store.dart';
import '../scan/artwork_jobs.dart';
import '../scan/scan_jobs.dart';
import '../watch_adapter.dart';
import '../tags.dart';
import 'protocol.dart';

/// The service proper: owns the database, routes [ServiceRequest]s to the
/// repositories, answers in JSON shapes. Where it runs is someone else's
/// business — an isolate today, a real server someday; the routes don't
/// change.
///
/// The scanner boards here too: roots CRUD, scan start/status/cancel, and
/// the folder watch, all booked through one [ScanCoordinator]. Callers may
/// bring their own coordinator and watch service (the server does, tests
/// do); left alone, the service builds the production pair itself.
class MediaService {
  MediaService(
    this.db, {
    ScanCoordinator? coordinator,
    LibraryWatchService? watch,
    this._artwork,
  }) : _libraries = LibraryRepository(db),
       _collections = CollectionsRepository(db),
       _settings = SettingsStore(db),
       _search = SearchRepository(db),
       _plays = PlayLog(db),
       _scanner = ScannerRepository(db),
       _coordinator = coordinator ?? ScanCoordinator(db) {
    _watch = watch ?? const NoLibraryWatch();
  }

  final MediaDatabase db;
  final LibraryRepository _libraries;
  final CollectionsRepository _collections;
  final SettingsStore _settings;
  final SearchRepository _search;
  final PlayLog _plays;
  final ScannerRepository _scanner;
  final ScanCoordinator _coordinator;
  late final LibraryWatchService _watch;

  /// The pictures made after the scan, when the policy defers them; null
  /// when the scan makes its own.
  final ArtworkQueue? _artwork;

  Map<String, Object?> get artworkStatus =>
      _artwork?.toJson() ?? const {'pending': 0, 'running': false};

  Future<ArtworkRow?> artwork(int fileId) async =>
      await _libraries.artworkOf(fileId) ?? await _artwork?.ensure(fileId);

  Future<void> close() async {
    try {
      await _coordinator.close();
    } finally {
      try {
        await _watch.stop();
      } finally {
        try {
          await _artwork?.close();
        } finally {
          await db.close();
        }
      }
    }
  }

  /// Makes the folder watch agree with the `scanner.watchFolders` setting —
  /// started when true, stopped when false. The settings route calls this
  /// after every write to the key; the server calls it once at boot.
  Future<void> syncWatchers() async {
    if (await _settings.get(ScannerSettings.watchFolders)) {
      await _watch.start();
    } else {
      await _watch.stop();
    }
  }

  Future<ServiceResponse> handle(ServiceRequest request) async {
    try {
      return await _route(request);
    } on ArgumentError catch (error) {
      return _reply(request, 400, {'error': '$error'});
    } on FormatException catch (error) {
      return _reply(request, 400, {'error': '$error'});
    } on TypeError catch (error) {
      return _reply(request, 400, {'error': '$error'});
    } on Object catch (error) {
      return _reply(request, 500, {'error': '$error'});
    }
  }

  ServiceResponse _reply(
    ServiceRequest request,
    int status, [
    Map<String, Object?> body = const {},
  ]) => ServiceResponse(id: request.id, status: status, body: body);

  Future<ServiceResponse> _route(ServiceRequest r) async {
    final uri = Uri.parse(r.path);
    final parts = uri.pathSegments;
    final m = r.method;

    return switch ((m, parts)) {
      (ServiceMethod.get, ['libraries']) => _reply(r, 200, {
        'libraries': [
          for (final row in await _libraries.listLibraries())
            await _libraryJson(row),
        ],
      }),
      (ServiceMethod.post, ['libraries']) => () async {
        final id = await _libraries.createLibrary(
          r.body!['name'] as String,
          LibraryType.values.byName(
            r.body!['type'] == 'videos' ? 'movies' : r.body!['type'] as String,
          ),
        );
        return _reply(r, 201, {'id': id, 'uuid': await _libraries.uuidOf(id)});
      }(),
      (ServiceMethod.put, ['libraries', final id]) => () async {
        await _libraries.renameLibrary(
          int.parse(id),
          r.body!['name'] as String,
        );
        return _reply(r, 200);
      }(),
      (ServiceMethod.delete, ['libraries', final id]) => () async {
        await _libraries.deleteLibrary(int.parse(id));
        // The library's roots died with it; a running watch lets them go.
        await _watch.refresh();
        return _reply(r, 200);
      }(),
      (ServiceMethod.get, ['libraries', final id, 'items']) => _reply(r, 200, {
        'items': [
          for (final item in await _itemsOf(
            int.parse(id),
            kind: uri.queryParameters['kind'],
          ))
            _itemJson(item),
        ],
      }),
      (ServiceMethod.post, ['libraries', final id, 'items']) => _reply(r, 201, {
        'id': await _addItem(int.parse(id), r.body!),
      }),
      (ServiceMethod.get, ['libraries', final id, 'tracks']) => _reply(r, 200, {
        'tracks': [
          for (final track in await _libraries.trackSummaries(int.parse(id)))
            track.toJson(),
        ],
      }),
      (ServiceMethod.get, ['libraries', final id, 'roots']) => _reply(r, 200, {
        'roots': [
          for (final root in await _scanner.rootsOf(int.parse(id)))
            {
              'id': root.id,
              'path': root.path,
              'createdAt': root.createdAt.toIso8601String(),
            },
        ],
      }),
      (ServiceMethod.post, ['libraries', final id, 'roots']) => _addRoot(
        r,
        int.parse(id),
      ),
      (ServiceMethod.delete, ['libraries', _, 'roots', final rootId]) =>
        () async {
          if (!await _scanner.removeRoot(int.parse(rootId))) {
            return _reply(r, 404, {'error': 'No such root.'});
          }
          await _watch.refresh();
          return _reply(r, 200);
        }(),
      (ServiceMethod.post, ['libraries', final id, 'scan']) => _startScan(
        r,
        int.parse(id),
      ),
      (ServiceMethod.get, ['libraries', final id, 'scan']) => _reply(
        r,
        200,
        _coordinator.statusOf(int.parse(id)).toJson(),
      ),
      (ServiceMethod.delete, ['libraries', final id, 'scan']) => _reply(
        r,
        200,
        {'cancelled': _coordinator.cancel(int.parse(id))},
      ),
      (ServiceMethod.post, ['scan']) => _reply(r, 202, {
        'queued': await _coordinator.scanAll(),
      }),
      (ServiceMethod.get, ['collections']) => _reply(r, 200, {
        'collections': [
          for (final row in await _collections.listCollections())
            _collectionJson(row),
        ],
      }),
      (ServiceMethod.post, ['collections']) => _reply(r, 201, {
        'id': await _collections.create(r.body!['name'] as String),
      }),
      (ServiceMethod.get, ['collections', final id, 'entries']) => _reply(
        r,
        200,
        {'items': await _collections.entries(int.parse(id))},
      ),
      (ServiceMethod.put, ['collections', final id, 'entries']) => () async {
        await _collections.setEntries(
          int.parse(id),
          (r.body!['items'] as List).cast<int>(),
        );
        return _reply(r, 200);
      }(),
      (ServiceMethod.get, ['settings', final key]) => () async {
        final row = await (db.select(
          db.settings,
        )..where((s) => s.key.equals(key))).getSingleOrNull();
        return row == null
            ? _reply(r, 404)
            : _reply(r, 200, {'value': row.value});
      }(),
      (ServiceMethod.put, ['settings', final key]) => () async {
        await _settings.putRaw(key, r.body!['value'] as String);
        if (key == ScannerSettings.watchFolders.key) await syncWatchers();
        return _reply(r, 200);
      }(),
      (ServiceMethod.get, ['files', final id, 'artwork']) => () async {
        final role = uri.queryParameters['role'];
        final fileId = int.parse(id);
        var row = await _libraries.artworkOf(
          fileId,
          roles: role == null
              ? const [
                  ArtworkRole.thumbnail,
                  ArtworkRole.embedded,
                  ArtworkRole.folder,
                ]
              : [ArtworkRole.values.byName(role)],
        );
        // Nothing stored, and a queue to ask: the asker is looking at
        // the file right now, so it goes to the front and the answer
        // waits for the render (a bounded wait; `wait=0` does not).
        final queue = _artwork;
        if (row == null &&
            queue != null &&
            (role == null || role == ArtworkRole.thumbnail.name) &&
            uri.queryParameters['wait'] != '0') {
          row = await queue.ensure(fileId);
        }
        return row == null
            ? _reply(r, 404)
            : _reply(r, 200, {
                'role': row.role.name,
                'mime': row.mime,
                'bytesBase64': base64Encode(row.data),
              });
      }(),
      (ServiceMethod.get, ['artwork', 'queue']) => _reply(
        r,
        200,
        _artwork?.toJson() ?? const {'pending': 0, 'running': false},
      ),
      (ServiceMethod.post, ['artwork', 'prefetch']) => () async {
        final queue = _artwork;
        if (queue == null) return _reply(r, 200, {'pending': 0});
        queue.promote((r.body!['fileIds'] as List).cast<int>());
        return _reply(r, 200, queue.toJson());
      }(),
      (ServiceMethod.post, ['artwork', 'sweep']) => () async {
        final queue = _artwork;
        if (queue == null) return _reply(r, 200, {'added': 0});
        final library = r.body?['libraryId'] as int?;
        return _reply(r, 202, {'added': await queue.sweep(library)});
      }(),
      (ServiceMethod.get, ['search']) => _reply(r, 200, {
        'items': await _search.search(uri.queryParameters['q'] ?? ''),
      }),
      (ServiceMethod.post, ['plays']) => _reply(r, 201, {
        'id': await _plays.recordPlay(
          r.body!['itemId'] as int,
          completed: r.body!['completed'] as bool? ?? false,
        ),
      }),
      (ServiceMethod.put, ['progress', final id]) => () async {
        await _plays.setProgress(
          int.parse(id),
          Duration(milliseconds: r.body!['positionMs'] as int),
        );
        return _reply(r, 200);
      }(),
      _ => _reply(r, 404, {'error': 'No route for ${m.name} ${r.path}'}),
    };
  }

  /// Claims a directory for the library: 404 for a library nobody made,
  /// 400 for a path that is not an existing directory, 409 for ground
  /// already claimed. A running watch picks the new root up at once.
  Future<ServiceResponse> _addRoot(ServiceRequest r, int libraryId) async {
    if (!await _libraryExists(libraryId)) {
      return _reply(r, 404, {'error': 'No library $libraryId.'});
    }
    final path = mediaPath.normalize(r.body!['path'] as String);
    if (!mediaPath.isAbsolute(path)) {
      return _reply(r, 400, {'error': 'Root must be absolute'});
    }
    if (!mediaFileSystem.directory(path).existsSync()) {
      return _reply(r, 400, {'error': 'Not a directory: $path'});
    }
    try {
      final rootId = await _scanner.addRoot(libraryId, path);
      await _watch.refresh();
      return _reply(r, 201, {'id': rootId});
    } on StateError {
      return _reply(r, 409, {'error': 'Already a root: $path'});
    }
  }

  /// Books the scan and answers 202 with its opening snapshot — or 409
  /// when one is already on the floor, 404 when the library is not.
  Future<ServiceResponse> _startScan(ServiceRequest r, int libraryId) async {
    try {
      return _reply(r, 202, (await _coordinator.start(libraryId)).toJson());
    } on ArgumentError {
      return _reply(r, 404, {'error': 'No library $libraryId.'});
    } on StateError {
      return _reply(r, 409, {
        'error': 'Library $libraryId is already scanning.',
      });
    }
  }

  Future<bool> _libraryExists(int libraryId) async =>
      await (db.select(
        db.libraries,
      )..where((l) => l.id.equals(libraryId))).getSingleOrNull() !=
      null;

  Future<List<MediaItem>> _itemsOf(int libraryId, {String? kind}) async {
    final items = await _libraries.mediaItems(libraryId);
    if (kind == null) return items;
    final wanted = MediaKind.values.byName(kind);
    return [
      for (final item in items)
        if (item.metadata.kind == wanted) item,
    ];
  }

  Future<int> _addItem(int libraryId, Map<String, Object?> body) =>
      _libraries.addItem(
        libraryId: libraryId,
        path: body['path'] as String,
        sizeBytes: body['sizeBytes'] as int,
        modifiedAt: DateTime.parse(body['modifiedAt'] as String),
        metadata: MediaMetadata.fromJson(
          MediaKind.values.byName(body['kind'] as String),
          (body['metadata'] as Map).cast<String, Object?>(),
        ),
        hashes: {
          for (final MapEntry(:key, :value)
              in ((body['hashes'] as Map?) ?? const {}).entries)
            HashKind.values.byName(key as String): value as String,
        },
        tags: [
          for (final tag in (body['tags'] as List?) ?? const [])
            Tag.parse(tag as String),
        ],
        notes: body['notes'] as String?,
      );

  Future<Map<String, Object?>> _libraryJson(LibraryRow row) async => {
    'uuid': await _libraries.uuidOf(row.id),
    'id': row.id,
    'name': row.name,
    'type': row.type.name,
    'createdAt': row.createdAt.toIso8601String(),
  };

  Map<String, Object?> _collectionJson(CollectionRow row) => {
    'id': row.id,
    'name': row.name,
    'createdAt': row.createdAt.toIso8601String(),
  };

  Map<String, Object?> _itemJson(MediaItem item) => {
    'id': item.id,
    'fileId': item.fileId,
    'path': item.path,
    'kind': item.metadata.kind.name,
    'metadata': item.metadata.toJson(),
    'tags': [for (final tag in item.tags) tag.canonical],
  };
}
