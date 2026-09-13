import 'dart:convert';
import 'dart:typed_data';

import '../database/database.dart';
import '../kinds.dart';
import '../metadata.dart';
import '../repositories/library_repository.dart';
import '../repositories/settings_store.dart';
import '../scan/scan_jobs.dart';
import '../scan/scanner.dart';
import '../tags.dart';
import 'media_service.dart';
import 'protocol.dart';

/// Carries one request map to the service and brings the response map
/// back. The isolate transport speaks over ports; the direct transport
/// calls the service in-process — same envelopes either way.
typedef ServiceTransport =
    Future<Map<String, Object?>> Function(Map<String, Object?> request);

/// What a scan attempt came back with.
class ScanOutcome {
  const ScanOutcome({required this.status, required this.message});

  final int status;
  final String message;

  bool get accepted => status >= 200 && status < 300;
}

/// One picture off the wire: what it is, what it's encoded as, and the
/// bytes themselves.
class ArtworkBytes {
  const ArtworkBytes({
    required this.role,
    required this.mime,
    required this.bytes,
  });

  final ArtworkRole role;
  final String mime;
  final Uint8List bytes;
}

/// One reading of a library's scan, as the status route tells it: the
/// state, the counters, the first fifty failures, and the clock. A library
/// never scanned reads as [ScanState.idle] with everything else at rest.
class ScanStatus {
  const ScanStatus({
    required this.state,
    this.seen = 0,
    this.changed = 0,
    this.discovered = 0,
    this.enriched = 0,
    this.added = 0,
    this.updated = 0,
    this.moved = 0,
    this.missing = 0,
    this.sidecars = 0,
    this.artwork = 0,
    this.skipped = 0,
    this.errorCount = 0,
    this.errors = const [],
    this.startedAt,
    this.finishedAt,
    this.elapsed = Duration.zero,
  });

  factory ScanStatus.fromJson(Map<String, Object?> json) => ScanStatus(
    state: ScanState.values.byName(json['state'] as String),
    seen: json['seen'] as int? ?? 0,
    changed: json['changed'] as int? ?? 0,
    discovered: json['discovered'] as int? ?? 0,
    enriched: json['enriched'] as int? ?? 0,
    added: json['added'] as int? ?? 0,
    updated: json['updated'] as int? ?? 0,
    moved: json['moved'] as int? ?? 0,
    missing: json['missing'] as int? ?? 0,
    sidecars: json['sidecars'] as int? ?? 0,
    artwork: json['artwork'] as int? ?? 0,
    skipped: json['skipped'] as int? ?? 0,
    errorCount: json['errorCount'] as int? ?? 0,
    errors: [
      for (final error in (json['errors'] as List?) ?? const [])
        ScanError(
          (error as Map)['path'] as String? ?? '',
          error['message'] as String? ?? '',
        ),
    ],
    startedAt: switch (json['startedAt']) {
      final String at => DateTime.parse(at),
      _ => null,
    },
    finishedAt: switch (json['finishedAt']) {
      final String at => DateTime.parse(at),
      _ => null,
    },
    elapsed: Duration(milliseconds: json['elapsedMs'] as int? ?? 0),
  );

  final ScanState state;
  final int seen;

  /// Files the diff found new or changed - what the scan is working
  /// through, and what [added] plus [updated] climb towards. Zero means
  /// the library was already up to date.
  final int changed;
  final int discovered;
  final int enriched;
  final int added;
  final int updated;
  final int moved;
  final int missing;
  final int sidecars;
  final int artwork;
  final int skipped;

  /// Every failure counted, even past the wire's fifty-error cap.
  final int errorCount;

  /// The first fifty failures, path and message.
  final List<ScanError> errors;

  final DateTime? startedAt;
  final DateTime? finishedAt;

  /// How long the scan has been at it — or took, once finished.
  final Duration elapsed;

  /// Whether the scan is still in motion — poll again when so.
  bool get running => state.running;
}

