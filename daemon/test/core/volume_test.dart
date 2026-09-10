import 'dart:async';
import 'package:cadence_client/cadence_client.dart';
import 'package:cadence_media/cadence_media.dart';
import 'package:cadenced/volume.dart';
import 'package:cadenced/volume_vfs.dart';
import 'package:file/chroot.dart';
import 'package:file/memory.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';
import 'host_test.dart' show GateTier;

class MemoryCard implements VolumeAttachment {
  MemoryCard(this.fileSystem, this.onRelease);
  @override
  final FileSystem fileSystem;
  final void Function() onRelease;
  bool attached = true;
  bool flushFails = false;
  @override
  bool get isAttached => attached;
  @override
  void syncDirectory() {}
  @override
  void flush() {
    if (flushFails) throw StateError('Flush failed');
  }

  @override
  void release() => onRelease();
}

class EnteredTier extends GateTier {
  EnteredTier(super.gate);
  final entered = Completer<void>();
  @override
  Future<ExtractionResult?> extract(String path, MediaKind kind) {
    if (!entered.isCompleted) entered.complete();
    return super.extract(path, kind);
  }
}

/// Polls a job until it finishes. The bound is generous because integration
/// suites run a JIT daemon with the native probe on loaded CI runners; a
/// finished job returns as soon as it lands.
Future<Map<String, Object?>> settle(CadenceClient client, String id) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (true) {
    final job = await client.job(id);
    if (job['finishedAt'] != null) return job;
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Job did not finish within 60s: $job');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late MemoryFileSystem fs;
  late String mount;
  late bool owned;
  MemoryCard? card;
  Future<VolumeAttachment> attach({required bool initialize}) async {
    if (owned) throw StateError('Already owned');
    owned = true;
    final view = ChrootFileSystem(fs, mount);
    view.directory('/.cadence').createSync(recursive: true);
    return card = MemoryCard(view, () => owned = false);
  }

  setUp(() {
    fs = MemoryFileSystem.test();
    mount = '/player-one/card';
    owned = false;
    fs.file('$mount/music/song.mp3')
      ..createSync(recursive: true)
      ..writeAsStringSync('song');
  });
  test(
    'card relocation retains library UUID, media IDs, metadata and full hash',
    () async {
      var host = ManagedLibraryHost(
        reconcileOnAttach: false,
        attach: attach,
        initialize: true,
      );
      await host.open();
      var client = CadenceClient(host);
      final volume = (await client.volume())['id'];
      final created = await client.call('post', '/libraries', {
        'name': 'Music',
        'type': 'music',
      });
      final id = created['id'] as int;
      final uuid = created['uuid'];
      expect(
        uuid,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      await client.addRoot(id, '/music');
      final job = await client.scan(id);
      expect((await settle(client, job['jobId'] as String))['discovered'], 1);
      final original = (await client.items(id)).single;
      expect((original as Map)['path'], '/music/song.mp3');
      expect((await client.ejectVolume())['readyToUnmount'], true);
      expect(owned, false);
      expect(
        (await client.snapshot())['volume'],
        containsPair('state', 'detached'),
      );
      await expectLater(client.items(id), throwsA(isA<MediaError>()));
      await host.close();
      fs.directory('/player-two').createSync();
      fs.directory(mount).renameSync('/player-two/sd');
      mount = '/player-two/sd';
      host = ManagedLibraryHost(reconcileOnAttach: false, attach: attach);
      await host.open();
      addTearDown(host.close);
      client = CadenceClient(host);
      expect((await client.volume())['id'], volume);
      final libraries =
          (await client.call('get', '/libraries'))['libraries'] as List;
      expect((libraries.single as Map)['uuid'], uuid);
      expect(await client.items(id), [original]);
      final rescan = await client.scan(id);
      final done = await settle(client, rescan['jobId'] as String);
      expect(done['state'], 'done');
      expect(done['discovered'], 0);
      expect(await client.items(id), [original]);
      await expectLater(
        client.addRoot(id, '/.cadence'),
        throwsA(isA<MediaError>()),
      );
      await expectLater(
        client.addRoot(id, '/../outside'),
        throwsA(isA<MediaError>()),
      );
    },
  );
  test(
    'eject drains work and automatically resumes interrupted job on attach',
    () async {
      final gate = Completer<void>();
      final tier = EnteredTier(gate.future);
      final host = ManagedLibraryHost(
        reconcileOnAttach: false,
        attach: attach,
        initialize: true,
        buildExtractor: () => MediaExtractor([tier]),
      );
      await host.open();
      addTearDown(host.close);
      final client = CadenceClient(host);
      final id = await client.createLibrary('Music', 'music');
      await client.addRoot(id, '/music');
      final added = host.events.firstWhere(
        (e) => e['type'] == 'media-item-added',
      );
      final job = await client.scan(id);
      await added;
      await tier.entered.future;
      var ejected = false;
      final eject = client.ejectVolume().then((s) {
        ejected = true;
        return s;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ejected, false);
      expect((await client.volume())['state'], 'quiescing');
      await expectLater(
        client.scan(id),
        throwsA(
          isA<MediaError>().having((e) => e.code, 'code', 'volume_quiescing'),
        ),
      );
      expect(owned, true);
      gate.complete();
      expect((await eject)['readyToUnmount'], true);
      final before = await client.volumeStatus();
      final volume = before.id!;
      await expectLater(
        client.attachVolume(expectedId: volume, expectedGeneration: 'stale'),
        throwsA(
          isA<MediaError>().having((e) => e.code, 'code', 'stale_generation'),
        ),
      );
      await client.attachVolume(expectedId: volume);
      final done = await settle(client, job['jobId'] as String);
      await expectLater(
        client.ejectVolume(expectedGeneration: 'stale'),
        throwsA(
          isA<MediaError>().having((e) => e.code, 'code', 'stale_generation'),
        ),
      );
      expect((await client.volumeStatus()).state, 'attached');
      expect(done['state'], 'done');
      expect(done['attemptCount'], 2);
      expect(await client.items(id), hasLength(1));
    },
  );
  test(
    'loss rejects clients, preserves records and requires explicit reattach',
    () async {
      final host = ManagedLibraryHost(
        reconcileOnAttach: false,
        attach: attach,
        initialize: true,
      );
      await host.open();
      addTearDown(host.close);
      final client = CadenceClient(host);
      final id = await client.createLibrary('Music', 'music');
      await client.addRoot(id, '/music');
      final job = await client.scan(id);
      await settle(client, job['jobId'] as String);
      card!.attached = false;
      await expectLater(client.scan(id), throwsA(isA<MediaError>()));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect((await client.volume())['state'], 'unavailable');
      expect(owned, false);
      await client.attachVolume();
      expect(await client.items(id), hasLength(1));
    },
  );
  test(
    'initialization is explicit, exclusive and rejects wrong volume identity',
    () async {
      final uninitialized = ManagedLibraryHost(
        reconcileOnAttach: false,
        attach: attach,
      );
      await expectLater(uninitialized.open(), throwsStateError);
      await uninitialized.close();
      final host = ManagedLibraryHost(
        reconcileOnAttach: false,
        attach: attach,
        initialize: true,
      );
      await host.open();
      addTearDown(host.close);
      final other = ManagedLibraryHost(
        reconcileOnAttach: false,
        attach: attach,
        initialize: true,
      );
      await expectLater(other.open(), throwsStateError);
      await other.close();
      await host.request('post', '/volume/eject');
      await expectLater(
        host.request('post', '/volume/attach', {'expectedId': 'wrong'}),
        throwsA(isA<MediaError>()),
      );
      expect(owned, false);
      await host.request('post', '/volume/attach');
    },
  );
  test('VFS transaction rollback and integrity use injected filesystem', () {
    fs.directory('/.cadence').createSync();
    final vfs = VolumeVfs(fs, name: 'test-volume-vfs', syncDirectory: () {});
    sqlite.sqlite3.registerVirtualFileSystem(vfs);
    addTearDown(() => sqlite.sqlite3.unregisterVirtualFileSystem(vfs));
    var db = sqlite.sqlite3.open('/.cadence/library.sqlite', vfs: vfs.name);
    db.execute('CREATE TABLE example (value TEXT)');
    db.execute("INSERT INTO example VALUES ('before')");
    db.execute('BEGIN IMMEDIATE');
    db.execute("UPDATE example SET value = 'after'");
    db.execute('ROLLBACK');
    expect(db.select('SELECT value FROM example').single['value'], 'before');
    db.close();
    db = sqlite.sqlite3.open('/.cadence/library.sqlite', vfs: vfs.name);
    expect(db.select('PRAGMA integrity_check').single.values, ['ok']);
    db.close();
    expect(fs.file('/.cadence/library.sqlite').lengthSync(), greaterThan(0));
  });
  test(
    'lost card during metadata restores the durable job and minimal item',
    () async {
      final gate = Completer<void>();
      final tier = EnteredTier(gate.future);
      final host = ManagedLibraryHost(
        attach: attach,
        initialize: true,
        reconcileOnAttach: false,
        buildExtractor: () => MediaExtractor([tier]),
      );
      await host.open();
      addTearDown(host.close);
      final client = CadenceClient(host);
      final library = await client.createLibrary('Music', 'music');
      await client.addRoot(library, '/music');
      final job = await client.scan(library);
      await tier.entered.future;
      card!.attached = false;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      gate.complete();
      // Await cleanup before attaching another lease.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((await client.volume())['state'], 'unavailable');
      await client.attachVolume();
      final done = await settle(client, job['jobId'] as String);
      await expectLater(
        client.ejectVolume(expectedGeneration: 'stale'),
        throwsA(
          isA<MediaError>().having((e) => e.code, 'code', 'stale_generation'),
        ),
      );
      expect((await client.volumeStatus()).state, 'attached');
      expect(done['state'], 'done');
      expect(done['attemptCount'], 2);
      expect(await client.items(library), hasLength(1));
    },
  );
  test(
    'hot rollback journal recovers interrupted writes in MemoryFileSystem',
    () {
      fs.directory('/.cadence').createSync();
      final vfs = VolumeVfs(fs, name: 'hot-original', syncDirectory: () {});
      sqlite.sqlite3.registerVirtualFileSystem(vfs);
      final db = sqlite.sqlite3.open('/.cadence/library.sqlite', vfs: vfs.name);
      final crash = MemoryFileSystem.test();
      crash.directory('/.cadence').createSync();
      try {
        db.execute('PRAGMA cache_size = 2');
        db.execute(
          'CREATE TABLE recovery (id INTEGER PRIMARY KEY, payload TEXT)',
        );
        db.execute('BEGIN');
        for (var i = 0; i < 40; i++) {
          db.execute('INSERT INTO recovery VALUES (?, ?)', [
            i,
            'before' * 1024,
          ]);
        }
        db.execute('COMMIT');
        db.execute('BEGIN IMMEDIATE');
        db.execute(
          "UPDATE recovery SET payload = replace(payload, 'before', 'after!')",
        );
        expect(
          fs.file('/.cadence/library.sqlite-journal').lengthSync(),
          greaterThan(512),
        );
        for (final file
            in fs.directory('/.cadence').listSync().whereType<File>()) {
          crash.file(file.path).writeAsBytesSync(file.readAsBytesSync());
        }
      } finally {
        db.close();
        sqlite.sqlite3.unregisterVirtualFileSystem(vfs);
      }
      final recovery = VolumeVfs(
        crash,
        name: 'hot-recovered',
        syncDirectory: () {},
      );
      sqlite.sqlite3.registerVirtualFileSystem(recovery);
      final restored = sqlite.sqlite3.open(
        '/.cadence/library.sqlite',
        vfs: recovery.name,
      );
      try {
        expect(restored.select('PRAGMA integrity_check').single.values, ['ok']);
        final rows = restored.select('SELECT payload FROM recovery');
        expect(rows, hasLength(40));
        expect(rows.every((r) => r['payload'] == 'before' * 1024), true);
      } finally {
        restored.close();
        sqlite.sqlite3.unregisterVirtualFileSystem(recovery);
      }
    },
  );
  test(
    'flush failure never reports ready; explicit attach can recover',
    () async {
      final host = ManagedLibraryHost(attach: attach, initialize: true);
      await host.open();
      addTearDown(host.close);
      card!.flushFails = true;
      final failed = await host.request('post', '/volume/eject');
      expect(failed['readyToUnmount'], false);
      expect(failed['state'], 'unavailable');
      expect(failed['error'], contains('Flush failed'));
      expect(owned, false);
      await host.request('post', '/volume/attach');
      expect(
        (await host.request('post', '/volume/eject'))['readyToUnmount'],
        true,
      );
    },
  );
}
