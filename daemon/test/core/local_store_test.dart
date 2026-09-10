import 'dart:async';
import 'package:cadence_client/cadence_client.dart';
import 'package:cadence_media/cadence_media.dart';
import 'package:cadenced/volume.dart';
import 'package:cadenced/volume_vfs.dart';
import 'package:cadenced/root_access.dart';
import 'package:cadenced/root_filesystem.dart';
import 'package:file/chroot.dart';
import 'package:file/memory.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:test/test.dart';
import 'volume_test.dart' show settle, EnteredTier;

class TestRootLease implements RootLease {
  TestRootLease(this.fileSystem);
  @override
  final FileSystem fileSystem;
  @override
  String get mountPath => '/mnt/card';
  @override
  bool available = true;
  @override
  void close() {
    available = false;
  }
}

class TestLocalStore
    implements LocalStoreAttachment, RootAccessAdapter, LocalPlaybackVolume {
  TestLocalStore(
    this.fileSystem,
    this.metadata,
    this.releaseOwner,
    this.makeLease,
  ) {
    vfs = VolumeVfs(
      metadata,
      name: 'local-test-${sequence++}',
      syncDirectory: () {},
    );
    sql.sqlite3.registerVirtualFileSystem(vfs);
  }
  static int sequence = 0;
  final FileSystem metadata;
  final void Function() releaseOwner;
  final TestRootLease Function() makeLease;
  late final VolumeVfs vfs;
  List<RootObservation> observations = [];
  @override
  final RootFileSystem fileSystem;
  @override
  bool isAttached = true;
  @override
  String get cacheDirectory => '/xdg/cache';
  @override
  bool get databaseExists =>
      metadata.file('/.cadence/library.sqlite').existsSync();
  @override
  sql.Database openDatabase() =>
      sql.sqlite3.open('/.cadence/library.sqlite', vfs: vfs.name);
  @override
  void syncDirectory() {}
  @override
  void flush() {}
  @override
  void release() {
    isAttached = false;
    for (final lease in fileSystem.leases.values) {
      lease.close();
    }
    fileSystem.leases.clear();
    sql.sqlite3.unregisterVirtualFileSystem(vfs);
    releaseOwner();
  }

  @override
  void configureRoots(List<RootObservation> roots) {
    for (final lease in fileSystem.leases.values) {
      lease.close();
    }
    fileSystem.leases.clear();
    observations = roots;
    if (roots.any((r) => r.available && r.mountPath != null)) {
      if (roots.any(
        (r) => r.available && r.mountPath != null && r.mountId != 'card-A',
      ))
        throw StateError('Wrong mount');
      fileSystem.leases['/mnt/card'] = makeLease();
    }
  }

  @override
  bool rootAvailable(String path) => observations.any(
    (r) =>
        (r.path == path || fileSystem.path.isWithin(r.path, path)) &&
        r.available &&
        (r.mountPath == null ||
            fileSystem.leases[r.mountPath]?.available == true),
  );
  @override
  String playbackPath(String path) => path;
}

