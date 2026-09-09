import '../local_test_scope.dart';
import 'package:file/local.dart';

import 'dart:async';
import 'dart:io';

import 'package:cadence_media/cadence_media.dart'
    hide File, Directory, FileSystemEntity;
import 'package:cadence_media/src/extract/audio_extractor.dart';
import 'package:cadence_media/src/extract/document_extractor.dart';
import 'package:cadence_media/src/extract/image_extractor.dart';
import 'package:cadenced/probe.dart';
import 'package:cadence_media/src/extract/video_extractor.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart'
    hide test, setUp, tearDown, setUpAll, tearDownAll, addTearDown;

import '../../../packages/media/test/fixtures.dart';

/// The whole machine, on trial as one: a fixture tree stood up in a temp
/// directory, four typed libraries claiming its corners, and every scan
/// booked through the service routes the app itself would call. The
/// assertions then go where the app cannot — straight into the tables —
/// and check what actually landed: items and their tags, typed fields per
/// format, artwork by role, sidecars by kind, fingerprints by algorithm,
/// and the search index fed along the way.
///
/// The tree stands twice: once with the default stack (the native probe
/// aboard when its library can be found or built), and once with the pure
/// Dart tiers alone — proving the system needs no Rust to stand up.
/// `CADENCE_PROBE_PATH` cannot play the absence: probe.dart treats the
/// env var as the *first* candidate, not the only one, so a built library
/// in `build/rust` would still be found. The probeless flavour
/// simply leaves the tier out, which is exactly what absence looks like.
///
/// Two quirks are honoured, not fought: the Dart tier computes no pHash
/// for the TIFF fixture (package:image cannot decode its packbits data),
/// so that assertion follows the probe; and durations are never pinned to
/// the generated length, which containers round each their own way.
void main() => withMediaFileSystem(const LocalFileSystem(), registerTests);
void registerTests() {
  setUpAll(() {
    _probeAround = _loadProbe() != null;
    if (!_probeAround) {
      print(
        'scan_integration_test: no native probe — probe-gated assertions '
        'will expect its absence',
      );
    }
  });

  _treeSuite(
    'with the default stack',
    build: () => MediaExtractor([
      ...defaultMediaExtractor().tiers,
      ?ProbeExtractor.tryLoad(),
    ]),
    probeRides: true,
  );
  _treeSuite('with the pure tiers alone', build: _pureTiers, probeRides: false);

  group('the lifecycle', () {
    late Directory temp;
    late MediaDatabase db;
    late MediaClient client;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('cadence_scan_life_');
      db = MediaDatabase(NativeDatabase.memory());
      client = MediaClient.direct(db);
    });

    tearDown(() async {
      await client.close();
      temp.deleteSync(recursive: true);
    });

    test(
      'an unchanged rescan touches nothing; a rewrite updates in place',
      () async {
        final lib = await client.createLibrary('Music', LibraryType.music);
        await client.addRoot(lib, temp.path);
        final track = p.join(temp.path, 'Track One.mp3');
        File(Fixtures.id3v23Mp3).copySync(track);

        final first = await _scan(client, lib);
        expect(first.added, 1);
        final item = (await client.mediaItems(lib)).single;
        expect((item.metadata as AudioMetadata).title, 'Sine of the Times');
        final file = (await db.select(db.files).get()).single;
        final shaBefore = await _sha256Row(db, file.id);
        expect(shaBefore, matches(RegExp(r'^[0-9a-f]{64}$')));

        final second = await _scan(client, lib, after: first.finishedAt);
        expect(second.seen, 1);
        expect(second.added, 0);
        expect(
          second.updated,
          0,
          reason: 'same size, same mtime — nothing to redo',
        );

        // A rewrite, padded until the size disagrees so the diff cannot
        // mistake it for the same file landing in the same second.
        final replacement = File(Fixtures.id3v24Mp3).readAsBytesSync().toList();
        while (replacement.length == file.sizeBytes) {
          replacement.add(0);
        }
        File(track).writeAsBytesSync(replacement, flush: true);

        final third = await _scan(client, lib, after: second.finishedAt);
        expect(third.added, 0);
        expect(third.updated, 1);
        final updated = (await client.mediaItems(lib)).single;
        expect(updated.id, item.id, reason: 'the item survives the rewrite');
        expect(updated.fileId, item.fileId);
        expect((updated.metadata as AudioMetadata).title, 'Four Forty');
        expect(await _sha256Row(db, file.id), isNot(shaBefore));

        // The search index moved with the metadata, not after it.
        expect(await client.search('four forty'), contains(item.id));
        expect(await client.search('sine'), isNot(contains(item.id)));
      },
    );

    test('a move keeps the item, its tags, and its history', () async {
      final lib = await client.createLibrary('Music', LibraryType.music);
      await client.addRoot(lib, temp.path);
      final track = p.join(temp.path, 'Track One.mp3');
      File(Fixtures.id3v23Mp3).copySync(track);

      final first = await _scan(client, lib);
      expect(first.added, 1);
      final item = (await client.mediaItems(lib)).single;
      await client.recordPlay(item.id, completed: true);

      final moved = p.join(temp.path, 'Disc One', 'Track One.mp3');
      Directory(p.dirname(moved)).createSync();
      File(track).renameSync(moved);

      final second = await _scan(client, lib, after: first.finishedAt);
      expect(second.moved, 1);
      expect(second.added, 0);
      expect(second.missing, 0);

      final row = (await db.select(db.files).get()).single;
      expect(row.id, item.fileId, reason: 'recognised by sha256, not reborn');
      expect(row.path, moved);
      expect(row.missingSince, isNull);
      final after = (await client.mediaItems(lib)).single;
      expect(after.id, item.id);
      expect(after.path, moved);
      final plays = await db.select(db.plays).get();
      expect(
        plays.single.itemId,
        item.id,
        reason: 'history rides with the item, wherever the file goes',
      );
    });

    test('absence is stamped, and coming back lifts the stamp', () async {
      final lib = await client.createLibrary('Music', LibraryType.music);
      await client.addRoot(lib, temp.path);
      final stays = p.join(temp.path, 'Stays.mp3');
      final goes = p.join(temp.path, 'Goes.mp3');
      File(Fixtures.id3v23Mp3).copySync(stays);
      File(Fixtures.id3v24Mp3).copySync(goes);

      final first = await _scan(client, lib);
      expect(first.added, 2);
      final goesId = (await db.select(db.files).get())
          .singleWhere((row) => row.path == goes)
          .id;

      final bytes = File(goes).readAsBytesSync();
      File(goes).deleteSync();

      final second = await _scan(client, lib, after: first.finishedAt);
      expect(second.missing, 1);
      final rows = {
        for (final row in await db.select(db.files).get()) row.path: row,
      };
      expect(rows[goes]!.missingSince, isNotNull);
      expect(rows[stays]!.missingSince, isNull);
      expect(
        await client.mediaItems(lib),
        hasLength(2),
        reason: 'a scan annotates; it never deletes',
      );

      File(goes).writeAsBytesSync(bytes, flush: true);
      final third = await _scan(client, lib, after: second.finishedAt);
      expect(third.missing, 0);
      final back = (await db.select(db.files).get()).singleWhere(
        (row) => row.path == goes,
      );
      expect(back.missingSince, isNull);
      expect(back.id, goesId, reason: 'the same row welcomed the file home');
      expect(await client.mediaItems(lib), hasLength(2));
    });

    test('two libraries scan at once without treading on each other', () async {
      final music = await client.createLibrary('Music', LibraryType.music);
      final walls = await client.createLibrary('Walls', LibraryType.images);
      final musicDir = Directory(p.join(temp.path, 'music'))..createSync();
      final wallsDir = Directory(p.join(temp.path, 'walls'))..createSync();
      File(Fixtures.id3v23Mp3).copySync(p.join(musicDir.path, 'a.mp3'));
      File(Fixtures.taggedFlac).copySync(p.join(musicDir.path, 'b.flac'));
      File(Fixtures.tinyPng).copySync(p.join(wallsDir.path, 'one.png'));
      File(Fixtures.tinyGif).copySync(p.join(wallsDir.path, 'two.gif'));
      await client.addRoot(music, musicDir.path);
      await client.addRoot(walls, wallsDir.path);

      // Both scans on the floor together — the per-library booking desk
      // must keep them apart while one database serves them both.
      expect((await client.scan(music)).status, 202);
      expect((await client.scan(walls)).status, 202);
      final done = await Future.wait([
        _settle(client, music),
        _settle(client, walls),
      ]);
      expect(done[0].state, ScanState.done);
      expect(done[1].state, ScanState.done);
      expect(done[0].added, 2);
      expect(done[1].added, 2);
      expect(done[0].errors, isEmpty);
      expect(done[1].errors, isEmpty);
      expect(await client.mediaItems(music), hasLength(2));
      expect(await client.mediaItems(walls), hasLength(2));
    });

    test(
      'a rewrite sheds the art and sidecars the file no longer has',
      () async {
        final lib = await client.createLibrary('Music', LibraryType.music);
        await client.addRoot(lib, temp.path);
        final track = p.join(temp.path, 'Track.mp3');
        final lyrics = p.join(temp.path, 'Track.lrc');
        File(Fixtures.apicMp3).copySync(track);
        File(Fixtures.lyricsLrc).copySync(lyrics);

        final first = await _scan(client, lib);
        expect(first.added, 1);
        expect(first.sidecars, 1);
        final fileId = (await db.select(db.files).get()).single.id;
        expect(
          await db.select(db.artworks).get(),
          isNotEmpty,
          reason: 'the APIC cover and its thumbnail landed',
        );
        expect(await db.select(db.sidecars).get(), hasLength(1));

        // The cover-less rewrite, padded until the size disagrees; the
        // lyric sheet leaves with it.
        File(lyrics).deleteSync();
        final replacement = File(Fixtures.id3v23Mp3).readAsBytesSync().toList();
        while (replacement.length == File(track).lengthSync()) {
          replacement.add(0);
        }
        File(track).writeAsBytesSync(replacement, flush: true);

        final second = await _scan(client, lib, after: first.finishedAt);
        expect(second.updated, 1);
        expect((await db.select(db.files).get()).single.id, fileId);
        expect(
          await db.select(db.artworks).get(),
          isEmpty,
          reason: 'art the file no longer carries is not kept on faith',
        );
        expect(
          await db.select(db.sidecars).get(),
          isEmpty,
          reason: 'a sidecar gone from disk is gone from the table',
        );
      },
    );

    test('lost in one scan, found elsewhere in the next', () async {
      final lib = await client.createLibrary('Music', LibraryType.music);
      await client.addRoot(lib, temp.path);
      final track = p.join(temp.path, 'Track.mp3');
      File(Fixtures.id3v23Mp3).copySync(track);

      final first = await _scan(client, lib);
      expect(first.added, 1);
      final item = (await client.mediaItems(lib)).single;
      final bytes = File(track).readAsBytesSync();
      File(track).deleteSync();

      final second = await _scan(client, lib, after: first.finishedAt);
      expect(second.missing, 1);
      expect((await db.select(db.files).get()).single.missingSince, isNotNull);

      final elsewhere = p.join(temp.path, 'Found', 'Track.mp3');
      Directory(p.dirname(elsewhere)).createSync();
      File(elsewhere).writeAsBytesSync(bytes, flush: true);

      final third = await _scan(client, lib, after: second.finishedAt);
      expect(third.moved, 1);
      expect(third.added, 0);
      expect(third.missing, 0);
      final row = (await db.select(db.files).get()).single;
      expect(
        row.id,
        item.fileId,
        reason: 'a whole scan of absence later, the sha256 still vouches',
      );
      expect(row.path, elsewhere);
      expect(row.missingSince, isNull);
      expect((await client.mediaItems(lib)).single.id, item.id);
    });

    test(
      'a cancel stops between batches; the next scan finishes the job',
      () async {
        final gate = Completer<void>();
        final tier = _GatedTier(gate.future);
        final coordinator = ScanCoordinator(
          db,
          scanner: LibraryScanner(
            db,

            buildExtractor: () => MediaExtractor([tier]),
            concurrency: 1,
            batchSize: 1,
          ),
        );
        final gated = MediaClient.direct(
          db,
          service: MediaService(db, coordinator: coordinator),
        );
        addTearDown(gated.close);

        final lib = await gated.createLibrary('Slow', LibraryType.music);
        for (final name in const ['a.mp3', 'b.mp3', 'c.mp3']) {
          File(Fixtures.id3v23Mp3).copySync(p.join(temp.path, name));
        }
        await gated.addRoot(lib, temp.path);

        expect((await gated.scan(lib)).status, 202);
        // The first file is on the tier's doorstep — the scan is provably
        // mid-batch, so the cancel below lands between batches, not before.
        await tier.entered.future;
        expect(await gated.cancelScan(lib), isTrue);
        gate.complete();

        final cancelled = await _settle(gated, lib);
        expect(cancelled.state, ScanState.cancelled);
        expect(cancelled.seen, 3);
        expect(
          cancelled.added,
          0,
          reason: 'cancelled batches are discarded before database writes',
        );
        expect(await gated.mediaItems(lib), isEmpty);

        final resumed = await _scan(gated, lib, after: cancelled.finishedAt);
        expect(resumed.state, ScanState.done);
        expect(resumed.added, 3);
        expect(await gated.mediaItems(lib), hasLength(3));
      },
    );
  });
}