/// The app's hand on the media service: typed methods over the HTTP-shaped
/// protocol. The transport is injected — an isolate today, a socket
/// someday, the service directly in tests.
class MediaClient {
  MediaClient(this._transport, {Future<void> Function()? onClose})
    // ignore: prefer_initializing_formals
    : _onClose = onClose;

  /// The service in-process, envelopes and all — the seam without the
  /// isolate, for tests and tools. Bring a [service] to choose its wiring
  /// (a gated scanner, a watched watcher); left out, one is built plain.
  factory MediaClient.direct(MediaDatabase db, {MediaService? service}) {
    final served = service ?? MediaService(db);
    return MediaClient(
      (request) async =>
          (await served.handle(ServiceRequest.fromMap(request))).toMap(),
      onClose: served.close,
    );
  }

  final ServiceTransport _transport;
  final Future<void> Function()? _onClose;
  int _nextId = 0;

  Future<void> close() async => _onClose?.call();

  Future<ServiceResponse> send(
    ServiceMethod method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    final request = ServiceRequest(
      id: _nextId++,
      method: method,
      path: path,
      body: body,
    );
    final response = ServiceResponse.fromMap(await _transport(request.toMap()));
    assert(response.id == request.id, 'response out of order');
    return response;
  }

  Future<ServiceResponse> _expectOk(
    ServiceMethod method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    final response = await send(method, path, body);
    if (!response.ok) {
      throw StateError(
        '${method.name} $path → ${response.status}: ${response.body}',
      );
    }
    return response;
  }

  // --- Libraries ---

  Future<List<LibraryRow>> listLibraries() async {
    final response = await _expectOk(ServiceMethod.get, '/libraries');
    return [
      for (final json in (response.body['libraries'] as List))
        _libraryRow((json as Map).cast<String, Object?>()),
    ];
  }

  Future<int> createLibrary(String name, LibraryType type) async =>
      (await _expectOk(ServiceMethod.post, '/libraries', {
            'name': name,
            'type': type.name,
          })).body['id']
          as int;

  Future<void> renameLibrary(int libraryId, String name) =>
      _expectOk(ServiceMethod.put, '/libraries/$libraryId', {'name': name});

  Future<void> deleteLibrary(int libraryId) =>
      _expectOk(ServiceMethod.delete, '/libraries/$libraryId');

  Future<List<MediaItem>> mediaItems(int libraryId) async {
    final response = await _expectOk(
      ServiceMethod.get,
      '/libraries/$libraryId/items',
    );
    return [
      for (final json in (response.body['items'] as List))
        _mediaItem((json as Map).cast<String, Object?>()),
    ];
  }

  Future<List<AudioItem>> audioItems(int libraryId) async {
    final response = await _expectOk(
      ServiceMethod.get,
      '/libraries/$libraryId/items?kind=audio',
    );
    return [
      for (final json in (response.body['items'] as List))
        _audioItem((json as Map).cast<String, Object?>()),
    ];
  }

  /// The library's tracks, compact: what a list shows and a shelf sorts
  /// by, one small row per track — the shape to ask for when there are
  /// thousands. [audioItems] is the whole item, for one at a time.
  Future<List<TrackSummary>> tracks(int libraryId) async {
    final response = await _expectOk(
      ServiceMethod.get,
      '/libraries/$libraryId/tracks',
    );
    return [
      for (final json in (response.body['tracks'] as List))
        TrackSummary.fromJson((json as Map).cast<String, Object?>()),
    ];
  }

  Future<int> addItem({
    required int libraryId,
    required String path,
    required int sizeBytes,
    required DateTime modifiedAt,
    required MediaMetadata metadata,
    Map<HashKind, String> hashes = const {},
    List<Tag> tags = const [],
    String? notes,
  }) async =>
      (await _expectOk(ServiceMethod.post, '/libraries/$libraryId/items', {
            'path': path,
            'sizeBytes': sizeBytes,
            'modifiedAt': modifiedAt.toIso8601String(),
            'kind': metadata.kind.name,
            'metadata': metadata.toJson(),
            'hashes': {
              for (final MapEntry(:key, :value) in hashes.entries)
                key.name: value,
            },
            'tags': [for (final tag in tags) tag.canonical],
            'notes': ?notes,
          })).body['id']
          as int;

