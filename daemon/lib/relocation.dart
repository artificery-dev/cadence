import 'dart:async';
import 'package:cadence_client/cadence_client.dart';
import 'package:crypto/crypto.dart';
import 'package:file/file.dart';
import 'package:sqlite3/sqlite3.dart';

/// An exclusively owned datastore. Platform adapters retain both leases until
/// relocation returns, including while SQLite's incremental backup yields.
class RelocationStore {
  RelocationStore({
    required this.database,
    required this.fileSystem,
    required this.cacheDirectory,
    required this.location,
    required this.available,
    required this.flush,
    required this.storageKind,
  });
  final Database database;
  final FileSystem fileSystem;
  final String cacheDirectory;
  final String location;
  final String storageKind;
  final bool Function() available;
  final void Function() flush;
}

Map<String, Object?>? relocationRecord(Database db) {
  if (db
      .select(
        "SELECT name FROM sqlite_master WHERE name = 'cadence_relocation'",
      )
      .isEmpty)
    return null;
  final rows = db.select('SELECT * FROM cadence_relocation');
  if (rows.length != 1)
    throw MediaError('relocation_invalid', 'Invalid relocation record', 409);
  return Map<String, Object?>.from(rows.single);
}

/// A retired or interrupted copy must never become another active owner of the
/// same library identities. Recovery uses the same relocation invocation.
void requireActiveDatastore(Database db) {
  final record = relocationRecord(db);
  if (record != null && record['state'] != 'active') {
    throw MediaError(
      record['state'] == 'retired' ? 'datastore_retired' : 'relocation_pending',
      'Datastore relocation ${record['operation_id']} is ${record['state']}; '
      'retry the original relocation command before starting the destination',
      409,
    );
  }
}

/// Inspection is performed while the caller holds exclusive ownership. It does
/// not initialize, migrate, resume jobs, or change the relocation journal.
Map<String, Object?> inspectRelocationStore(RelocationStore store) {
  final db = store.database;
  final tables = db
      .select(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
      )
      .map((r) => r['name'])
      .toSet();
  final result = <String, Object?>{
    'store': store.location,
    'storageKind': store.storageKind,
    'state': 'unsupported',
    'canOpen': false,
  };
  if (tables.isEmpty) return {...result, 'state': 'empty'};
  final record = relocationRecord(db);
  if (record != null)
    result.addAll({
      'operationId': record['operation_id'],
      'relocationState': record['state'],
    });
  if (!tables.contains('cadence_volume') ||
      !tables.contains('cadence_media_base') ||
      db.userVersion != 10 ||
      !db
          .select('PRAGMA table_info(cadence_media_base)')
          .any((r) => r['name'] == 'mount')) {
    return {...result, if (record != null) 'state': 'pending'};
  }
  final ids = db.select('SELECT id,format_version FROM cadence_volume');
  final config = db.select('SELECT root,mount FROM cadence_media_base');
  if (ids.length != 1 ||
      ids.single['format_version'] != 1 ||
      config.length != 1)
    return result;
  final root = config.single['root'];
  final mount = config.single['mount'];
  if (root is! String || (mount != null && mount is! String)) return result;
  final path = store.fileSystem.path;
  final resolvedRoot = root == '.' ? path.dirname(store.location) : root;
  final resolvedMount = mount == '.'
      ? path.dirname(store.location)
      : mount as String?;
  if (!path.isAbsolute(resolvedRoot) ||
      path.normalize(resolvedRoot) != resolvedRoot ||
      (resolvedMount != null &&
          (!path.isAbsolute(resolvedMount) ||
              path.normalize(resolvedMount) != resolvedMount ||
              !(resolvedRoot == resolvedMount ||
                  path.isWithin(resolvedMount, resolvedRoot)))))
    return result;
  final state = record == null || record['state'] == 'active'
      ? 'active'
      : record['state'] == 'retired'
      ? 'retired'
      : 'pending';
  return {
    ...result,
    'state': state,
    'canOpen': state == 'active',
    'datastoreId': ids.single['id'],
    'mediaRoot': config.single['root'],
    'mediaMount': config.single['mount'],
  };
}

