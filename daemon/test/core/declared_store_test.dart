import 'package:cadence_client/cadence_client.dart';
import 'dart:typed_data';
import 'package:cadence_media/cadence_media.dart' hide FileSystem;
import 'package:cadenced/host.dart';
import 'package:drift/native.dart';
import 'package:cadenced/declared_store.dart';
import 'package:cadenced/root_access.dart';
import 'package:cadenced/volume.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';
import 'volume_test.dart' show MemoryCard, settle;

class _MediaLease implements RootLease {
  _MediaLease(this.fileSystem, this.mountPath);
  @override
  final FileSystem fileSystem;
  @override
  final String mountPath;
  @override
  bool available = true;
  @override
  void close() => available = false;
}

class _Metadata extends MemoryCard implements RootedStoreAttachment {
  _Metadata(FileSystem fs) : super(fs, () {});
  @override
  bool get removable => false;
}

void main() {
  test(
    'artwork cache uses metadata filesystem rather than media filesystem',
    () async {
      final media = MemoryFileSystem.test();
      final metadata = MemoryFileSystem.test();
      final db = MediaDatabase(NativeDatabase.memory());
      final host = await MediaHost.open(
        database: db,
        fileSystem: media,
        cacheFileSystem: metadata,
        cacheDirectory: '/.cadence/cache',
        autoStartJobs: false,
      );
      addTearDown(host.close);
      final file = await db
          .into(db.files)
          .insert(
            FilesCompanion.insert(
              path: '/Music/song.mp3',
              sizeBytes: 1,
              modifiedAt: DateTime(2026),
              kind: MediaKind.audio,
              metadata: '{}',
            ),
          );
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      await db
          .into(db.artworks)
          .insert(
            ArtworksCompanion.insert(
              fileId: file,
              role: ArtworkRole.embedded,
              mime: 'image/png',
              data: bytes,
            ),
          );
      expect(await host.artwork(file), bytes);
      expect(await host.artwork(file), bytes);
      expect(media.directory('/.cadence').existsSync(), false);
      expect(
        (metadata.directory('/.cadence/cache').listSync().single as File)
            .readAsBytesSync(),
        bytes,
      );
    },
  );
  test(
    'internal metadata retains independent card paths across restart and absence',
    () async {
      final metadata = MemoryFileSystem.test()
        ..directory('/.cadence').createSync();
      final media = MemoryFileSystem.test();
      media.file('/Music/song.mp3')
        ..createSync(recursive: true)
        ..writeAsStringSync('song');
      _MediaLease? lease;
      var present = true;
      ManagedLibraryHost make({String? declared = '/mnt/sd'}) =>
          ManagedLibraryHost(
            initialize: true,
            hostRootAvailability: true,
            attach: ({required initialize}) async => DeclaredMediaStore(
              metadata: _Metadata(metadata),
              declaredMediaRoot: declared,
              metadataRoot: '/home/tempo',
              mediaMount: declared == null ? null : '/mnt/sd',
              acquireMediaRoot: (root, mount, id) {
                if (!present || id != 'mount-A')
                  throw StateError('Wrong mount');
                return lease = _MediaLease(media, '/mnt/sd');
              },
              playerPath: (path) => path,
            ),
          );
      var host = make();
      await host.open();
      var client = CadenceClient(host);
      final created = await client.call('post', '/libraries', {
        'name': 'Music',
        'type': 'music',
      });
      final library = created['id'] as int;
      final root = await client.addRoot(library, '/Music');
      Future<void> observe(bool available) async {
        final status = await client.volumeStatus();
        await client.setRootAvailability(
          expectedId: status.id!,
          expectedGeneration: status.generation!,
          roots: [
            RootAvailability(
              rootId: root,
              available: available,
              mountId: available ? 'mount-A' : null,
              sourceId: 'card-A',
            ),
          ],
        );
      }

      final initial = await client.volume();
      expect(initial['mediaRoot'], '/mnt/sd');
      expect(initial['pathStyle'], 'volume-posix');
      expect(initial['rootAvailabilityReady'], false);
      await expectLater(client.scan(library), throwsA(isA<MediaError>()));
      await observe(true);
      Future<Map<String, Object?>> latest() async {
        final jobs = (await client.snapshot())['jobs'] as List;
        return settle(client, (jobs.last as Map)['jobId'] as String);
      }

      expect((await latest())['discovered'], 1);
      final original = (await client.items(library)).single as Map;
      expect(original['path'], '/Music/song.mp3');
      expect(media.directory('/.cadence').existsSync(), false);
      expect(metadata.file('/.cadence/library.sqlite').existsSync(), true);
      await observe(false);
      expect(lease!.available, false);
      expect((await client.volumeStatus()).quiescentMountPaths, ['/mnt/sd']);
      expect(await client.items(library), [original]);
      await host.close();
      present = false;
      host = make(declared: null);
      await host.open();
      client = CadenceClient(host);
      expect((await client.volume())['id'], initial['id']);
      expect(await client.items(library), [original]);
      await expectLater(observe(true), throwsA(isA<MediaError>()));
      expect((await client.volumeStatus()).rootAvailabilityReady, false);
      present = true;
      await observe(true);
      expect((await latest())['discovered'], 0);
      expect(await client.items(library), [original]);
      await host.close();
      final retargeted = make(declared: '.');
      await expectLater(
        retargeted.open(),
        throwsA(
          isA<MediaError>().having(
            (e) => e.code,
            'code',
            'media_root_mismatch',
          ),
        ),
      );
      await retargeted.close();
    },
  );

  test(
    'home media uses dot base with no removable-mount observation',
    () async {
      final metadata = MemoryFileSystem.test()
        ..directory('/.cadence').createSync();
      final media = MemoryFileSystem.test();
      media.file('/Music/home.mp3')
        ..createSync(recursive: true)
        ..writeAsStringSync('home song');
      final host = ManagedLibraryHost(
        initialize: true,
        hostRootAvailability: true,
        attach: ({required initialize}) async => DeclaredMediaStore(
          metadata: _Metadata(metadata),
          declaredMediaRoot: '.',
          metadataRoot: '/home/tempo',
          mediaMount: null,
          acquireMediaRoot: (root, mount, id) {
            expect(id, null);
            return _MediaLease(media, '/home/tempo');
          },
          playerPath: (path) => path,
        ),
      );
      await host.open();
      addTearDown(host.close);
      final client = CadenceClient(host);
      final library = await client.createLibrary('Music', 'music');
      final root = await client.addRoot(library, '/Music');
      final state = await client.volumeStatus();
      await client.setRootAvailability(
        expectedId: state.id!,
        expectedGeneration: state.generation!,
        roots: [RootAvailability(rootId: root, available: true)],
      );
      final jobs = (await client.snapshot())['jobs'] as List;
      expect(
        (await settle(
          client,
          (jobs.single as Map)['jobId'] as String,
        ))['discovered'],
        1,
      );
      expect(
        ((await client.items(library)).single as Map)['path'],
        '/Music/home.mp3',
      );
      expect((await client.volume())['resolvedMediaRoot'], '/home/tempo');
    },
  );
}