  /// How fast the library may read, in bytes a second; null for no limit.
  Future<int?> scanBudget() async =>
      (await _expectOk(
            ServiceMethod.get,
            '/scan/budget',
          )).body['bytesPerSecond']
          as int?;

  /// Paces every read the library does at [bytesPerSecond]; null or zero
  /// lifts the pace. Answers what the service settled on.
  Future<int?> setScanBudget(int? bytesPerSecond) async =>
      (await _expectOk(ServiceMethod.put, '/scan/budget', {
            'bytesPerSecond': bytesPerSecond,
          })).body['bytesPerSecond']
          as int?;

  /// Asks for a scan without insisting: 202 and the opening state when the
  /// scanner takes the job, 409 when one is already running, 404 when the
  /// library is not — either way the answer comes back for the caller to
  /// show, and [scanStatus] follows the work from there.
  Future<ScanOutcome> scan(int libraryId) async {
    final response = await send(
      ServiceMethod.post,
      '/libraries/$libraryId/scan',
    );
    return ScanOutcome(
      status: response.status,
      message:
          response.body['error'] as String? ??
          response.body['state'] as String? ??
          '',
    );
  }

  // --- Roots & scanning ---

  /// The directories the library claims, oldest claim first.
  Future<List<LibraryRootRow>> listRoots(int libraryId) async {
    final response = await _expectOk(
      ServiceMethod.get,
      '/libraries/$libraryId/roots',
    );
    return [
      for (final json in (response.body['roots'] as List))
        _rootRow(libraryId, (json as Map).cast<String, Object?>()),
    ];
  }

  /// Claims [path] for the library and returns the new root's id.
  Future<int> addRoot(int libraryId, String path) async =>
      (await _expectOk(ServiceMethod.post, '/libraries/$libraryId/roots', {
            'path': path,
          })).body['id']
          as int;

  /// Releases a root, answering whether one was actually there to release.
  /// Files and items remain; the next scan decides what fell outside.
  Future<bool> removeRoot(int libraryId, int rootId) async {
    final response = await send(
      ServiceMethod.delete,
      '/libraries/$libraryId/roots/$rootId',
    );
    if (response.status == 404) return false;
    if (!response.ok) {
      throw StateError('removeRoot → ${response.status}: ${response.body}');
    }
    return true;
  }

  /// Where the library's scan stands — live counters while it runs, the
  /// final tally after, [ScanState.idle] when none ever ran.
  Future<ScanStatus> scanStatus(int libraryId) async => ScanStatus.fromJson(
    (await _expectOk(ServiceMethod.get, '/libraries/$libraryId/scan')).body,
  );

  /// Asks a running scan to stop. Idempotent, and honest: true only when
  /// there was something to stop.
  Future<bool> cancelScan(int libraryId) async =>
      (await _expectOk(
            ServiceMethod.delete,
            '/libraries/$libraryId/scan',
          )).body['cancelled']
          as bool;

  /// Scans every library, one after another, and returns the ids queued —
  /// poll [scanStatus] per library to watch the queue drain.
  Future<List<int>> scanAll() async =>
      ((await _expectOk(ServiceMethod.post, '/scan')).body['queued'] as List)
          .cast<int>();

  // --- Collections ---

  Future<List<CollectionRow>> listCollections() async {
    final response = await _expectOk(ServiceMethod.get, '/collections');
    return [
      for (final json in (response.body['collections'] as List))
        _collectionRow((json as Map).cast<String, Object?>()),
    ];
  }

  Future<int> createCollection(String name) async =>
      (await _expectOk(ServiceMethod.post, '/collections', {
            'name': name,
          })).body['id']
          as int;

  Future<List<int>> collectionEntries(int collectionId) async =>
      ((await _expectOk(
                ServiceMethod.get,
                '/collections/$collectionId/entries',
              )).body['items']
              as List)
          .cast<int>();

