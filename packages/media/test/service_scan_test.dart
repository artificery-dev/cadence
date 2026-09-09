import 'test_filesystem.dart';
import 'dart:async';

import 'package:cadence_media/cadence_media.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart'
    hide test, setUp, tearDown, setUpAll, tearDownAll, addTearDown;

import 'fixtures.dart';

/// Polls the status route until the scan lands somewhere terminal —
/// through the same client the app would use, so the wire shape is on
/// trial too. [after] insists on an ending newer than the one given,
/// which is how a rescan is told apart from the scan before it.
Future<ScanStatus> settle(
  MediaClient client,
  int libraryId, {
  DateTime? after,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (true) {
    final status = await client.scanStatus(libraryId);
    final finishedAt = status.finishedAt;
    if (!status.running &&
        status.state != ScanState.idle &&
        finishedAt != null &&
        (after == null || finishedAt.isAfter(after))) {
      return status;
    }
    if (DateTime.now().isAfter(deadline)) {
      fail('scan of library $libraryId never settled: ${status.state}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void _copy(String fixture, String destination) =>
    mediaFileSystem.file(fixture).copySync(destination);

/// A desk that keeps score — how many times the watcher knocked.

/// A tier that answers only when the test says so — the scan it serves
/// stays running for exactly as long as the assertions need it to.
class _GatedTier implements MetadataExtractor {
  _GatedTier(this.open);

  final Future<void> open;

  @override
  bool handles(MediaKind kind, String extension) => true;

  @override
  Future<ExtractionResult?> extract(String path, MediaKind kind) async {
    await open;
    return null;
  }
}

void main() => memoryTests(registerTests);
void registerTests() {
  group('service scan routes', () {
    late MediaClient client;
    late Directory temp;

    setUp(() {
      client = MediaClient.direct(MediaDatabase(NativeDatabase.memory()));
      temp = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_service_scan_',
      );
    });

    tearDown(() async {
      await client.close();
      temp.deleteSync(recursive: true);
    });

    test('roots are listed, added, removed', () async {
      final libraryId = await client.createLibrary('Music', LibraryType.music);
      expect(await client.listRoots(libraryId), isEmpty);

      final rootId = await client.addRoot(libraryId, temp.path);
      final roots = await client.listRoots(libraryId);
      expect(roots.single.id, rootId);
      expect(roots.single.libraryId, libraryId);
      expect(roots.single.path, temp.path);

      expect(await client.removeRoot(libraryId, rootId), isTrue);
      expect(await client.listRoots(libraryId), isEmpty);
      expect(
        await client.removeRoot(libraryId, rootId),
        isFalse,
        reason: 'a root already gone is a 404, not a shrug',
      );
    });

    test('root mistakes answer with their proper statuses', () async {
      final libraryId = await client.createLibrary('Music', LibraryType.music);

      final notDir = await client.send(
        ServiceMethod.post,
        '/libraries/$libraryId/roots',
        {'path': p.join(temp.path, 'nowhere')},
      );
      expect(notDir.status, 400);

      await client.addRoot(libraryId, temp.path);
      final duplicate = await client.send(
        ServiceMethod.post,
        '/libraries/$libraryId/roots',
        {'path': temp.path},
      );
      expect(duplicate.status, 409);

      final lostLibrary = await client.send(
        ServiceMethod.post,
        '/libraries/999/roots',
        {'path': temp.path},
      );
      expect(lostLibrary.status, 404);

      final lostRoot = await client.send(
        ServiceMethod.delete,
        '/libraries/$libraryId/roots/999',
      );
      expect(lostRoot.status, 404);
    });

    test('a never-scanned library reports bare idle', () async {
      final libraryId = await client.createLibrary('Empty', LibraryType.music);

      final raw = await client.send(
        ServiceMethod.get,
        '/libraries/$libraryId/scan',
      );
      expect(raw.status, 200);
      expect(raw.body, {'state': 'idle'});

      final status = await client.scanStatus(libraryId);
      expect(status.state, ScanState.idle);
      expect(status.seen, 0);
      expect(status.startedAt, isNull);
      expect(status.running, isFalse);

      expect(
        await client.cancelScan(libraryId),
        isFalse,
        reason: 'nothing running, nothing cancelled — still a 200',
      );

      final lost = await client.send(ServiceMethod.post, '/libraries/999/scan');
      expect(lost.status, 404);
    });

    test('a scan runs end to end and lands items', () async {
      final libraryId = await client.createLibrary('Music', LibraryType.music);
      _copy(Fixtures.id3v23Mp3, p.join(temp.path, 'Track One.mp3'));
      _copy(Fixtures.taggedFlac, p.join(temp.path, 'Track Two.flac'));
      _copy(Fixtures.lyricsLrc, p.join(temp.path, 'Track One.lrc'));
      _copy(Fixtures.coverJpg, p.join(temp.path, 'cover.jpg'));
      await client.addRoot(libraryId, temp.path);

      final outcome = await client.scan(libraryId);
      expect(outcome.status, 202);
      expect(outcome.accepted, isTrue);

      final status = await settle(client, libraryId);
      expect(status.state, ScanState.done);
      expect(status.seen, 2);
      expect(status.added, 2);
      expect(status.errors, isEmpty);
      expect(status.errorCount, 0);
      expect(
        status.sidecars,
        3,
        reason: 'lyrics for Track One, folder art for both tracks',
      );
      expect(status.artwork, greaterThan(0));
      expect(status.startedAt, isNotNull);
      expect(status.finishedAt, isNotNull);
      expect(status.elapsed, greaterThanOrEqualTo(Duration.zero));

      final items = await client.audioItems(libraryId);
      expect(items, hasLength(2));
      for (final item in items) {
        expect(item.metadata.title, allOf(isNotNull, isNotEmpty));
      }
      expect({
        for (final item in items)
          for (final tag in item.tags) tag.canonical,
      }, containsAll(['kind/audio', 'format/mp3', 'format/flac']));

      // Nothing changed, so a rescan touches nothing.
      expect((await client.scan(libraryId)).status, 202);
      final again = await settle(client, libraryId, after: status.finishedAt);
      expect(again.state, ScanState.done);
      expect(again.seen, 2);
      expect(again.added, 0);
      expect(again.updated, 0);
    });

    test('a second start answers 409 and a cancel is honoured', () async {
      final db = MediaDatabase(NativeDatabase.memory());
      final gate = Completer<void>();
      final coordinator = ScanCoordinator(
        db,
        scanner: LibraryScanner(
          db,

          buildExtractor: () => MediaExtractor([_GatedTier(gate.future)]),
          concurrency: 1,
          batchSize: 1,
        ),
      );
      final gated = MediaClient.direct(
        db,
        service: MediaService(db, coordinator: coordinator),
      );
      addTearDown(gated.close);

      final libraryId = await gated.createLibrary('Slow', LibraryType.music);
      _copy(Fixtures.id3v23Mp3, p.join(temp.path, 'a.mp3'));
      _copy(Fixtures.id3v24Mp3, p.join(temp.path, 'b.mp3'));
      await gated.addRoot(libraryId, temp.path);

      expect((await gated.scan(libraryId)).status, 202);

      final second = await gated.send(
        ServiceMethod.post,
        '/libraries/$libraryId/scan',
      );
      expect(second.status, 409);

      expect(await gated.cancelScan(libraryId), isTrue);
      gate.complete();

      final status = await settle(gated, libraryId);
      expect(status.state, ScanState.cancelled);
      expect(
        await gated.cancelScan(libraryId),
        isFalse,
        reason: 'cancelling twice is polite and answers false',
      );
    });

    test('scan-all queues every library and drains them', () async {
      final music = await client.createLibrary('Music', LibraryType.music);
      final walls = await client.createLibrary('Walls', LibraryType.images);
      final musicDir = mediaFileSystem.directory(p.join(temp.path, 'music'))
        ..createSync();
      final wallsDir = mediaFileSystem.directory(p.join(temp.path, 'walls'))
        ..createSync();
      _copy(Fixtures.id3v23Mp3, p.join(musicDir.path, 'song.mp3'));
      _copy(Fixtures.tinyPng, p.join(wallsDir.path, 'wall.png'));
      await client.addRoot(music, musicDir.path);
      await client.addRoot(walls, wallsDir.path);

      final raw = await client.send(ServiceMethod.post, '/scan');
      expect(raw.status, 202);
      expect(((raw.body['queued'] as List).cast<int>()).toSet(), {
        music,
        walls,
      });

      final musicStatus = await settle(client, music);
      final wallsStatus = await settle(client, walls);
      expect(musicStatus.state, ScanState.done);
      expect(wallsStatus.state, ScanState.done);
      expect(musicStatus.added, 1);
      expect(wallsStatus.added, 1);
      expect(await client.mediaItems(music), hasLength(1));
      expect(await client.mediaItems(walls), hasLength(1));

      // The typed door queues the same way.
      expect((await client.scanAll()).toSet(), {music, walls});
      final musicAgain = await settle(
        client,
        music,
        after: musicStatus.finishedAt,
      );
      final wallsAgain = await settle(
        client,
        walls,
        after: wallsStatus.finishedAt,
      );
      expect(musicAgain.state, ScanState.done);
      expect(wallsAgain.state, ScanState.done);
      expect(musicAgain.added, 0);
      expect(wallsAgain.added, 0);
    });
  });
}
