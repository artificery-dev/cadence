import 'dart:convert';
import 'package:cadence_client/cadence_client.dart';
import 'package:cadenced/relocation.dart';
import 'package:cadenced/volume.dart';
import 'package:cadenced/volume_vfs.dart';
import 'package:cadenced/declared_store.dart';
import 'package:cadenced/root_access.dart';
import 'package:crypto/crypto.dart';
import 'package:file/memory.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:test/test.dart';
import 'volume_test.dart' show MemoryCard, settle;

class _Open {
  _Open(this.fs, this.location) {
    fs.directory('/.cadence').createSync(recursive: true);
    vfs = VolumeVfs(
      fs,
      name: 'relocation-test-${sequence++}',
      syncDirectory: () {},
    );
    sql.sqlite3.registerVirtualFileSystem(vfs);
    db = sql.sqlite3.open('/.cadence/library.sqlite', vfs: vfs.name);
    store = RelocationStore(
      database: db,
      fileSystem: fs,
      cacheDirectory: '/.cadence/cache',
      location: location,
      storageKind: location.startsWith('/card') ? 'portable' : 'local',
      available: () => available,
      flush: () {
        if (flushFails) throw StateError('Flush failed');
      },
    );
  }
  static int sequence = 0;
  final MemoryFileSystem fs;
  final String location;
  late final VolumeVfs vfs;
  late final sql.Database db;
  late final RelocationStore store;
  bool available = true, flushFails = false;
  void close() {
    db.close();
    sql.sqlite3.unregisterVirtualFileSystem(vfs);
  }
}

class _Lease implements RootLease {
  _Lease(this.fileSystem);
  @override
  final MemoryFileSystem fileSystem;
  @override
  String get mountPath => '/card';
  @override
  bool available = true;
  @override
  void close() => available = false;
}

