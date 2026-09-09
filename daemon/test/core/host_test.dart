import 'dart:async';
import 'package:test/test.dart';
import 'package:drift/native.dart';
import 'package:cadence_media/cadence_media.dart';
import 'package:cadence_client/cadence_client.dart';
import 'package:cadenced/host.dart';
import 'package:file/memory.dart';

class GateTier implements MetadataExtractor {
  GateTier(this.gate);
  final Future<void> gate;
  @override
  bool handles(MediaKind kind, String extension) => true;
  @override
  Future<ExtractionResult?> extract(String path, MediaKind kind) async {
    await gate;
    return const ExtractionResult(metadata: AudioMetadata(title: 'Fixture'));
  }
}

Future<Map<String, Object?>> settle(MediaHost host, String id) async {
  for (var i = 0; i < 500; i++) {
    final job = await host.request('get', '/jobs/$id');
    if (job['finishedAt'] != null) return job;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Job failed to settle');
}

void main() {
  test(
    'jobs survive client replacement, conflict, cancel, and retain status',
    () async {
      final fs = MemoryFileSystem.test();
      fs.file('/music/a.mp3')
        ..createSync(recursive: true)
        ..writeAsStringSync('a');
      final gate = Completer<void>();
      final db = MediaDatabase(NativeDatabase.memory());
      final host = await MediaHost.open(
        database: db,
        fileSystem: fs,
        buildExtractor: () => MediaExtractor([GateTier(gate.future)]),
      );
      addTearDown(host.close);
      final client = CadenceClient(host.connect());
      final library = await client.createLibrary('Music', 'music');
      await client.addRoot(library, '/music');
      final job = await client.scan(library);
      final id = job['jobId'] as String;
      await expectLater(client.scan(library), throwsA(isA<MediaError>()));
      // Embedded host lifetime is independent from views; a new client sees the job.
      await client.close();
      final reconnected = CadenceClient(host.connect());
      expect((await reconnected.snapshot())['jobs'], hasLength(1));
      await reconnected.cancel(id);
      gate.complete();
      expect((await settle(host, id))['state'], 'cancelled');
      final next = await reconnected.scan(library);
      expect((await settle(host, next['jobId'] as String))['state'], 'done');
      expect(await reconnected.items(library), hasLength(1));
      expect((await reconnected.snapshot())['jobs'], hasLength(2));
    },
  );
  test(
    'unfinished durable jobs retry automatically with the same identifier',
    () async {
      final db = MediaDatabase(NativeDatabase.memory());
      await LibraryRepository(db).createLibrary('Music', LibraryType.music);
      await db.customStatement(
        'CREATE TABLE daemon_jobs (id TEXT PRIMARY KEY, body TEXT NOT NULL)',
      );
      await db.customStatement('INSERT INTO daemon_jobs VALUES (?, ?)', [
        'old',
        '{"jobId":"old","libraryId":1,"state":"extracting"}',
      ]);
      final host = await MediaHost.open(
        database: db,
        fileSystem: MemoryFileSystem.test(),
      );
      addTearDown(host.close);
      final job = await settle(host, 'old');
      expect(job['state'], 'done');
      expect(job['attemptCount'], 2);
      expect((job['attempts'] as List).first['state'], 'interrupted');
      expect(job['finishedAt'], isNotNull);
      expect(
        (await host.request('get', '/capabilities'))['restart'],
        'automatic-incremental-retry',
      );
    },
  );
  test('offline roots can be configured before media is mounted', () async {
    final fs = MemoryFileSystem.test();
    final host = await MediaHost.open(
      database: MediaDatabase(NativeDatabase.memory()),
      fileSystem: fs,
    );
    addTearDown(host.close);
    final lib = (await host.request('post', '/libraries', {
      'name': 'Movies',
      'type': 'videos',
    }))['id'];
    await host.request('post', '/libraries/$lib/roots', {
      'path': '/card/Movies',
      'available': false,
    });
    final snapshot = await host.request('get', '/snapshot');
    expect(((snapshot['roots'] as List).single as Map)['available'], false);
    expect(((snapshot['libraries'] as List).single as Map)['type'], 'movies');
    final job = await settle(
      host,
      (await host.request('post', '/libraries/$lib/scan'))['jobId'] as String,
    );
    expect(job['missing'], 0);
    expect(job['errorCount'], 1);
  });
  test('a database connection has one embedded owner', () async {
    final db = MediaDatabase(NativeDatabase.memory());
    final host = await MediaHost.open(
      database: db,
      fileSystem: MemoryFileSystem.test(),
    );
    addTearDown(host.close);
    await expectLater(
      MediaHost.open(database: db, fileSystem: MemoryFileSystem.test()),
      throwsStateError,
    );
  });
  for (final style in [FileSystemStyle.posix, FileSystemStyle.windows]) {
    test(
      'incremental scans, unavailable roots, moves and missing ($style)',
      () async {
        final fs = MemoryFileSystem.test(style: style);
        final root = style == FileSystemStyle.windows ? r'C:\music' : '/music';
        fs.directory(root).createSync(recursive: true);
        final file = fs.file(fs.path.join(root, 'a.mp3'))
          ..writeAsStringSync('initial');
        final db = MediaDatabase(NativeDatabase.memory());
        final host = await MediaHost.open(
          database: db,
          fileSystem: fs,
          buildExtractor: () => MediaExtractor([GateTier(Future.value())]),
        );
        addTearDown(host.close);
        final client = CadenceClient(host.connect());
        final lib = await client.createLibrary('Music', 'music');
        final rootId = await client.addRoot(lib, root);
        Future<Map<String, Object?>> scan() async =>
            settle(host, (await client.scan(lib))['jobId'] as String);
        expect((await scan())['added'], 1);
        expect((await scan())['changed'], 0);
        file.writeAsStringSync('metadata updated content');
        expect((await scan())['updated'], 1);
        final moved = file.renameSync(fs.path.join(root, 'b.mp3'));
        expect((await scan())['moved'], 1);
        await client.call('put', '/libraries/$lib/roots/$rootId', {
          'available': false,
        });
        moved.deleteSync();
        expect((await scan())['missing'], 0);
        expect((await db.select(db.files).get()).single.missingSince, isNull);
        await client.call('put', '/libraries/$lib/roots/$rootId', {
          'available': true,
        });
        expect((await scan())['missing'], 1);
        expect(
          (await db.select(db.files).get()).single.missingSince,
          isNotNull,
        );
      },
    );
  }
  test(
    'symlinks cannot escape roots and missing scopes do not erase records',
    () async {
      final fs = MemoryFileSystem.test();
      fs.file('/outside/secret.mp3')
        ..createSync(recursive: true)
        ..writeAsStringSync('secret');
      fs.directory('/music').createSync();
      fs.link('/music/escape.mp3').createSync('/outside/secret.mp3');
      fs.link('/music/loop').createSync('/music');
      final host = await MediaHost.open(
        database: MediaDatabase(NativeDatabase.memory()),
        fileSystem: fs,
      );
      addTearDown(host.close);
      final client = CadenceClient(host.connect());
      final lib = await client.createLibrary('Music', 'music');
      await client.addRoot(lib, '/music');
      final job = await settle(
        host,
        (await client.scan(lib))['jobId'] as String,
      );
      expect(job['seen'], 0);
      await expectLater(
        client.call('post', '/libraries/$lib/items', {
          'path': '/outside/secret.mp3',
        }),
        throwsA(isA<MediaError>()),
      );
    },
  );
}
