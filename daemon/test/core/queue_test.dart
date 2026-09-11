import 'dart:async';
import 'dart:convert';
import 'package:cadence_client/cadence_client.dart';
import 'package:cadence_media/cadence_media.dart';
import 'package:cadenced/host.dart';
import 'package:drift/native.dart';
import 'package:file/memory.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';
import 'host_test.dart' show settle;

class GateExtractor implements MetadataExtractor {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  bool handles(MediaKind kind, String extension) => true;
  @override
  Future<ExtractionResult?> extract(String path, MediaKind kind) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return const ExtractionResult(metadata: AudioMetadata(title: 'Fixture'));
  }
}

void main() {
  test(
    'FIFO queue survives graceful host restart; cancellation stays terminal',
    () async {
      final fs = MemoryFileSystem.test();
      for (final root in ['one', 'two', 'three']) {
        fs.file('/$root/a.mp3')
          ..createSync(recursive: true)
          ..writeAsStringSync(root);
      }
      final raw = sqlite.sqlite3.openInMemory();
      final gate = GateExtractor();
      MediaDatabase database() => MediaDatabase(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      var host = await MediaHost.open(
        database: database(),
        fileSystem: fs,
        buildExtractor: () => MediaExtractor([gate]),
      );
      addTearDown(() async {
        await host.close();
        raw.close();
      });
      var client = CadenceClient(host.connect());
      final libs = <int>[];
      for (final root in ['one', 'two', 'three']) {
        final lib = await client.createLibrary(root, 'music');
        await client.addRoot(lib, '/$root');
        libs.add(lib);
      }
      final first = (await client.scan(libs[0]))['jobId'] as String;
      await gate.entered.future.timeout(const Duration(seconds: 5));
      final second = (await client.scan(libs[1]))['jobId'] as String;
      final third = (await client.scan(libs[2]))['jobId'] as String;
      expect((await client.job(second))['state'], 'queued');
      await expectLater(client.scan(libs[1]), throwsA(isA<MediaError>()));
      await client.cancel(third);
      expect((await client.job(third))['state'], 'cancelled');
      expect((await client.job(first))['finishedAt'], isNull);
      await client.close();
      client = CadenceClient(host.connect());
      expect((await client.snapshot())['jobs'], hasLength(3));
      final closing = host.close();
      // Let close signal cooperative cancellation before releasing extraction.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.release.complete();
      await closing;
      host = await MediaHost.open(database: database(), fileSystem: fs);
      client = CadenceClient(host.connect());
      final recovered = await settle(host, first);
      expect(recovered['state'], 'done');
      expect(recovered['attemptCount'], 2);
      expect((recovered['attempts'] as List).first['state'], 'interrupted');
      expect((recovered['attempts'] as List).first['reason'], 'host_shutdown');
      final next = await settle(host, second);
      expect(next['state'], 'done');
      expect(next['attemptCount'], 1);
      expect(
        DateTime.parse(
          next['startedAt'] as String,
        ).isBefore(DateTime.parse(recovered['finishedAt'] as String)),
        isFalse,
      );
      expect((await client.job(third))['state'], 'cancelled');
      expect((await client.job(third))['attemptCount'], 0);
      expect(await client.items(libs[0]), hasLength(1));
      expect(await client.items(libs[1]), hasLength(1));
      expect(await client.items(libs[2]), isEmpty);
      // Every state the queue put on the wire is a ScanState member — in
      // the job records and in their attempt histories alike — so a client
      // parsing with ScanState.values.byName never throws on one.
      for (final job in (await client.snapshot())['jobs'] as List) {
        final record = (job as Map).cast<String, Object?>();
        ScanState.values.byName(record['state'] as String);
        for (final attempt in record['attempts'] as List) {
          ScanState.values.byName((attempt as Map)['state'] as String);
        }
      }
    },
  );

  test(
    'restart honors durable cancellation and migrates old interrupted jobs',
    () async {
      final db = MediaDatabase(NativeDatabase.memory());
      final lib = await LibraryRepository(
        db,
      ).createLibrary('Music', LibraryType.music);
      await db.customStatement(
        'CREATE TABLE daemon_jobs (id TEXT PRIMARY KEY, body TEXT NOT NULL)',
      );
      for (final entry in [
        {
          'jobId': 'cancelled',
          'libraryId': lib,
          'state': 'extracting',
          'cancelRequested': true,
        },
        {
          'jobId': 'legacy',
          'libraryId': lib,
          'state': 'interrupted',
          'finishedAt': '2026-01-01T00:00:00Z',
        },
        {'jobId': 'invalid-library', 'libraryId': 999, 'state': 'queued'},
        {'jobId': 'next', 'libraryId': lib, 'state': 'queued'},
      ]) {
        await db.customStatement('INSERT INTO daemon_jobs VALUES (?, ?)', [
          entry['jobId'],
          jsonEncode(entry),
        ]);
      }
      final host = await MediaHost.open(
        database: db,
        fileSystem: MemoryFileSystem.test(),
      );
      addTearDown(host.close);
      expect((await settle(host, 'cancelled'))['state'], 'cancelled');
      final legacy = await settle(host, 'legacy');
      expect(legacy['state'], 'done');
      expect(legacy['attemptCount'], 2);
      expect((legacy['attempts'] as List).first['state'], 'interrupted');
      expect((await settle(host, 'invalid-library'))['state'], 'failed');
      expect((await settle(host, 'next'))['state'], 'done');
    },
  );
}
