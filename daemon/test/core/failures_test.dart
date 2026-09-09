import 'dart:async';
import 'package:test/test.dart';
import 'package:drift/native.dart';
import 'package:file/memory.dart';
import 'package:cadence_media/cadence_media.dart';
import 'package:cadenced/host.dart';
import 'host_test.dart' show settle;

class ArtTier implements MetadataExtractor {
  int reads = 0;
  @override
  bool handles(MediaKind kind, String extension) => true;
  @override
  Future<ExtractionResult?> extract(String path, MediaKind kind) async {
    reads++;
    return const ExtractionResult(
      metadata: AudioMetadata(title: 'Art'),
      artwork: [
        ExtractedArtwork(
          bytes: [1, 2, 3],
          mime: 'image/jpeg',
          role: ArtworkRole.thumbnail,
        ),
      ],
    );
  }
}

void main() {
  test(
    'injected read failures are reported without marking known files missing',
    () async {
      var deny = false;
      final fs = MemoryFileSystem.test(
        opHandle: (path, op) {
          if (deny &&
              path.endsWith('a.mp3') &&
              (op == FileSystemOp.open || op == FileSystemOp.read)) {
            throw FileSystemException('Permission denied', path);
          }
        },
      );
      final file = fs.file('/music/a.mp3')
        ..createSync(recursive: true)
        ..writeAsStringSync('old');
      final db = MediaDatabase(NativeDatabase.memory());
      final host = await MediaHost.open(database: db, fileSystem: fs);
      addTearDown(host.close);
      final id = (await host.request('post', '/libraries', {
        'name': 'Music',
        'type': 'music',
      }))['id'];
      await host.request('post', '/libraries/$id/roots', {'path': '/music'});
      await settle(
        host,
        (await host.request('post', '/libraries/$id/scan'))['jobId'] as String,
      );
      file.writeAsStringSync('new bytes');
      deny = true;
      final job = await settle(
        host,
        (await host.request('post', '/libraries/$id/scan'))['jobId'] as String,
      );
      expect(job['errorCount'], 1);
      expect((await db.select(db.files).get()).single.missingSince, isNull);
      fs.directory('/music').renameSync('/removed');
      final missing = await settle(
        host,
        (await host.request('post', '/libraries/$id/scan'))['jobId'] as String,
      );
      expect(missing['missing'], 0);
    },
  );
  test('artwork is cached as bytes through the injected filesystem', () async {
    final fs = MemoryFileSystem.test();
    fs.file('/music/a.mp3')
      ..createSync(recursive: true)
      ..writeAsStringSync('a');
    final tier = ArtTier();
    final host = await MediaHost.open(
      database: MediaDatabase(NativeDatabase.memory()),
      fileSystem: fs,
      cacheDirectory: '/cache',
      buildExtractor: () => MediaExtractor([tier]),
    );
    addTearDown(host.close);
    final lib = (await host.request('post', '/libraries', {
      'name': 'Music',
      'type': 'music',
    }))['id'];
    await host.request('post', '/libraries/$lib/roots', {'path': '/music'});
    await settle(
      host,
      (await host.request('post', '/libraries/$lib/scan'))['jobId'] as String,
    );
    final items =
        (await host.request('get', '/libraries/$lib/items'))['items'] as List;
    final fileId = (items.single as Map)['fileId'] as int;
    // The imported queue renders only valid image bytes; directly seed a cached
    // artwork row to isolate cache transport from codec behavior covered elsewhere.
    await withMediaFileSystem(
      fs,
      () => ScannerRepository(host.db).replaceArtwork(
        fileId,
        ArtworkRole.thumbnail,
        [
          const ExtractedArtwork(
            bytes: [1, 2, 3],
            mime: 'image/jpeg',
            role: ArtworkRole.thumbnail,
          ),
        ],
      ),
    );
    expect(
      await Future.wait(List.generate(8, (_) => host.artwork(fileId))),
      everyElement([1, 2, 3]),
    );
    expect(await host.artwork(fileId), [1, 2, 3]);
    expect(fs.directory('/cache').listSync(), hasLength(1));
  });
  test(
    'cancel during a large walk stops before extraction and missing marking',
    () async {
      final fs = MemoryFileSystem.test();
      for (var i = 0; i < 1000; i++) {
        fs.file('/music/$i.mp3')
          ..createSync(recursive: true)
          ..writeAsStringSync('data');
      }
      final host = await MediaHost.open(
        database: MediaDatabase(NativeDatabase.memory()),
        fileSystem: fs,
      );
      addTearDown(host.close);
      final lib = (await host.request('post', '/libraries', {
        'name': 'Music',
        'type': 'music',
      }))['id'];
      await host.request('post', '/libraries/$lib/roots', {'path': '/music'});
      final job = await host.request('post', '/libraries/$lib/scan');
      await host.request('delete', '/jobs/${job['jobId']}');
      final result = await settle(host, job['jobId'] as String);
      expect(result['state'], 'cancelled');
      expect(result['added'], 0);
      expect(result['seen'] as int, lessThan(1000));
    },
  );
}