  Future<void> setCollectionEntries(int collectionId, List<int> itemIds) =>
      _expectOk(ServiceMethod.put, '/collections/$collectionId/entries', {
        'items': itemIds,
      });

  // --- Settings ---

  Future<T> getSetting<T>(SettingDef<T> def) async {
    final response = await send(ServiceMethod.get, '/settings/${def.key}');
    if (response.status == 404) return def.fallback;
    if (!response.ok) throw StateError('settings → ${response.status}');
    return def.decode(jsonDecode(response.body['value'] as String));
  }

  Future<void> setSetting<T>(SettingDef<T> def, T value) => _expectOk(
    ServiceMethod.put,
    '/settings/${def.key}',
    {'value': jsonEncode(def.encode(value))},
  );

  // --- Artwork ---

  /// The best picture on file, or null when the file sits bare. [role]
  /// narrows the ask; left alone, the service tries thumbnail, embedded,
  /// then folder art.
  Future<ArtworkBytes?> artwork(int fileId, {ArtworkRole? role}) async {
    final response = await send(
      ServiceMethod.get,
      role == null
          ? '/files/$fileId/artwork'
          : '/files/$fileId/artwork?role=${role.name}',
    );
    if (response.status == 404) return null;
    if (!response.ok) {
      throw StateError('artwork $fileId → ${response.status}');
    }
    return ArtworkBytes(
      role: ArtworkRole.values.byName(response.body['role'] as String),
      mime: response.body['mime'] as String,
      bytes: base64Decode(response.body['bytesBase64'] as String),
    );
  }

  /// Put [fileIds] at the front of the artwork queue - the rows about to
  /// be drawn - without waiting for any of them. Nothing happens on a
  /// service whose scans render their own pictures.
  Future<void> prefetchArtwork(List<int> fileIds) =>
      _expectOk(ServiceMethod.post, '/artwork/prefetch', {'fileIds': fileIds});

  /// Where the artwork queue stands: pending, running, rendered, bare.
  Future<Map<String, Object?>> artworkQueue() async =>
      (await _expectOk(ServiceMethod.get, '/artwork/queue')).body;

  // --- Search, plays, progress ---

  Future<List<int>> search(String query) async =>
      ((await _expectOk(
                ServiceMethod.get,
                Uri(path: '/search', queryParameters: {'q': query}).toString(),
              )).body['items']
              as List)
          .cast<int>();

  Future<void> recordPlay(int itemId, {bool completed = false}) => _expectOk(
    ServiceMethod.post,
    '/plays',
    {'itemId': itemId, 'completed': completed},
  );

  Future<void> setProgress(int itemId, Duration position) => _expectOk(
    ServiceMethod.put,
    '/progress/$itemId',
    {'positionMs': position.inMilliseconds},
  );

  // --- Decoding ---

  LibraryRow _libraryRow(Map<String, Object?> json) => LibraryRow(
    id: json['id'] as int,
    name: json['name'] as String,
    type: LibraryType.values.byName(json['type'] as String),
    createdAt: DateTime.parse(json['createdAt'] as String),
  );

  LibraryRootRow _rootRow(int libraryId, Map<String, Object?> json) =>
      LibraryRootRow(
        id: json['id'] as int,
        libraryId: libraryId,
        path: json['path'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );

  CollectionRow _collectionRow(Map<String, Object?> json) => CollectionRow(
    id: json['id'] as int,
    name: json['name'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );

  MediaItem _mediaItem(Map<String, Object?> json) => MediaItem(
    id: json['id'] as int,
    fileId: json['fileId'] as int,
    path: json['path'] as String,
    metadata: MediaMetadata.fromJson(
      MediaKind.values.byName(json['kind'] as String),
      (json['metadata'] as Map).cast<String, Object?>(),
    ),
    tags: [for (final tag in (json['tags'] as List)) Tag.parse(tag as String)],
  );

  AudioItem _audioItem(Map<String, Object?> json) {
    final item = _mediaItem(json);
    return AudioItem(
      id: item.id,
      fileId: item.fileId,
      path: item.path,
      metadata: item.metadata as AudioMetadata,
      tags: item.tags,
    );
  }
}
