import 'dart:async';
import 'package:cadence_client/cadence_client.dart';
import 'package:cadence_media/cadence_media.dart';
import 'package:cadenced/host.dart';
import 'package:drift/native.dart';
import 'package:file/memory.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';
import 'host_test.dart' show settle;

class MetadataGate implements MetadataExtractor {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  bool handles(MediaKind kind, String extension) => true;
  @override
  Future<ExtractionResult?> extract(String path, MediaKind kind) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return const ExtractionResult(
      metadata: AudioMetadata(title: 'Song', artist: 'Artist', album: 'Album'),
    );
  }
}

void main() {
  test(
    'committed minimal items are browseable before metadata; reconnect gets work',
    () async {
      final fs = MemoryFileSystem.test();
      fs.file('/music/untagged.mp3')
        ..createSync(recursive: true)
        ..writeAsStringSync('audio');
      final gate = MetadataGate();
      final host = await MediaHost.open(
        database: MediaDatabase(NativeDatabase.memory()),
        fileSystem: fs,
        buildExtractor: () => MediaExtractor([gate]),
      );
      addTearDown(() async {
        if (!gate.release.isCompleted) gate.release.complete();
        await host.close();
      });
      final events = <Map<String, Object?>>[];
      final subscription = host.events.listen(events.add);
      addTearDown(subscription.cancel);
      var client = CadenceClient(host.connect());
      final library = await client.createLibrary('Music', 'music');
      await client.addRoot(library, '/music');
      final job = await client.scan(library);
      await gate.entered.future.timeout(const Duration(seconds: 5));
      final minimal = (await client.items(library)).single as Map;
      expect(minimal['path'], '/music/untagged.mp3');
      expect((minimal['metadata'] as Map)['title'], 'untagged');
      expect((minimal['metadata'] as Map)['album'], isNull);
      expect((await client.job(job['jobId'] as String))['phase'], 'metadata');
      expect(
        (await host.db.select(host.db.fileHashes).get()).single.kind,
        HashKind.sampledSha256,
      );
      expect(
        events.where((e) => e['type'] == 'media-item-added'),
        hasLength(1),
      );
      final added = events.singleWhere((e) => e['type'] == 'media-item-added');
      expect(added['itemId'], minimal['id']);
      await client.close();
      client = CadenceClient(host.connect());
      expect((await client.snapshot())['pendingWork'], [
        containsPair('stage', 'metadata'),
      ]);
      expect(await client.items(library), hasLength(1));
      gate.release.complete();
      final done = await settle(host, job['jobId'] as String);
      expect(done['state'], 'done');
      expect(done['discovered'], 1);
      expect(done['enriched'], 1);
      final complete = (await client.items(library)).single as Map;
      expect(complete['id'], minimal['id']);
      expect((complete['metadata'] as Map)['title'], 'Song');
      final update = events.singleWhere(
        (e) => e['type'] == 'media-item-field-update',
      );
      expect(update['fields'], containsPair('album', 'Album'));
      expect(update['revision'] as int, greaterThan(added['revision'] as int));
      expect((await client.snapshot())['pendingWork'], isEmpty);
    },
  );

  test(
    'restarting mid-enrichment resumes metadata without hashing again',
    () async {
      final fs = MemoryFileSystem.test();
      fs.file('/music/a.mp3')
        ..createSync(recursive: true)
        ..writeAsStringSync('a');
      final raw = sqlite.sqlite3.openInMemory();
      MediaDatabase database() => MediaDatabase(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      final gate = MetadataGate();
      var host = await MediaHost.open(
        database: database(),
        fileSystem: fs,
        buildExtractor: () => MediaExtractor([gate]),
      );
      addTearDown(() async {
        if (!gate.release.isCompleted) gate.release.complete();
        await host.close();
        raw.close();
      });
      var client = CadenceClient(host.connect());
      final library = await client.createLibrary('Music', 'music');
      await client.addRoot(library, '/music');
      final job = await client.scan(library);
      await gate.entered.future.timeout(const Duration(seconds: 5));
      final id = ((await client.items(library)).single as Map)['id'];
      final closing = host.close();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.release.complete();
      await closing;
      host = await MediaHost.open(
        database: database(),
        fileSystem: fs,
        buildExtractor: () => MediaExtractor([gate]),
      );
      client = CadenceClient(host.connect());
      final done = await settle(host, job['jobId'] as String);
      expect(done['state'], 'done');
      expect(done['attemptCount'], 2);
      expect(done['discovered'], 0, reason: 'Committed identity is reused');
      expect(done['enriched'], 1);
      expect(((await client.items(library)).single as Map)['id'], id);
      expect((await client.snapshot())['pendingWork'], isEmpty);
    },
  );

  test(
    'Scan never hashes; each Discover result commits before slower files',
    () async {
      for (final style in [FileSystemStyle.posix, FileSystemStyle.windows]) {
        var phase = 'setup';
        final fs = MemoryFileSystem.test(
          style: style,
          opHandle: (path, operation) {
            if (phase == 'scan' &&
                (operation == FileSystemOp.open ||
                    operation == FileSystemOp.read)) {
              fail('Scan read file contents: $path');
            }
          },
        );
        final root = style == FileSystemStyle.windows ? r'C:\music' : '/music';
        for (final name in ['fast.mp3', 'slow.mp3']) {
          fs.file(fs.path.join(root, name))
            ..createSync(recursive: true)
            ..writeAsStringSync(name);
        }
        final db = MediaDatabase(NativeDatabase.memory());
        final library = await LibraryRepository(
          db,
        ).createLibrary('Music', LibraryType.music);
        final slow = Completer<void>();
        final fastCommitted = Completer<void>();
        final hashCalls = <String>[];
        try {
          await withMediaFileSystem(fs, () async {
            await ScannerRepository(db).addRoot(library, root);
            final scanner = LibraryScanner(
              db,
              fileSystem: fs,
              policy: const ScanPolicy(artwork: ArtworkPolicy.none),
              hashFile: (path) async {
                expect(phase, 'discover');
                expect(
                  await db.customSelect('SELECT * FROM scan_work').get(),
                  hasLength(2),
                );
                hashCalls.add(path);
                if (path.endsWith('slow.mp3')) await slow.future;
                return sampledSha256OfFile(path);
              },
              onChange: (event) {
                if (event['type'] == 'scan-phase-changed')
                  phase = event['phase'] as String;
                if (event['type'] == 'media-item-added' &&
                    (event['path'] as String).endsWith('fast.mp3')) {
                  fastCommitted.complete();
                }
              },
            );
            final scanning = scanner.scan(library);
            await fastCommitted.future.timeout(const Duration(seconds: 5));
            final rows = await db.select(db.libraryItems).get();
            expect(rows, hasLength(1));
            expect(phase, 'discover');
            slow.complete();
            final result = await scanning;
            expect(result.discovered, 2);
            expect(result.enriched, 2);
            expect(
              hashCalls,
              hasLength(2),
              reason: 'Metadata must not hash again',
            );
          });
        } finally {
          if (!slow.isCompleted) slow.complete();
          await db.close();
        }
      }
    },
  );
}