void main() {
  late MemoryFileSystem media, metadata;
  late bool owned;
  TestRootLease? lease;
  Future<VolumeAttachment> attach({required bool initialize}) async {
    if (owned) throw StateError('Already owned');
    owned = true;
    return TestLocalStore(
      RootFileSystem(media),
      metadata,
      () => owned = false,
      () => lease = TestRootLease(ChrootFileSystem(media, '/physical/card-A')),
    );
  }

  setUp(() {
    owned = false;
    media = MemoryFileSystem.test();
    metadata = MemoryFileSystem.test();
    metadata.directory('/.cadence').createSync();
    media.directory('/mnt/card').createSync(recursive: true);
    media.file('/home/user/Music/internal.mp3')
      ..createSync(recursive: true)
      ..writeAsStringSync('internal');
    media.file('/physical/card-A/Music/external.mp3')
      ..createSync(recursive: true)
      ..writeAsStringSync('external');
  });
  Future<VolumeStatus> observe(
    CadenceClient client,
    int internal,
    int external,
    bool available,
  ) async {
    final status = await client.volumeStatus();
    return client.setRootAvailability(
      expectedId: status.id!,
      expectedGeneration: status.generation!,
      roots: [
        RootAvailability(rootId: internal, available: true),
        RootAvailability(
          rootId: external,
          available: available,
          mountPath: '/mnt/card',
          mountId: available ? 'card-A' : null,
          sourceId: available ? 'cid-A' : null,
        ),
      ],
    );
  }

  test(
    'local store browses absolute roots; handshake precedes all filesystem jobs',
    () async {
      var host = ManagedLibraryHost(attach: attach, hostRootAvailability: true);
      await host.open();
      var client = CadenceClient(host);
      final library = await client.createLibrary('Music', 'music');
      final internal = await client.addRoot(library, '/home/user/Music');
      final external =
          (await client.call('post', '/libraries/$library/roots', {
                'path': '/mnt/card/Music',
                'mountPath': '/mnt/card',
              }))['id']
              as int;
      expect((await client.volumeStatus()).storageKind, 'local');
      expect((await client.volumeStatus()).rootAvailabilityReady, false);
      await expectLater(
        client.scan(library),
        throwsA(
          isA<MediaError>().having(
            (e) => e.code,
            'code',
            'root_availability_required',
          ),
        ),
      );
      final empty = await client.snapshot();
      expect(empty['libraries'], hasLength(1));
      final status = await observe(client, internal, external, true);
      final jobs = (await client.snapshot())['jobs'] as List;
      await settle(client, (jobs.single as Map)['jobId'] as String);
      final items = await client.items(library);
      expect(items, hasLength(2));
      expect(
        items.cast<Map>().map((i) => i['path']),
        containsAll([
          '/home/user/Music/internal.mp3',
          '/mnt/card/Music/external.mp3',
        ]),
      );
      final libraryUuid =
          (((await client.call('get', '/libraries'))['libraries'] as List)
                      .single
                  as Map)['uuid']
              as String;
      final removed = await observe(client, internal, external, false);
      expect(removed.quiescentRootIds, [external]);
      expect(removed.quiescentMountPaths, ['/mnt/card']);
      expect(removed.generation, isNot(status.generation));
      expect(owned, true);
      expect(await client.items(library), hasLength(2));
      final externalItem = items.cast<Map>().firstWhere(
        (i) => (i['path'] as String).startsWith('/mnt'),
      );
      await expectLater(
        client.resolveMedia(
          libraryUuid: libraryUuid,
          itemId: externalItem['id'] as int,
          volumeId: removed.id!,
          generation: removed.generation!,
        ),
        throwsA(
          isA<MediaError>().having((e) => e.code, 'code', 'root_unavailable'),
        ),
      );
      await host.close();
      host = ManagedLibraryHost(attach: attach, hostRootAvailability: true);
      await host.open();
      addTearDown(host.close);
      client = CadenceClient(host);
      expect((await client.volumeStatus()).id, status.id);
      expect((await client.volumeStatus()).rootAvailabilityReady, false);
      expect(await client.items(library), hasLength(2));
      expect(
        (await client.snapshot())['queue'],
        containsPair('enabled', false),
      );
      await observe(client, internal, external, true);
      for (final job
          in ((await client.snapshot())['jobs'] as List).cast<Map>()) {
        final done = await settle(client, job['jobId'] as String);
        expect(done['state'], 'done');
      }
      expect(await client.items(library), hasLength(2));
    },
  );
  test(
    'unavailable update waits for metadata drain and keeps DB browseable',
    () async {
      final gate = Completer<void>();
      final tier = EnteredTier(gate.future);
      final host = ManagedLibraryHost(
        attach: attach,
        hostRootAvailability: true,
        buildExtractor: () => MediaExtractor([tier]),
      );
      await host.open();
      addTearDown(host.close);
      final client = CadenceClient(host);
      final library = await client.createLibrary('Music', 'music');
      final internal = await client.addRoot(library, '/home/user/Music');
      final external =
          (await client.call('post', '/libraries/$library/roots', {
                'path': '/mnt/card/Music',
                'mountPath': '/mnt/card',
              }))['id']
              as int;
      await observe(client, internal, external, true);
      await tier.entered.future;
      var drained = false;
      final update = observe(client, internal, external, false).then((s) {
        drained = true;
        return s;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(drained, false);
      expect(lease!.available, true);
      gate.complete();
      final status = await update;
      expect(status.quiescentMountPaths, ['/mnt/card']);
      expect(lease!.available, false);
      expect(owned, true);
      expect(await client.items(library), hasLength(2));
    },
  );
  test(
    'mapped roots never read uncovered directory after surprise removal',
    () async {
      final fs = RootFileSystem(media);
      final pinned = TestRootLease(ChrootFileSystem(media, '/physical/card-A'));
      fs.leases['/mnt/card'] = pinned;
      final original = fs.file('/mnt/card/Music/external.mp3');
      pinned.available = false;
      media.file('/mnt/card/Music/external.mp3')
        ..createSync(recursive: true)
        ..writeAsStringSync('wrong card');
      expect(await original.readAsString(), 'external');
      expect(
        await fs.file('/mnt/card/Music/external.mp3').readAsString(),
        'external',
      );
      expect(
        (await fs.directory('/mnt/card/Music').list().toList()).single.path,
        '/mnt/card/Music/external.mp3',
      );
      expect(
        () => original.writeAsStringSync('bad'),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
  test(
    'changed or unknown card identity revalidates files with unchanged stat',
    () async {
      final host = ManagedLibraryHost(
        attach: attach,
        hostRootAvailability: true,
      );
      await host.open();
      addTearDown(host.close);
      final client = CadenceClient(host);
      final library = await client.createLibrary('Music', 'music');
      final internal = await client.addRoot(library, '/home/user/Music');
      final external =
          (await client.call('post', '/libraries/$library/roots', {
                'path': '/mnt/card/Music',
                'mountPath': '/mnt/card',
              }))['id']
              as int;
      await observe(client, internal, external, true);
      Future<Map<String, Object?>> latest() async {
        final jobs = (await client.snapshot())['jobs'] as List;
        return settle(client, (jobs.last as Map)['jobId'] as String);
      }

      expect((await latest())['discovered'], 2);
      var state = await client.volumeStatus();
      await client.setRootAvailability(
        expectedId: state.id!,
        expectedGeneration: state.generation!,
        roots: [
          RootAvailability(rootId: internal, available: true),
          RootAvailability(
            rootId: external,
            available: true,
            mountId: 'card-A',
            sourceId: 'different-card',
          ),
        ],
      );
      expect((await latest())['discovered'], 1);
      state = await client.volumeStatus();
      await client.setRootAvailability(
        expectedId: state.id!,
        expectedGeneration: state.generation!,
        roots: [
          RootAvailability(rootId: internal, available: true),
          RootAvailability(
            rootId: external,
            available: true,
            mountId: 'card-A',
          ),
        ],
      );
      expect((await latest())['discovered'], 1);
      expect(await client.items(library), hasLength(2));
    },
  );
}