/// A definitive rejection before this operation wrote any transfer state may
/// be dismissed by the supervisor. Uninspectable or already-pending states are
/// deliberately not classified as cancel-safe.
bool relocationCancelSafe({
  required RelocationStore source,
  required RelocationStore destination,
  required String operationId,
  required String expectedId,
  required bool mutationStarted,
}) {
  try {
    if (mutationStarted || !source.available() || !destination.available())
      return false;
    final inspected = inspectRelocationStore(source);
    if (inspected['state'] != 'active' ||
        inspected['datastoreId'] != expectedId)
      return false;
    final target = relocationRecord(destination.database);
    return target == null || target['operation_id'] != operationId;
  } catch (_) {
    return false;
  }
}

/// Current-format metadata/cache relocation. Media is never copied or deleted.
///
/// The source stays intact, but becomes permanently retired on commit. A
/// completed inverse relocation can reuse that retired copy. No existing active
/// destination is overwritten. Every restart retries with the same operation ID
/// and locations. Before publication both copies are blocked; source retirement
/// is durably flushed before destination activation, so a crash cannot activate
/// both. Errors after preparation require retry, not restarting the source.
/// Automatic invocation recovery belongs to the supervising host; this function
/// makes retries idempotent, including after activation but before acknowledgement.
Future<Map<String, Object?>> relocateDatastore({
  required RelocationStore source,
  required RelocationStore destination,
  required String operationId,
  required String expectedId,
  bool Function()? cancelled,
  void Function(Map<String, Object?>)? progress,
  bool checkOnly = false,
  void Function()? onMutation,
}) async {
  Never fail(String code, String message) =>
      throw MediaError(code, message, 409);
  void check() {
    if (cancelled?.call() == true)
      fail(
        'relocation_interrupted',
        'Relocation interrupted; retry the same operation ID',
      );
    if (!source.available() || !destination.available()) {
      fail(
        'storage_unavailable',
        'Storage detached; retry with the same operation ID and original card',
      );
    }
  }

  void report(String phase, [Map<String, Object?> extra = const {}]) {
    check();
    progress?.call({
      'event': 'relocation-progress',
      'operationId': operationId,
      'phase': phase,
      ...extra,
    });
  }

  if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(operationId) ||
      source.location == destination.location) {
    throw MediaError(
      'invalid_request',
      'Unique operationId and distinct locations required',
      400,
    );
  }
  final path = source.fileSystem.path;
  for (final location in [source.location, destination.location]) {
    if (!path.isAbsolute(location) ||
        path.normalize(location) != location ||
        path.basename(location) != '.cadence')
      throw MediaError(
        'invalid_request',
        'Canonical .cadence locations required',
        400,
      );
  }
  final from = source.database, to = destination.database;
  report('validating');
  if (from.userVersion != 10 ||
      from
          .select(
            "SELECT name FROM sqlite_master WHERE name = 'cadence_volume'",
          )
          .isEmpty) {
    fail(
      'unsupported_datastore_format',
      'Relocation requires current Cadence schema 10',
    );
  }
  final identity = from.select('SELECT id,format_version FROM cadence_volume');
  if (identity.length != 1 ||
      identity.single['id'] != expectedId ||
      identity.single['format_version'] != 1) {
    fail('datastore_mismatch', 'Source identity or format does not match');
  }
  if (!from
      .select('PRAGMA table_info(cadence_media_base)')
      .any((r) => r['name'] == 'mount'))
    fail(
      'unsupported_datastore_format',
      'Current declared media-base configuration required',
    );
  final config = from.select('SELECT root,mount FROM cadence_media_base');
  if (config.length != 1)
    fail('unsupported_datastore_format', 'One declared media base is required');
  String resolve(String value) =>
      value == '.' ? path.dirname(source.location) : value;
  final mediaRoot = resolve(config.single['root'] as String);
  final mediaMount = config.single['mount'] == null
      ? null
      : resolve(config.single['mount'] as String);
  String declare(String value) =>
      value == path.dirname(destination.location) ? '.' : value;
  if (!path.isAbsolute(mediaRoot) ||
      path.normalize(mediaRoot) != mediaRoot ||
      (mediaMount != null &&
          (!path.isAbsolute(mediaMount) ||
              !(mediaRoot == mediaMount ||
                  path.isWithin(mediaMount, mediaRoot)))))
    fail('unsupported_datastore_format', 'Invalid declared media base');
  final before = relocationRecord(from), existing = relocationRecord(to);
  Map<String, Object?> plan(String disposition, {bool allowed = true}) {
    final target = inspectRelocationStore(destination);
    return {
      'event': 'relocation-preflight',
      'operationId': operationId,
      'canRelocate': allowed,
      'disposition': disposition,
      'source': inspectRelocationStore(source),
      'destination': target,
      'canUseExisting':
          !allowed &&
          target['canOpen'] == true &&
          target['datastoreId'] != expectedId,
      'cancelSafe': relocationCancelSafe(
        source: source,
        destination: destination,
        operationId: operationId,
        expectedId: expectedId,
        mutationStarted: false,
      ),
    };
  }

  bool same(Map<String, Object?>? record) =>
      record != null &&
      record['operation_id'] == operationId &&
      record['source'] == source.location &&
      record['destination'] == destination.location;
  final resuming = same(before);
  if (!resuming &&
      from
          .select(
            "SELECT name FROM sqlite_master WHERE name='cadence_relocation_history'",
          )
          .isNotEmpty &&
      from.select(
        'SELECT operation_id FROM cadence_relocation_history WHERE operation_id=?',
        [operationId],
      ).isNotEmpty)
    fail(
      'operation_id_reused',
      'This operation ID belongs to an earlier move; use a new ID for new consent',
    );
  if (before != null && before['state'] != 'active' && !resuming) {
    fail(
      'relocation_conflict',
      'Source has another pending or retired relocation',
    );
  }
  Map<String, Object?> result() => {
    'event': 'relocation-complete',
    'state': 'done',
    'operationId': operationId,
    'datastoreId': expectedId,
    'storageKind': destination.storageKind,
    'store': destination.location,
    'mediaRoot': declare(mediaRoot),
    'resolvedMediaRoot': mediaRoot,
    'mediaMount': mediaMount,
    'sourceRetired': true,
    'sourceRetained': true,
    'libraries': [
      for (final row in to.select(
        'SELECT library_id,uuid FROM library_identities ORDER BY library_id',
      ))
        {'id': row['library_id'], 'uuid': row['uuid']},
    ],
  };
  if (resuming &&
      before!['state'] == 'retired' &&
      same(existing) &&
      existing!['state'] == 'active') {
    if (to.select('SELECT id FROM cadence_volume').single['id'] != expectedId)
      fail('datastore_mismatch', 'Destination identity changed');
    if (checkOnly) return plan('already-complete');
    destination.flush();
    return result();
  }
  final empty = to
      .select(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
      )
      .isEmpty;
  final returning =
      before?['state'] == 'active' &&
      existing?['state'] == 'retired' &&
      before?['operation_id'] == existing?['operation_id'] &&
      before?['source'] == destination.location &&
      before?['destination'] == source.location &&
      to.select('SELECT id FROM cadence_volume').single['id'] == expectedId;
  if (!empty &&
      !returning &&
      !(same(existing) &&
          ['incoming', 'outgoing', 'prepared'].contains(existing!['state']))) {
    if (checkOnly) return plan('destination-exists', allowed: false);
    fail(
      'destination_exists',
      'Destination already contains a datastore; it will not be overwritten',
    );
  }
  if (checkOnly)
    return plan(
      empty
          ? 'empty-destination'
          : returning
          ? 'reuse-retired'
          : 'resume',
    );
  final cacheFiles = <File>[];
  final cache = source.fileSystem.directory(source.cacheDirectory);
  if (cache.existsSync()) {
    if (source.fileSystem.typeSync(cache.path, followLinks: false) ==
        FileSystemEntityType.link)
      fail('unsafe_cache', 'Cache directory must not be a symbolic link');
    for (final entity in cache.listSync(followLinks: false)) {
      final name = source.fileSystem.path.basename(entity.path);
      // Only the daemon's content-addressed files are cache entries. Transient
      // files and the Linux flush inode are disposable, never followed/copied.
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(name)) continue;
      if (entity is! File)
        fail('unsafe_cache', 'Cache entry is not a regular file: $name');
      cacheFiles.add(entity);
    }
  }
  onMutation?.call();
  for (final db in [from, to]) {
    db.execute('PRAGMA journal_mode=DELETE');
    db.execute('PRAGMA synchronous=EXTRA');
    db.execute('PRAGMA temp_store=MEMORY');
  }
  void record(Database db, String state) {
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute(
        'CREATE TABLE IF NOT EXISTS cadence_relocation (operation_id TEXT NOT NULL, state TEXT NOT NULL, source TEXT NOT NULL, destination TEXT NOT NULL)',
      );
      db.execute('DELETE FROM cadence_relocation');
      db.execute(
        'CREATE TABLE IF NOT EXISTS cadence_relocation_history (operation_id TEXT PRIMARY KEY, source TEXT NOT NULL, destination TEXT NOT NULL)',
      );
      db.execute(
        'INSERT OR IGNORE INTO cadence_relocation_history VALUES (?,?,?)',
        [operationId, source.location, destination.location],
      );
      db.execute('INSERT INTO cadence_relocation VALUES (?,?,?,?)', [
        operationId,
        state,
        source.location,
        destination.location,
      ]);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  // A prepared destination is verified and flushed already. Never overwrite it
  // from the retired source: it may be the only complete committed generation.
  if (!(resuming &&
      before!['state'] == 'retired' &&
      same(existing) &&
      existing!['state'] == 'prepared')) {
    if (before?['state'] == 'retired')
      fail(
        'relocation_recovery_required',
        'Retired source requires its prepared destination',
      );
    record(to, 'incoming');
    destination.flush();
    record(from, 'outgoing');
    source.flush();
    report('copying-database');
    await for (final fraction in from.backup(to, nPage: 128)) {
      report('copying-database', {'fraction': fraction});
    }
    // Preserve every media/root/item/hash/job row. Only the declaration changes:
    // it must continue to resolve to the same physical media base after moving.
    to.execute('BEGIN IMMEDIATE');
    try {
      to.execute('UPDATE cadence_media_base SET root=?,mount=?', [
        declare(mediaRoot),
        mediaMount == null ? null : declare(mediaMount),
      ]);
      to.execute('UPDATE daemon_roots SET available=0');
      to.execute('COMMIT');
    } catch (_) {
      to.execute('ROLLBACK');
      rethrow;
    }
    var copied = 0;
    for (final file in cacheFiles) {
      report('copying-cache', {
        'completed': copied,
        'total': cacheFiles.length,
      });
      final name = source.fileSystem.path.basename(file.path);
      final target = destination.fileSystem.file(
        destination.fileSystem.path.join(destination.cacheDirectory, name),
      );
      target.parent.createSync(recursive: true);
      if (destination.fileSystem.typeSync(
                target.parent.path,
                followLinks: false,
              ) ==
              FileSystemEntityType.link ||
          destination.fileSystem.typeSync(target.path, followLinks: false) ==
              FileSystemEntityType.link)
        fail(
          'unsafe_cache',
          'Destination cache must not contain symbolic links',
        );
      final input = await file.open();
      RandomAccessFile? output;
      try {
        output = await target.open(mode: FileMode.write);
        while (true) {
          check();
          final bytes = await input.read(256 * 1024);
          if (bytes.isEmpty) break;
          await output.writeFrom(bytes);
        }
        await output.flush();
      } finally {
        await input.close();
        await output?.close();
      }
      if ((await sha256.bind(target.openRead()).first).toString() != name)
        fail('cache_verification_failed', 'Artwork cache checksum mismatch');
      copied++;
    }
    report('verifying');
    if (to.select('PRAGMA integrity_check').single.values.single != 'ok' ||
        to.select('PRAGMA foreign_key_check').isNotEmpty)
      fail('verification_failed', 'Destination SQLite verification failed');
    if (to.select('SELECT id FROM cadence_volume').single['id'] != expectedId)
      fail('verification_failed', 'Destination UUID changed');
    record(to, 'prepared');
    destination.flush();
    report('prepared');
    record(from, 'retired');
  }
  // A previous attempt may have written retirement but failed its device flush.
  // Reassert durability before making the destination accessible.
  source.flush();
  if (to.select('PRAGMA integrity_check').single.values.single != 'ok' ||
      to.select('PRAGMA foreign_key_check').isNotEmpty ||
      to.select('SELECT id FROM cadence_volume').single['id'] != expectedId)
    fail('verification_failed', 'Prepared destination verification failed');
  report('source-retired');
  record(to, 'active');
  destination.flush();
  report('activated');
  return result();
}