/// Whether a native probe answered [ProbeExtractor.tryLoad] (after a
/// cargo build attempt, when it came to that). Set once in `setUpAll`.
bool _probeAround = false;

/// The pure-Dart stack alone — the world where no probe was ever built.
/// Top-level, so the recipe can cross into worker isolates.
MediaExtractor _pureTiers() => MediaExtractor([
  const AudioExtractor(),
  const ImageExtractor(),
  const VideoExtractor(),
  const DocumentExtractor(),
]);

/// Loads the probe, building it first via `cadence native build` when only
/// cargo is around. Null when neither a library nor a toolchain shows up.
ProbeExtractor? _loadProbe() {
  final loaded = ProbeExtractor.tryLoad();
  if (loaded != null) return loaded;
  final root = p.dirname(p.dirname(p.dirname(p.dirname(Fixtures.root))));
  try {
    final built = Process.runSync(Platform.resolvedExecutable, [
      'run',
      p.join(root, 'tool', 'bin', 'cadence.dart'),
      'native',
      'build',
    ], workingDirectory: root);
    if (built.exitCode != 0) {
      print('scan_integration_test: probe build failed:\n${built.stderr}');
      return null;
    }
  } on ProcessException {
    return null;
  }
  return ProbeExtractor.tryLoad();
}