void main() {
  late MemoryFileSystem sourceFs, destinationFs;
  late _Open source, destination;
  late String id;
  late List<Map<String, Object?>> items, identities, hashes;
  late String cacheKey;
  setUp(() async {
    sourceFs = MemoryFileSystem.test();
    destinationFs = MemoryFileSystem.test();
    sourceFs.directory('/.cadence').createSync();
    sourceFs.file('/Music/song.mp3')
      ..createSync(recursive: true)
      ..writeAsStringSync('song');
    final host = ManagedLibraryHost(
      attach: ({required initialize}) async => MemoryCard(sourceFs, () {}),
      initialize: true,
      reconcileOnAttach: false,
    );
    await host.open();
    final client = CadenceClient(host);
    id = (await client.volumeStatus()).id!;
    final library = await client.createLibrary('Music', 'music');
    await client.addRoot(library, '/Music');
    final job = await client.scan(library);
    expect((await settle(client, job['jobId'] as String))['state'], 'done');
    await host.close();
    source = _Open(sourceFs, '/home/tempo/.cadence');
    destination = _Open(destinationFs, '/card/.cadence');
    source.db.execute(
      'CREATE TABLE cadence_media_base (root TEXT NOT NULL,mount TEXT)',
    );
    source.db.execute(
      "INSERT INTO cadence_media_base VALUES ('/card','/card')",
    );
    source.db.execute('INSERT INTO daemon_jobs VALUES (?,?)', [
      'pending',
      jsonEncode({
        'journalVersion': 2,
        'jobId': 'pending',
        'libraryId': library,
        'state': 'queued',
        'queueOrder': 2,
        'attemptCount': 0,
        'attempts': [],
      }),
    ]);
    items = source.db
        .select('SELECT * FROM library_items')
        .map((r) => Map<String, Object?>.from(r))
        .toList();
    identities = source.db
        .select('SELECT * FROM library_identities')
        .map((r) => Map<String, Object?>.from(r))
        .toList();
    hashes = source.db
        .select('SELECT * FROM file_hashes')
        .map((r) => Map<String, Object?>.from(r))
        .toList();
    final art = utf8.encode('cached-artwork');
    cacheKey = sha256.convert(art).toString();
    sourceFs.file('/.cadence/cache/$cacheKey')
      ..createSync(recursive: true)
      ..writeAsBytesSync(art);
  });
  tearDown(() {
    source.close();
    destination.close();
  });
  Future<Map<String, Object?>> move({
    void Function(Map<String, Object?>)? progress,
    bool Function()? cancelled,
  }) => relocateDatastore(
    source: source.store,
    destination: destination.store,
    operationId: 'outward',
    expectedId: id,
    progress: progress,
    cancelled: cancelled,
  );

  test(
    'metadata move preserves identities, paths, queue and cache; reverse reuses retired predecessor',
    () async {
      final done = await move();
      expect(done['sourceRetired'], true);
      expect(done['mediaRoot'], '.');
      expect(done['resolvedMediaRoot'], '/card');
      expect(
        destination.db
            .select('SELECT * FROM library_items')
            .map(Map<String, Object?>.from)
            .toList(),
        items,
      );
      expect(
        destination.db
            .select('SELECT * FROM library_identities')
            .map(Map<String, Object?>.from)
            .toList(),
        identities,
      );
      expect(
        destination.db
            .select('SELECT * FROM file_hashes')
            .map(Map<String, Object?>.from)
            .toList(),
        hashes,
      );
      expect(
        destination.db.select('SELECT path FROM files').single['path'],
        '/Music/song.mp3',
      );
      expect(
        destination.db
            .select("SELECT body FROM daemon_jobs WHERE id='pending'")
            .single['body'],
        source.db
            .select("SELECT body FROM daemon_jobs WHERE id='pending'")
            .single['body'],
      );
      expect(
        destinationFs.file('/.cadence/cache/$cacheKey').readAsBytesSync(),
        sourceFs.file('/.cadence/cache/$cacheKey').readAsBytesSync(),
      );
      expect(
        () => requireActiveDatastore(source.db),
        throwsA(isA<MediaError>()),
      );
      requireActiveDatastore(destination.db);
      expect(await move(), done);
      final back = await relocateDatastore(
        source: destination.store,
        destination: source.store,
        operationId: 'return',
        expectedId: id,
      );
      expect(back['mediaRoot'], '/card');
      await expectLater(
        move(),
        throwsA(
          isA<MediaError>().having(
            (e) => e.code,
            'code',
            'operation_id_reused',
          ),
        ),
      );
      requireActiveDatastore(source.db);
      expect(
        () => requireActiveDatastore(destination.db),
        throwsA(isA<MediaError>()),
      );
      expect(
        source.db
            .select('SELECT * FROM library_identities')
            .map(Map<String, Object?>.from)
            .toList(),
        identities,
      );
    },
  );

  test(
    'moving home metadata with home media never retargets media to the card',
    () async {
      source.db.execute("UPDATE cadence_media_base SET root='.',mount=NULL");
      final result = await move();
      expect(result['mediaRoot'], '/home/tempo');
      expect(result['mediaMount'], null);
      expect(
        destination.db.select('SELECT path FROM files').single['path'],
        '/Music/song.mp3',
      );
    },
  );

  test(
    'copied queued job resumes only after destination root handshake',
    () async {
      await move();
      destination.close();
      final host = ManagedLibraryHost(
        hostRootAvailability: true,
        attach: ({required initialize}) async => DeclaredMediaStore(
          metadata: MemoryCard(destinationFs, () {}),
          metadataRoot: '/card',
          acquireMediaRoot: (root, mount, id) => _Lease(sourceFs),
          playerPath: (path) => path,
        ),
      );
      try {
        await host.open();
        final client = CadenceClient(host);
        expect((await client.job('pending'))['state'], 'queued');
        final state = await client.volumeStatus();
        final roots = (await client.snapshot())['roots'] as List;
        await client.setRootAvailability(
          expectedId: state.id!,
          expectedGeneration: state.generation!,
          roots: [
            for (final root in roots.cast<Map>())
              RootAvailability(
                rootId: root['id'] as int,
                available: true,
                mountId: 'current-card',
                sourceId: 'card-A',
              ),
          ],
        );
        expect((await settle(client, 'pending'))['state'], 'done');
        expect((await client.job('pending'))['attemptCount'], 1);
        final libraries =
            (await client.call('get', '/libraries'))['libraries'] as List;
        expect((libraries.single as Map)['uuid'], identities.single['uuid']);
      } finally {
        await host.close();
        destination = _Open(destinationFs, '/card/.cadence');
      }
    },
  );

  for (final phase in [
    'copying-database',
    'copying-cache',
    'prepared',
    'source-retired',
    'activated',
  ]) {
    test(
      'interruption at $phase is recoverable after reopening both stores',
      () async {
        await expectLater(
          move(
            progress: (event) {
              if (event['phase'] == phase)
                throw StateError('Process interrupted');
            },
          ),
          throwsStateError,
        );
        source.close();
        destination.close();
        source = _Open(sourceFs, '/home/tempo/.cadence');
        destination = _Open(destinationFs, '/card/.cadence');
        expect(
          () => requireActiveDatastore(source.db),
          throwsA(isA<MediaError>()),
        );
        if (phase != 'activated')
          expect(
            () => requireActiveDatastore(destination.db),
            throwsA(isA<MediaError>()),
          );
        expect((await move())['state'], 'done');
        requireActiveDatastore(destination.db);
        expect(
          destination.db
              .select('SELECT * FROM library_identities')
              .map(Map<String, Object?>.from)
              .toList(),
          identities,
        );
      },
    );
  }
  test('wrong UUID and active destination leave the source usable', () async {
    await expectLater(
      relocateDatastore(
        source: source.store,
        destination: destination.store,
        operationId: 'wrong',
        expectedId: 'wrong',
      ),
      throwsA(isA<MediaError>()),
    );
    destination.db.execute('CREATE TABLE unrelated (value TEXT)');
    await expectLater(
      move(),
      throwsA(
        isA<MediaError>().having((e) => e.code, 'code', 'destination_exists'),
      ),
    );
    requireActiveDatastore(source.db);
    expect(relocationRecord(source.db), null);
    expect(
      destination.db.select(
        "SELECT name FROM sqlite_master WHERE name='unrelated'",
      ),
      hasLength(1),
    );
  });

  test(
    'preflight is read-only and identifies empty, active and retired destinations',
    () async {
      Future<Map<String, Object?>> inspect({
        bool reverse = false,
        String operation = 'outward',
      }) => relocateDatastore(
        source: reverse ? destination.store : source.store,
        destination: reverse ? source.store : destination.store,
        operationId: operation,
        expectedId: id,
        checkOnly: true,
        onMutation: () => fail('Preflight attempted mutation'),
      );
      final bytes = sourceFs.file('/.cadence/library.sqlite').readAsBytesSync();
      final empty = await inspect();
      expect(empty['disposition'], 'empty-destination');
      expect(empty['canRelocate'], true);
      expect(empty['cancelSafe'], true);
      expect(
        sourceFs.file('/.cadence/library.sqlite').readAsBytesSync(),
        bytes,
      );
      expect(relocationRecord(source.db), null);
      await move();
      final completed = await inspect();
      expect(completed['disposition'], 'already-complete');
      expect(completed['cancelSafe'], false);
      final returning = await inspect(reverse: true, operation: 'return');
      expect(returning['disposition'], 'reuse-retired');
      expect(returning['canRelocate'], true);
      expect(returning['cancelSafe'], true);
    },
  );

  test(
    'active destination can be selected without replacing it; rejection is cancel-safe',
    () async {
      await for (final _ in source.db.backup(destination.db)) {}
      var plan = await relocateDatastore(
        source: source.store,
        destination: destination.store,
        operationId: 'outward',
        expectedId: id,
        checkOnly: true,
      );
      expect(
        plan['canUseExisting'],
        false,
        reason: 'Do not recommend an active clone of the same datastore',
      );
      destination.db.execute(
        "UPDATE cadence_volume SET id='another-library-store'",
      );
      plan = await relocateDatastore(
        source: source.store,
        destination: destination.store,
        operationId: 'outward',
        expectedId: id,
        checkOnly: true,
      );
      expect(plan['canRelocate'], false);
      expect(plan['canUseExisting'], true);
      expect(
        (plan['destination'] as Map)['datastoreId'],
        'another-library-store',
      );
      var mutated = false;
      await expectLater(
        relocateDatastore(
          source: source.store,
          destination: destination.store,
          operationId: 'outward',
          expectedId: id,
          onMutation: () => mutated = true,
        ),
        throwsA(isA<MediaError>()),
      );
      expect(
        relocationCancelSafe(
          source: source.store,
          destination: destination.store,
          operationId: 'outward',
          expectedId: id,
          mutationStarted: mutated,
        ),
        true,
      );
      destination.available = false;
      expect(
        relocationCancelSafe(
          source: source.store,
          destination: destination.store,
          operationId: 'outward',
          expectedId: id,
          mutationStarted: false,
        ),
        false,
      );
    },
  );
  test(
    'cancellation and unavailable storage do not publish a successful copy',
    () async {
      var cancel = false;
      await expectLater(
        move(
          cancelled: () => cancel,
          progress: (event) {
            if (event['phase'] == 'copying-database') cancel = true;
          },
        ),
        throwsA(isA<MediaError>()),
      );
      expect(
        () => requireActiveDatastore(source.db),
        throwsA(isA<MediaError>()),
      );
      destination.available = false;
      await expectLater(move(), throwsA(isA<MediaError>()));
      destination.available = true;
      expect((await move())['state'], 'done');
    },
  );
  test(
    'flush failure after preparation leaves both copies blocked until retry',
    () async {
      await expectLater(
        move(
          progress: (event) {
            if (event['phase'] == 'prepared') source.flushFails = true;
          },
        ),
        throwsStateError,
      );
      expect(
        () => requireActiveDatastore(source.db),
        throwsA(isA<MediaError>()),
      );
      expect(
        () => requireActiveDatastore(destination.db),
        throwsA(isA<MediaError>()),
      );
      await expectLater(move(), throwsStateError);
      source.flushFails = false;
      expect((await move())['state'], 'done');
    },
  );
}