/// The file's sha256 row, straight from the table.
Future<String> _sha256Row(MediaDatabase db, int fileId) async {
  final rows = await db.select(db.fileHashes).get();
  return rows
      .singleWhere((row) => row.fileId == fileId && row.kind == HashKind.sha256)
      .value;
}

/// Asks for a scan through the service and polls it to a terminal state.
Future<ScanStatus> _scan(
  MediaClient client,
  int libraryId, {
  DateTime? after,
}) async {
  expect((await client.scan(libraryId)).status, 202);
  return _settle(client, libraryId, after: after);
}

/// Polls the status route until the scan lands somewhere terminal —
/// through the same client the app would use. [after] insists on an
/// ending newer than the one given, telling a rescan from its predecessor.
Future<ScanStatus> _settle(
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

/// A tier that answers only when the test says so, and announces the
/// moment the first file reaches it — the deterministic hook a mid-scan
/// cancel needs.
class _GatedTier implements MetadataExtractor {
  _GatedTier(this.open);

  final Future<void> open;
  final Completer<void> entered = Completer();

  @override
  bool handles(MediaKind kind, String extension) => true;

  @override
  Future<ExtractionResult?> extract(String path, MediaKind kind) async {
    if (!entered.isCompleted) entered.complete();
    await open;
    return null;
  }
}

/// Grows the fixture tree: an album with tracks, lyrics, and cover art; a
/// show with an episode and its subtitles; a shelf of books; a wall of
/// images — and the decoys every corner of a real disk keeps: a `.cadence`
/// directory, a dotfile, a loose image, a file no map knows.
({String music, String shows, String books, String walls}) _plant(
  Directory temp,
) {
  String dir(String relative) => (Directory(
    p.join(temp.path, relative),
  )..createSync(recursive: true)).path;
  void copy(String fixture, String into, String name) =>
      File(fixture).copySync(p.join(into, name));

  final album = dir('Music/Test Pattern');
  copy(Fixtures.id3v23Mp3, album, '01 Sine of the Times.mp3');
  copy(Fixtures.id3v24Mp3, album, '02 Four Forty.mp3');
  copy(Fixtures.taggedFlac, album, '03 Lossless Bloom.flac');
  copy(Fixtures.apicMp3, album, '04 Cover Story.mp3');
  // No pure tier speaks ASF — the probe enriches it, the facade's
  // filename fallback carries it when the probe stays home.
  copy(Fixtures.wmav2Wma, album, '05 Static Cling.wma');
  copy(Fixtures.lyricsLrc, album, '01 Sine of the Times.lrc');
  copy(Fixtures.coverJpg, album, 'cover.jpg');
  // A loose image that is not folder art, and an extension off the map —
  // both are noted, skipped, and never become items.
  copy(Fixtures.tinyPng, album, 'band.png');
  File(
    p.join(album, 'liner-notes.nfo'),
  ).writeAsStringSync('unknown to the format map');
  // The decoys: a dotfile, and a whole .cadence directory with bait.
  copy(Fixtures.id3v1Mp3, album, '.nope.mp3');
  copy(Fixtures.id3v23Mp3, dir('Music/Test Pattern/.cadence'), 'trap.mp3');

  final show = dir('Shows/Fixture Show');
  copy(Fixtures.episodeMkv, show, 'Fixture Show S01E02.mkv');
  copy(Fixtures.subsSrt, show, 'Fixture Show S01E02.srt');

  final books = dir('Books');
  copy(Fixtures.chaptersM4b, books, 'chapters.m4b');
  copy(Fixtures.bookEpub, books, 'book.epub');
  copy(Fixtures.infoPdf, books, 'info.pdf');
  copy(Fixtures.notesTxt, books, 'notes.txt');

  final walls = dir('Wallpapers');
  copy(Fixtures.exifJpg, walls, 'exif.jpg');
  copy(Fixtures.tinyPng, walls, 'tiny.png');
  copy(Fixtures.tinyGif, walls, 'tiny.gif');
  copy(Fixtures.tinyWebp, walls, 'tiny.webp');
  copy(Fixtures.tinyBmp, walls, 'tiny.bmp');
  copy(Fixtures.tinyTiff, walls, 'tiny.tiff');

  return (
    music: p.join(temp.path, 'Music'),
    shows: p.join(temp.path, 'Shows'),
    books: p.join(temp.path, 'Books'),
    walls: p.join(temp.path, 'Wallpapers'),
  );
}

/// The standing tree, examined limb by limb. Runs once per extractor
/// flavour: [probeRides] says whether the native tier may be aboard, and
/// every probe-only expectation follows both that flag and whether a
/// probe actually loaded.
void _treeSuite(
  String flavour, {
  required MediaExtractor Function() build,
  required bool probeRides,
}) {
  group('the standing tree, $flavour', () {
    late Directory temp;
    late MediaDatabase db;
    late MediaClient client;
    late int musicLib, showsLib, booksLib, wallsLib;
    late Map<int, ScanStatus> statuses;
    late Map<int, List<MediaItem>> itemsOf;
    late List<FileRow> fileRows;
    late List<FileHashRow> hashRows;
    late List<ArtworkRow> artRows;
    late List<SidecarRow> sidecarRows;

    // Whether the probe tier is actually in play for this flavour.
    bool probeInPlay() => probeRides && _probeAround;

    FileRow file(String name) =>
        fileRows.singleWhere((row) => p.basename(row.path) == name);

    MediaItem item(String name) => [
      for (final items in itemsOf.values)
        for (final item in items)
          if (p.basename(item.path) == name) item,
    ].single;

    String? hash(String name, HashKind kind) {
      final rows = [
        for (final row in hashRows)
          if (row.fileId == file(name).id && row.kind == kind) row,
      ];
      return rows.isEmpty ? null : rows.single.value;
    }

    int art(String name, ArtworkRole role) => [
      for (final row in artRows)
        if (row.fileId == file(name).id && row.role == role) row,
    ].length;

    List<SidecarRow> sidecars(String name, SidecarKind kind) => [
      for (final row in sidecarRows)
        if (row.fileId == file(name).id && row.kind == kind) row,
    ];

    setUpAll(() async {
      temp = Directory.systemTemp.createTempSync('cadence_scan_tree_');
      db = MediaDatabase(NativeDatabase.memory());
      client = MediaClient.direct(
        db,
        service: MediaService(
          db,
          coordinator: ScanCoordinator(
            db,
            scanner: LibraryScanner(db, buildExtractor: build),
          ),
        ),
      );

      final roots = _plant(temp);
      musicLib = await client.createLibrary('Music', LibraryType.music);
      showsLib = await client.createLibrary('Shows', LibraryType.shows);
      booksLib = await client.createLibrary('Books', LibraryType.books);
      wallsLib = await client.createLibrary('Walls', LibraryType.images);
      await client.addRoot(musicLib, roots.music);
      await client.addRoot(showsLib, roots.shows);
      await client.addRoot(booksLib, roots.books);
      await client.addRoot(wallsLib, roots.walls);

      final queued = await client.scanAll();
      expect(queued.toSet(), {musicLib, showsLib, booksLib, wallsLib});
      statuses = {for (final lib in queued) lib: await _settle(client, lib)};
      itemsOf = {for (final lib in queued) lib: await client.mediaItems(lib)};
      fileRows = await db.select(db.files).get();
      hashRows = await db.select(db.fileHashes).get();
      artRows = await db.select(db.artworks).get();
      sidecarRows = await db.select(db.sidecars).get();
    });

    tearDownAll(() async {
      await client.close();
      temp.deleteSync(recursive: true);
    });

    test('every scan lands whole, and counts what it walked past', () {
      for (final MapEntry(key: lib, value: status) in statuses.entries) {
        expect(status.state, ScanState.done, reason: 'library $lib');
        expect(status.errors, isEmpty, reason: 'library $lib');
        expect(status.errorCount, 0);
        expect(status.updated, 0);
        expect(status.moved, 0);
        expect(status.missing, 0);
      }
      expect(statuses[musicLib]!.seen, 5);
      expect(statuses[musicLib]!.added, 5);
      expect(
        statuses[musicLib]!.sidecars,
        6,
        reason: 'one lyric sheet, folder art for all five tracks',
      );
      expect(
        statuses[musicLib]!.skipped,
        2,
        reason: 'the loose PNG and the .nfo, noted and left alone',
      );
      expect(statuses[showsLib]!.seen, 1);
      expect(statuses[showsLib]!.added, 1);
      expect(statuses[showsLib]!.sidecars, 1);
      expect(statuses[showsLib]!.skipped, 0);
      expect(statuses[booksLib]!.seen, 4);
      expect(statuses[booksLib]!.added, 4);
      expect(statuses[wallsLib]!.seen, 6);
      expect(statuses[wallsLib]!.added, 6);
    });

    test('each library holds its own, in its own kinds', () {
      expect(itemsOf[musicLib], hasLength(5));
      expect(itemsOf[musicLib]!.map((i) => i.metadata.kind).toSet(), {
        MediaKind.audio,
      });
      expect(itemsOf[showsLib], hasLength(1));
      expect(itemsOf[showsLib]!.single.metadata.kind, MediaKind.video);
      expect(itemsOf[booksLib], hasLength(4));
      expect(
        [
          for (final item in itemsOf[booksLib]!)
            if (item.metadata.kind == MediaKind.audio) item.path,
        ].map(p.basename),
        ['chapters.m4b'],
        reason: 'the audiobook is audio on a book shelf',
      );
      expect(
        itemsOf[booksLib]!.where((i) => i.metadata.kind == MediaKind.document),
        hasLength(3),
      );
      expect(itemsOf[wallsLib], hasLength(6));
      expect(itemsOf[wallsLib]!.map((i) => i.metadata.kind).toSet(), {
        MediaKind.image,
      });
      expect(fileRows, hasLength(16));
    });

    test('the decoys never crossed the threshold', () {
      for (final row in fileRows) {
        expect(row.path, isNot(contains('.cadence')), reason: row.path);
        expect(p.basename(row.path), isNot(startsWith('.')));
      }
      final names = fileRows.map((row) => p.basename(row.path)).toSet();
      expect(names, isNot(contains('trap.mp3')));
      expect(
        names,
        isNot(contains('band.png')),
        reason: 'a loose image in an audio library is noise, not an item',
      );
      expect(
        names,
        isNot(contains('cover.jpg')),
        reason: 'folder art is a sidecar, never an item',
      );
      expect(names, isNot(contains('liner-notes.nfo')));
    });

    test('items wear their kind/ and format/ tags', () {
      const expected = {
        '01 Sine of the Times.mp3': (MediaKind.audio, 'mp3'),
        '02 Four Forty.mp3': (MediaKind.audio, 'mp3'),
        '03 Lossless Bloom.flac': (MediaKind.audio, 'flac'),
        '04 Cover Story.mp3': (MediaKind.audio, 'mp3'),
        '05 Static Cling.wma': (MediaKind.audio, 'wma'),
        'Fixture Show S01E02.mkv': (MediaKind.video, 'mkv'),
        'chapters.m4b': (MediaKind.audio, 'm4b'),
        'book.epub': (MediaKind.document, 'epub'),
        'info.pdf': (MediaKind.document, 'pdf'),
        'notes.txt': (MediaKind.document, 'txt'),
        'exif.jpg': (MediaKind.image, 'jpg'),
        'tiny.png': (MediaKind.image, 'png'),
        'tiny.gif': (MediaKind.image, 'gif'),
        'tiny.webp': (MediaKind.image, 'webp'),
        'tiny.bmp': (MediaKind.image, 'bmp'),
        'tiny.tiff': (MediaKind.image, 'tiff'),
      };
      for (final MapEntry(key: name, value: (kind, format))
          in expected.entries) {
        final tags = {for (final tag in item(name).tags) tag.canonical};
        expect(
          tags,
          containsAll(['kind/${kind.name}', 'format/$format']),
          reason: name,
        );
      }
    });

    test('audio: tracks, genres, and the studio ephemera', () {
      final sine = item('01 Sine of the Times.mp3').metadata as AudioMetadata;
      expect(sine.title, 'Sine of the Times');
      expect(sine.artist, 'The Fixtures');
      expect(sine.album, 'Test Pattern');
      expect(sine.trackNumber, 1);
      expect(sine.trackTotal, 8);
      expect(sine.year, 2001);
      expect(sine.genres, ['Electronic']);

      final forty = item('02 Four Forty.mp3').metadata as AudioMetadata;
      expect(forty.trackNumber, 2);
      expect(forty.year, 2001);

      final bloom = item('03 Lossless Bloom.flac').metadata as AudioMetadata;
      expect(bloom.trackNumber, 3);
      expect(bloom.genres, ['Electronic']);
      expect(bloom.lossless, isTrue);
      expect(
        bloom.musicBrainz?.recordingId,
        '8f6bd1e4-fbe1-4f50-aa9b-4c0f8d3c0b6e',
      );
      expect(bloom.replayGain?.trackGain, closeTo(-6.2, 0.001));
      expect(bloom.replayGain?.albumPeak, closeTo(0.999969, 0.000001));
      expect(bloom.duration, isNotNull);
      expect(bloom.duration!, greaterThan(Duration.zero));

      final wma = item('05 Static Cling.wma').metadata as AudioMetadata;
      if (probeInPlay()) {
        expect(
          wma.title,
          'Redmond Calling',
          reason: 'the probe speaks ASF and reads the real title',
        );
        expect(wma.artist, 'The Fixtures');
      } else {
        expect(
          wma.title,
          '05 Static Cling',
          reason: 'no pure tier speaks ASF, so the filename stands in',
        );
        expect(wma.artist, isNull);
      }
    });

    test('the audiobook keeps its two chapters', () {
      final book = item('chapters.m4b').metadata as AudioMetadata;
      expect(book.title, 'Audiobook of Fixtures');
      expect(book.chapters, hasLength(2));
      expect(book.chapters[0], const ChapterMark('Chapter One', Duration.zero));
      expect(
        book.chapters[1],
        const ChapterMark('Chapter Two', Duration(milliseconds: 100)),
      );
    });

    test('video: the filename names the series, the container the frame', () {
      final episode = item('Fixture Show S01E02.mkv').metadata as VideoMetadata;
      expect(episode.title, 'Fixture Show S01E02');
      expect(episode.series, 'Fixture Show');
      expect(episode.season, 1);
      expect(episode.episode, 2);
      expect(episode.width, 16);
      expect(episode.height, 16);
    });

    test('images: dimensions always, the camera when EXIF speaks', () {
      for (final name in const [
        'exif.jpg', 'tiny.png', 'tiny.gif', 'tiny.webp', 'tiny.bmp', //
        'tiny.tiff',
      ]) {
        final image = item(name).metadata as ImageMetadata;
        expect(image.width, 8, reason: name);
        expect(image.height, 8, reason: name);
      }
      final shot = item('exif.jpg').metadata as ImageMetadata;
      expect(shot.cameraMake, 'Cadence');
      expect(shot.cameraModel, 'Fixture Cam 1000');
      expect(shot.lensModel, 'Fixture 35mm f/2');
      expect(shot.iso, 200);
      expect(shot.fNumber, closeTo(2.8, 0.01));
      expect(shot.exposureSeconds, closeTo(1 / 250, 0.0001));
      expect(shot.focalLengthMm, closeTo(35, 0.01));
      expect(shot.orientation, 1);
      expect(shot.takenAt, DateTime(2020, 5, 17, 10, 30));
      expect(shot.gpsLatitude, closeTo(51.5007, 0.0001));
      expect(shot.gpsLongitude, closeTo(-0.1246, 0.0001));
      expect(shot.description, isNotNull);
    });

    test('documents: pages counted, authors credited, shelf data kept', () {
      final pdf = item('info.pdf').metadata as DocumentMetadata;
      expect(pdf.title, 'Fixture Document');
      expect(pdf.author, 'Cadence Fixtures');
      expect(pdf.pageCount, 1);

      final epub = item('book.epub').metadata as DocumentMetadata;
      expect(epub.title, 'The Fixture Book');
      expect(epub.authors, contains('Cadence Fixtures'));
      expect(epub.language, 'en');
      expect(epub.publisher, 'Fixture Press');
      expect(epub.isbn, '9780306406157');

      final txt = item('notes.txt').metadata as DocumentMetadata;
      expect(txt.title, 'notes');
    });

    test('search finds titles, credits, and tags alike', () async {
      expect(
        await client.search('sine of the times'),
        contains(item('01 Sine of the Times.mp3').id),
      );
      expect(
        await client.search('lossless'),
        contains(item('03 Lossless Bloom.flac').id),
      );
      expect(
        await client.search('fixture book'),
        contains(item('book.epub').id),
      );
      expect(
        await client.search('mkv'),
        contains(item('Fixture Show S01E02.mkv').id),
        reason: 'the format/ tag is indexed too',
      );
      expect(
        await client.search('fixtures'),
        containsAll([
          item('01 Sine of the Times.mp3').id,
          item('chapters.m4b').id,
        ]),
        reason: 'the artist credit reaches across libraries',
      );
    });

    test('artwork lands by role: embedded, thumbnail, folder', () {
      // Art inside the file: the FLAC PICTURE and the MP3 APIC.
      expect(art('03 Lossless Bloom.flac', ArtworkRole.embedded), 1);
      expect(art('04 Cover Story.mp3', ArtworkRole.embedded), 1);
      expect(art('01 Sine of the Times.mp3', ArtworkRole.embedded), 0);
      expect(art('05 Static Cling.wma', ArtworkRole.embedded), 0);

      // Every track in the album directory wears the folder's cover, and
      // a thumbnail besides: rendered from embedded art where there is
      // some, from that cover where there is none.
      for (final name in const [
        '01 Sine of the Times.mp3', '02 Four Forty.mp3', //
        '03 Lossless Bloom.flac', '04 Cover Story.mp3', //
        '05 Static Cling.wma',
      ]) {
        expect(art(name, ArtworkRole.folder), 1, reason: name);
        expect(art(name, ArtworkRole.thumbnail), 1, reason: name);
      }

      // Images render their own thumbnails — except the TIFF, which no
      // tier can decode into one.
      for (final name in const [
        'exif.jpg',
        'tiny.png',
        'tiny.gif',
        'tiny.webp',
        'tiny.bmp',
      ]) {
        expect(art(name, ArtworkRole.thumbnail), 1, reason: name);
        expect(art(name, ArtworkRole.embedded), 0, reason: name);
        expect(art(name, ArtworkRole.folder), 0, reason: name);
      }
      expect(art('tiny.tiff', ArtworkRole.thumbnail), 0);

      // A show with no art anywhere has no rows to show.
      for (final role in ArtworkRole.values) {
        expect(art('Fixture Show S01E02.mkv', role), 0);
      }
    });

    test('sidecars land by kind, pinned to the files they serve', () {
      final lyrics = sidecars('01 Sine of the Times.mp3', SidecarKind.lyrics);
      expect(lyrics, hasLength(1));
      expect(p.basename(lyrics.single.path), '01 Sine of the Times.lrc');
      expect(
        sidecars('02 Four Forty.mp3', SidecarKind.lyrics),
        isEmpty,
        reason: 'lyrics serve the track sharing their basename, no other',
      );

      final subs = sidecars('Fixture Show S01E02.mkv', SidecarKind.subtitles);
      expect(subs, hasLength(1));
      expect(p.basename(subs.single.path), 'Fixture Show S01E02.srt');

      for (final name in const [
        '01 Sine of the Times.mp3', '02 Four Forty.mp3', //
        '03 Lossless Bloom.flac', '04 Cover Story.mp3', //
        '05 Static Cling.wma',
      ]) {
        final cover = sidecars(name, SidecarKind.artwork);
        expect(cover, hasLength(1), reason: name);
        expect(p.basename(cover.single.path), 'cover.jpg');
      }
      expect(
        sidecarRows,
        hasLength(7),
        reason: 'five covers, one lyric sheet, one subtitle file',
      );
    });

    test('fingerprints: sha256 everywhere, the rest where they belong', () {
      for (final row in fileRows) {
        final sha = [
          for (final hash in hashRows)
            if (hash.fileId == row.id && hash.kind == HashKind.sha256) hash,
        ];
        expect(sha, hasLength(1), reason: row.path);
        expect(sha.single.value, matches(RegExp(r'^[0-9a-f]{64}$')));
      }

      // pHash on every image the Dart tier can decode; the TIFF's comes
      // only from the probe (package:image balks at its packbits data).
      for (final name in const [
        'exif.jpg',
        'tiny.png',
        'tiny.gif',
        'tiny.webp',
        'tiny.bmp',
      ]) {
        expect(
          hash(name, HashKind.perceptual),
          matches(RegExp(r'^[0-9a-f]{16}$')),
          reason: name,
        );
      }
      expect(
        hash('tiny.tiff', HashKind.perceptual),
        probeInPlay() ? matches(RegExp(r'^[0-9a-f]{16}$')) : isNull,
        reason: 'the tiff pHash is the probe\'s alone',
      );

      // No pHash where no picture is: audio, video, documents.
      expect(hash('01 Sine of the Times.mp3', HashKind.perceptual), isNull);
      expect(hash('Fixture Show S01E02.mkv', HashKind.perceptual), isNull);

      // SimHash on the texts the Dart tier can read; the PDF's text only
      // yields to the probe.
      expect(
        hash('book.epub', HashKind.textSimhash),
        matches(RegExp(r'^[0-9a-f]{16}$')),
      );
      expect(
        hash('notes.txt', HashKind.textSimhash),
        matches(RegExp(r'^[0-9a-f]{16}$')),
      );
      expect(
        hash('info.pdf', HashKind.textSimhash),
        probeInPlay() ? matches(RegExp(r'^[0-9a-f]{16}$')) : isNull,
      );
      expect(hash('chapters.m4b', HashKind.textSimhash), isNull);
    });

    test('a second pass over unchanged ground changes nothing', () async {
      final queued = await client.scanAll();
      final again = <int, ScanStatus>{};
      for (final lib in queued) {
        again[lib] = await _settle(
          client,
          lib,
          after: statuses[lib]!.finishedAt,
        );
      }
      for (final MapEntry(key: lib, value: status) in again.entries) {
        expect(status.state, ScanState.done, reason: 'library $lib');
        expect(status.seen, statuses[lib]!.seen);
        expect(status.added, 0);
        expect(status.updated, 0);
        expect(status.moved, 0);
        expect(status.missing, 0);
        expect(status.errors, isEmpty);
      }
      expect(await db.select(db.files).get(), unorderedEquals(fileRows));
      expect(await db.select(db.fileHashes).get(), unorderedEquals(hashRows));
      expect(await db.select(db.sidecars).get(), unorderedEquals(sidecarRows));
      // Folder-art rows are replaced in place each pass, so their ids
      // churn while their substance must not.
      List<(int, ArtworkRole, String, int)> shapes(List<ArtworkRow> rows) => [
        for (final row in rows)
          (row.fileId, row.role, row.mime, row.data.length),
      ];
      expect(
        shapes(await db.select(db.artworks).get()),
        unorderedEquals(shapes(artRows)),
      );
      // The search index was re-fed, not fed twice.
      final hits = await client.search('fixtures');
      expect(
        hits.toSet(),
        hasLength(hits.length),
        reason: 'no item indexed twice after a rescan',
      );
    });
  });
}
