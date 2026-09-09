import 'test_filesystem.dart';
import 'dart:async';
import 'dart:convert';

import 'package:cadence_media/cadence_media.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart'
    hide test, setUp, tearDown, setUpAll, tearDownAll, addTearDown;

/// A tier that answers from the filename alone — the scanner under test,
/// the real extractors left out of it. Files with `embedded` in their name
/// come with art inside.
class _CannedTier implements MetadataExtractor {
  const _CannedTier();

  @override
  bool handles(MediaKind kind, String extension) => true;

  @override
  Future<ExtractionResult?> extract(String path, MediaKind kind) async {
    final title = p.basenameWithoutExtension(path);
    final metadata = switch (kind) {
      MediaKind.audio => AudioMetadata(title: title, artist: 'The Canned'),
      MediaKind.video => VideoMetadata(title: title),
      MediaKind.image => ImageMetadata(title: title),
      MediaKind.document => DocumentMetadata(title: title),
    };
    return ExtractionResult(
      metadata: metadata,
      artwork: title.contains('embedded')
          ? const [
              ExtractedArtwork(
                bytes: [9, 9, 9],
                mime: 'image/jpeg',
                role: ArtworkRole.embedded,
              ),
            ]
          : const [],
    );
  }
}

/// A tier that takes its time — long enough for a test to look at a scan
/// mid-flight.
class _SlowTier implements MetadataExtractor {
  const _SlowTier(this.delay);

  final Duration delay;

  @override
  bool handles(MediaKind kind, String extension) => true;

  @override
  Future<ExtractionResult?> extract(String path, MediaKind kind) async {
    await Future<void>.delayed(delay);
    return ExtractionResult(
      metadata: AudioMetadata(title: p.basenameWithoutExtension(path)),
    );
  }
}

/// A facade that refuses one file by name and behaves for the rest.
class _ExplodingExtractor extends MediaExtractor {
  const _ExplodingExtractor(super.tiers, this.marker);

  final String marker;

  @override
  Future<ExtractionResult> extract(String path, MediaKind kind) {
    if (p.basename(path) == marker) {
      throw StateError('this file refuses to be read');
    }
    return super.extract(path, kind);
  }
}

/// A desk that keeps score — how many times the watcher knocked.

MediaExtractor _buildCanned() => const MediaExtractor([_CannedTier()]);

ExtractedArtwork? _fakeThumb(List<int> bytes, {int longestSide = 256}) =>
    const ExtractedArtwork(
      bytes: [1, 2, 3],
      mime: 'image/jpeg',
      role: ArtworkRole.thumbnail,
    );

Map<String, List<SidecarMatch>> _noSidecars({
  required List<String> mediaFiles,
  required List<String> otherFiles,
}) => const {};

/// Association rules small enough to trust: `.lrc` by basename, and any
/// `cover.jpg` serves its whole directory.
Map<String, List<SidecarMatch>> _lyricsAndCovers({
  required List<String> mediaFiles,
  required List<String> otherFiles,
}) {
  final out = <String, List<SidecarMatch>>{};
  for (final media in mediaFiles) {
    final matches = <SidecarMatch>[];
    for (final other in otherFiles) {
      if (p.dirname(other) != p.dirname(media)) continue;
      if (p.extension(other) == '.lrc' &&
          p.basenameWithoutExtension(other) ==
              p.basenameWithoutExtension(media)) {
        matches.add(SidecarMatch(other, SidecarKind.lyrics));
      } else if (p.basename(other).toLowerCase() == 'cover.jpg') {
        matches.add(SidecarMatch(other, SidecarKind.artwork));
      }
    }
    if (matches.isNotEmpty) out[media] = matches;
  }
  return out;
}

Future<void> _until(
  FutureOr<bool> Function() ready, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!(await ready())) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition never came true within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() => memoryTests(registerTests);
void registerTests() {
  late MediaDatabase db;
  late ScannerRepository repo;
  late Directory root;
  late int libraryId;

  setUp(() async {
    db = MediaDatabase(NativeDatabase.memory());
    repo = ScannerRepository(db);
    root = mediaFileSystem.systemTempDirectory.createTempSync('cadence_scan');
    libraryId = await LibraryRepository(
      db,
    ).createLibrary('Music', LibraryType.music);
    await repo.addRoot(libraryId, root.path);
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String write(String relative, String content) {
    final file = mediaFileSystem.file(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content, flush: true);
    return file.path;
  }

  LibraryScanner scanner({
    ExtractorBuilder? build,
    SidecarAssociator? associate,
    ThumbnailRenderer? thumb,
    int batchSize = 2,
    int concurrency = 2,
    bool extractInIsolates = false,
    ScanPolicy policy = ScanPolicy.full,
  }) => LibraryScanner(
    db,
    buildExtractor: build ?? _buildCanned,
    associate: associate ?? _noSidecars,
    renderThumbnail: thumb ?? _fakeThumb,

    concurrency: concurrency,
    batchSize: batchSize,
    policy: policy,
  );

  Future<List<FileRow>> files() => db.select(db.files).get();
  Future<List<LibraryItemRow>> items() => db.select(db.libraryItems).get();
  Future<List<ItemTagRow>> tags() => db.select(db.itemTags).get();
  Future<List<FileHashRow>> hashes() => db.select(db.fileHashes).get();
  Future<List<ArtworkRow>> artworks() => db.select(db.artworks).get();
  Future<List<SidecarRow>> sidecars() => db.select(db.sidecars).get();

  group('LibraryScanner', () {
    test('a first scan adds files, items, tags, and hashes', () async {
      final a = write('a.mp3', 'aaa');
      write('b.flac', 'bbb');
      write('sub/c.mp4', 'ccc');
      write('.hidden.mp3', 'no');
      write('.cadence/inside.mp3', 'no');
      write('unknown.xyz', 'no');

      final progress = await scanner().scan(libraryId);

      expect(progress.seen, 3);
      expect(progress.added, 3);
      expect(progress.updated, 0);
      expect(progress.skipped, 1);
      expect(progress.errors, isEmpty);

      final rows = await files();
      expect(rows, hasLength(3));
      final rowA = rows.singleWhere((r) => r.path == a);
      expect(rowA.scannedAt, isNotNull);
      expect(rowA.missingSince, isNull);
      expect((jsonDecode(rowA.metadata) as Map<String, Object?>)['title'], 'a');

      expect(await items(), hasLength(3));
      final canonical = [
        for (final t in await tags()) '${t.namespace}/${t.name}',
      ];
      expect(
        canonical,
        containsAll([
          'kind/audio',
          'kind/video',
          'format/mp3',
          'format/flac',
          'format/mp4',
        ]),
      );

      final hashA = (await hashes()).singleWhere(
        (h) => h.fileId == rowA.id && h.kind == HashKind.sha256,
      );
      expect(
        hashA.value,
        crypto.sha256
            .convert(mediaFileSystem.file(a).readAsBytesSync())
            .toString(),
      );
    });

    test('an unchanged file is left exactly alone', () async {
      write('a.mp3', 'aaa');
      await scanner().scan(libraryId);
      final before = (await files()).single;

      final progress = await scanner().scan(libraryId);
      expect(progress.seen, 1);
      expect(progress.added, 0);
      expect(progress.updated, 0);
      final after = (await files()).single;
      expect(after.scannedAt, before.scannedAt);
      expect(await items(), hasLength(1));
    });

    test('a changed file is re-read in place', () async {
      final a = write('a.mp3', 'aaa');
      await scanner().scan(libraryId);
      final before = (await files()).single;
      final itemBefore = (await items()).single;

      write('a.mp3', 'a much longer body of sound');
      final progress = await scanner().scan(libraryId);

      expect(progress.updated, 1);
      expect(progress.added, 0);
      final after = (await files()).single;
      expect(after.id, before.id);
      expect(after.sizeBytes, isNot(before.sizeBytes));
      expect((await items()).single.id, itemBefore.id);
      final hash = (await hashes()).singleWhere(
        (h) => h.fileId == after.id && h.kind == HashKind.sha256,
      );
      expect(
        hash.value,
        crypto.sha256
            .convert(mediaFileSystem.file(a).readAsBytesSync())
            .toString(),
      );
    });

    test(
      'a vanished file is marked missing; a returned one is welcomed back',
      () async {
        final a = write('a.mp3', 'aaa');
        write('b.mp3', 'bbb');
        await scanner().scan(libraryId);

        final stat = mediaFileSystem.file(a).statSync();
        mediaFileSystem.file(a).deleteSync();
        var progress = await scanner().scan(libraryId);
        expect(progress.missing, 1);
        var rowA = (await files()).singleWhere((r) => r.path == a);
        expect(rowA.missingSince, isNotNull);
        expect(await items(), hasLength(2), reason: 'nothing is ever deleted');

        // The same bytes come home with the same clock face.
        mediaFileSystem.file(a).writeAsStringSync('aaa', flush: true);
        mediaFileSystem.file(a).setLastModifiedSync(stat.modified);
        progress = await scanner().scan(libraryId);
        expect(progress.added, 0);
        expect(progress.updated, 0);
        rowA = (await files()).singleWhere((r) => r.path == a);
        expect(rowA.missingSince, isNull);
      },
    );

    test('a moved file keeps its row, its item, and its history', () async {
      final a = write('a.mp3', 'irreplaceable bytes');
      write('b.mp3', 'bbb');
      await scanner().scan(libraryId);
      final rowBefore = (await files()).singleWhere((r) => r.path == a);
      final itemBefore = (await items()).singleWhere(
        (i) => i.fileId == rowBefore.id,
      );

      final moved = p.join(root.path, 'albums', 'renamed.mp3');
      mediaFileSystem.directory(p.dirname(moved)).createSync(recursive: true);
      mediaFileSystem.file(a).renameSync(moved);

      final progress = await scanner().scan(libraryId);
      expect(progress.moved, 1);
      expect(progress.added, 0);
      expect(progress.missing, 0);

      final rows = await files();
      expect(rows, hasLength(2), reason: 'no duplicate row for the new path');
      final rowAfter = rows.singleWhere((r) => r.id == rowBefore.id);
      expect(rowAfter.path, moved);
      expect(rowAfter.missingSince, isNull);
      final itemAfter = (await items()).singleWhere(
        (i) => i.fileId == rowBefore.id,
      );
      expect(itemAfter.id, itemBefore.id);
    });

    test('embedded art lands with a thumbnail rendered from it', () async {
      write('embedded_song.mp3', 'artful');
      final progress = await scanner().scan(libraryId);

      final art = await artworks();
      expect(art.where((a) => a.role == ArtworkRole.embedded), hasLength(1));
      final thumb = art.singleWhere((a) => a.role == ArtworkRole.thumbnail);
      expect(thumb.data, [1, 2, 3]);
      expect(progress.artwork, 2);
    });

    test(
      'sidecars: lyrics matched, folder art attached, thumbnail follows',
      () async {
        write('track.mp3', 'song');
        write('track.lrc', '[00:01.00] la');
        final cover = write('cover.jpg', 'JPEGDATA');

        final scan = scanner(associate: _lyricsAndCovers);
        var progress = await scan.scan(libraryId);

        expect(progress.seen, 1, reason: 'sidecars are never items');
        expect(progress.sidecars, 2);
        expect(progress.skipped, 0);
        final rows = await sidecars();
        expect(rows, hasLength(2));
        expect(
          {for (final row in rows) row.kind},
          {SidecarKind.lyrics, SidecarKind.artwork},
        );

        var art = await artworks();
        final folder = art.singleWhere((a) => a.role == ArtworkRole.folder);
        expect(utf8.decode(folder.data), 'JPEGDATA');
        expect(
          art.where((a) => a.role == ArtworkRole.thumbnail),
          hasLength(1),
          reason: 'no embedded art, so the thumbnail comes from the folder',
        );

        // A second pass re-asserts rather than duplicates, and the standing
        // thumbnail is not re-rendered.
        progress = await scan.scan(libraryId);
        expect(await sidecars(), hasLength(2));
        art = await artworks();
        expect(art.where((a) => a.role == ArtworkRole.thumbnail), hasLength(1));

        // The cover leaves; its rows follow.
        mediaFileSystem.file(cover).deleteSync();
        await scan.scan(libraryId);
        expect(
          (await sidecars()).single.kind,
          SidecarKind.lyrics,
          reason: 'the artwork sidecar went with its file',
        );
        expect(
          (await artworks()).where((a) => a.role == ArtworkRole.folder),
          isEmpty,
        );
      },
    );

    test(
      'in a non-image library a loose image is counted and skipped',
      () async {
        write('track.mp3', 'song');
        write('random.png', 'pixels');

        final progress = await scanner().scan(libraryId);
        expect(progress.seen, 1);
        expect(progress.added, 1);
        expect(progress.skipped, 1);
        expect(await items(), hasLength(1));
      },
    );

    test('in an image library images are items', () async {
      final imagesId = await LibraryRepository(
        db,
      ).createLibrary('Walls', LibraryType.images);
      final wallRoot = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_walls',
      );
      addTearDown(() => wallRoot.deleteSync(recursive: true));
      await repo.addRoot(imagesId, wallRoot.path);
      mediaFileSystem
          .file(p.join(wallRoot.path, 'photo.png'))
          .writeAsStringSync('pixels', flush: true);
      mediaFileSystem
          .file(p.join(wallRoot.path, 'track.mp3'))
          .writeAsStringSync('song', flush: true);

      final progress = await scanner().scan(imagesId);
      expect(progress.seen, 2);
      expect(progress.added, 2);
      expect(progress.skipped, 0);
      final canonical = [
        for (final t in await tags()) '${t.namespace}/${t.name}',
      ];
      expect(canonical, containsAll(['kind/image', 'format/png']));
    });

    test(
      'a file whose extraction throws lands in errors; the scan walks on',
      () async {
        write('good_one.mp3', 'fine');
        write('boom.mp3', 'cursed');
        write('good_two.mp3', 'also fine');

        final progress = await scanner(
          build: () => const _ExplodingExtractor([_CannedTier()], 'boom.mp3'),
        ).scan(libraryId);

        expect(progress.errors, hasLength(1));
        expect(progress.errors.single.path, endsWith('boom.mp3'));
        expect(progress.added, 2);
        expect(await items(), hasLength(2));
      },
    );

    test('a missing root is an error entry, not a crash', () async {
      await repo.addRoot(libraryId, p.join(root.path, 'nowhere'));
      write('a.mp3', 'aaa');

      final progress = await scanner().scan(libraryId);
      expect(progress.added, 1);
      expect(progress.errors.single.path, endsWith('nowhere'));
    });

    test(
      'cancellation stops between batches and marks nothing missing',
      () async {
        for (var i = 0; i < 6; i++) {
          write('track_$i.mp3', 'song $i');
        }
        final progress = ScanProgress();
        await scanner(batchSize: 1, concurrency: 1).scan(
          libraryId,
          progress: progress,
          shouldCancel: () => progress.added >= 2,
        );

        expect(progress.added, 2);
        expect(await items(), hasLength(2));
        expect(progress.missing, 0);
      },
    );

    test(
      'an incremental scan touches only the directories it is told',
      () async {
        write('a/one.mp3', 'one');
        final two = write('b/two.mp3', 'two');
        await scanner().scan(libraryId);

        write('a/three.mp3', 'three');
        write('b/four.mp3', 'four');
        mediaFileSystem.file(two).deleteSync();

        var progress = await scanner().scan(
          libraryId,
          onlyDirs: {p.join(root.path, 'a')},
        );
        expect(progress.added, 1);
        expect(progress.missing, 0, reason: 'b was out of scope');
        expect(
          (await files()).singleWhere((r) => r.path == two).missingSince,
          isNull,
        );

        progress = await scanner().scan(libraryId);
        expect(progress.added, 1);
        expect(progress.missing, 1);
      },
    );

    test(
      'a library sharing an already-scanned root still gains its items',
      () async {
        write('a.mp3', 'aaa');
        write('b.mp3', 'bbb');
        await scanner().scan(libraryId);

        final mirrorId = await LibraryRepository(
          db,
        ).createLibrary('Mirror', LibraryType.music);
        await repo.addRoot(mirrorId, root.path);
        final progress = await scanner().scan(mirrorId);

        expect(progress.seen, 2);
        expect(progress.added, 0, reason: 'the files themselves are old news');
        final mirrored = await (db.select(
          db.libraryItems,
        )..where((i) => i.libraryId.equals(mirrorId))).get();
        expect(mirrored, hasLength(2));
        final canonical = [
          for (final t in await tags()) '${t.namespace}/${t.name}',
        ];
        expect(canonical, containsAll(['kind/audio', 'format/mp3']));
      },
    );

    test('a recreated library refills from unchanged files', () async {
      write('a.mp3', 'aaa');
      await scanner().scan(libraryId);
      await LibraryRepository(db).deleteLibrary(libraryId);

      final again = await LibraryRepository(
        db,
      ).createLibrary('Music', LibraryType.music);
      await repo.addRoot(again, root.path);
      await scanner().scan(again);

      final refilled = await (db.select(
        db.libraryItems,
      )..where((i) => i.libraryId.equals(again))).get();
      expect(refilled, hasLength(1));
    });

    test('nested roots walk the same ground once: no doubled sidecars, '
        'no duplicate folder art', () async {
      write('albums/track.mp3', 'song');
      write('albums/track.lrc', '[00:01.00] la');
      write('albums/cover.jpg', 'JPEGDATA');
      write('albums/stray.xyz', 'junk');
      await repo.addRoot(libraryId, p.join(root.path, 'albums'));

      final progress = await scanner(
        associate: _lyricsAndCovers,
      ).scan(libraryId);

      expect(progress.seen, 1);
      expect(progress.sidecars, 2);
      expect(progress.skipped, 1);
      expect(
        (await artworks()).where((a) => a.role == ArtworkRole.folder),
        hasLength(1),
      );
    });

    test('extraction builds from the injected recipe', () async {
      write('a.mp3', 'aaa');
      write('b.mp3', 'bbb');
      write('sub/c.flac', 'ccc');

      final progress = await scanner(extractInIsolates: true).scan(libraryId);
      expect(progress.added, 3);
      final row = (await files()).singleWhere((r) => r.path.endsWith('a.mp3'));
      expect(
        (jsonDecode(row.metadata) as Map<String, Object?>)['artist'],
        'The Canned',
      );
    });

    test('an unknown library refuses politely', () async {
      expect(scanner().scan(999), throwsArgumentError);
    });
  });

  group('ScanCoordinator', () {
    ScanCoordinator coordinator() => ScanCoordinator(
      db,
      scanner: LibraryScanner(
        db,
        buildExtractor: _buildCanned,
        associate: _noSidecars,
        renderThumbnail: _fakeThumb,

        concurrency: 1,
        batchSize: 1,
      ),
    );

    ScanCoordinator slowCoordinator(Duration delay) => ScanCoordinator(
      db,
      scanner: LibraryScanner(
        db,
        buildExtractor: () => MediaExtractor([_SlowTier(delay)]),
        associate: _noSidecars,
        renderThumbnail: _fakeThumb,

        concurrency: 1,
        batchSize: 1,
      ),
    );

    test(
      'a second start while scanning is refused with a StateError',
      () async {
        for (var i = 0; i < 5; i++) {
          write('track_$i.mp3', 'song $i');
        }
        final desk = slowCoordinator(const Duration(milliseconds: 30));
        final first = await desk.start(libraryId);
        expect(first.state.running, isTrue);
        expect(desk.start(libraryId), throwsStateError);

        final settled = await desk.wait(libraryId);
        expect(settled.state, ScanState.done);
        expect(settled.progress?.added, 5);
        expect(settled.startedAt, isNotNull);
        expect(settled.finishedAt, isNotNull);
        expect(settled.toJson()['state'], 'done');

        // Done means the desk is free again.
        await desk.start(libraryId);
        await desk.wait(libraryId);
      },
    );

    test('cancel asks nicely, and the outcome says cancelled', () async {
      for (var i = 0; i < 8; i++) {
        write('track_$i.mp3', 'song $i');
      }
      final desk = slowCoordinator(const Duration(milliseconds: 30));
      await desk.start(libraryId);
      expect(desk.cancel(libraryId), isTrue);
      final settled = await desk.wait(libraryId);
      expect(settled.state, ScanState.cancelled);
      expect(settled.progress?.added, lessThan(8));
      expect(desk.cancel(libraryId), isFalse, reason: 'nothing left to stop');
    });

    test('an unknown library is an ArgumentError, never a scan', () async {
      final desk = coordinator();
      expect(desk.start(999), throwsArgumentError);
      expect(desk.statusOf(999).state, ScanState.idle);
    });

    test('a never-scanned library reports idle and nothing else', () {
      final desk = coordinator();
      expect(desk.statusOf(libraryId).state, ScanState.idle);
      expect(desk.statusOf(libraryId).toJson(), {'state': 'idle'});
    });

    test('a vanished library is nobody\'s debt to the watcher', () async {
      final desk = coordinator();
      await LibraryRepository(db).deleteLibrary(libraryId);
      expect(
        await desk.startIncremental(libraryId, dirs: {root.path}),
        isTrue,
        reason: 'nothing to scan and nothing worth retrying',
      );
      expect(desk.statusOf(libraryId).state, ScanState.idle);
    });

    test('scanAll queues every library and drains them', () async {
      write('a.mp3', 'aaa');
      final secondId = await LibraryRepository(
        db,
      ).createLibrary('More', LibraryType.music);
      final secondRoot = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_more',
      );
      addTearDown(() => secondRoot.deleteSync(recursive: true));
      await repo.addRoot(secondId, secondRoot.path);
      mediaFileSystem
          .file(p.join(secondRoot.path, 'b.mp3'))
          .writeAsStringSync('bbb', flush: true);

      final desk = coordinator();
      final ids = await desk.scanAll();
      expect(ids, containsAll([libraryId, secondId]));
      await _until(
        () =>
            desk.statusOf(libraryId).state == ScanState.done &&
            desk.statusOf(secondId).state == ScanState.done,
      );
      expect(await items(), hasLength(2));
    });
  });

  group('the epilogue', () {
    test('an unchanged library rescans without rewriting its sidecars, '
        'and reports nothing changed', () async {
      write('album/track.mp3', 'aaa');
      write('album/track.lrc', 'lyrics');
      write('album/cover.jpg', 'jpeg');
      final first = await scanner(associate: _lyricsAndCovers).scan(libraryId);
      expect(first.changed, 1);
      final before = await sidecars();
      expect(before, hasLength(2));

      final again = await scanner(associate: _lyricsAndCovers).scan(libraryId);
      expect(again.changed, 0);
      expect(again.added, 0);
      expect(again.updated, 0);
      expect(
        again.sidecars,
        0,
        reason: 'the rows were left alone, not cleared and re-made',
      );
      expect(await sidecars(), hasLength(2));
    });

    test('a cover that appears beside old tracks is noticed', () async {
      write('album/track.mp3', 'aaa');
      await scanner(associate: _lyricsAndCovers).scan(libraryId);
      expect(await sidecars(), isEmpty);

      write('album/cover.jpg', 'jpeg');
      final progress = await scanner(
        associate: _lyricsAndCovers,
      ).scan(libraryId);
      expect(progress.changed, 0);
      expect(progress.sidecars, 1);
      expect(await sidecars(), hasLength(1));
    });

    test('a sidecar that goes is let go', () async {
      final lyrics = write('album/track.lrc', 'lyrics');
      write('album/track.mp3', 'aaa');
      await scanner(associate: _lyricsAndCovers).scan(libraryId);
      expect(await sidecars(), hasLength(1));

      mediaFileSystem.file(lyrics).deleteSync();
      await scanner(associate: _lyricsAndCovers).scan(libraryId);
      expect(await sidecars(), isEmpty);
    });
  });

  group('ScanPolicy', () {
    test('lean policy stores full hashes for large and small files', () async {
      final big = write('big.mp3', 'x' * (3 * sampledSpan));
      write('small.mp3', 'small');
      await scanner(policy: ScanPolicy.lean).scan(libraryId);
      final rows = await hashes();
      expect(rows, hasLength(2));
      expect(rows.every((h) => h.kind == HashKind.sha256), isTrue);
      for (final file in await files()) {
        expect(
          rows.singleWhere((h) => h.fileId == file.id).value,
          crypto.sha256
              .convert(mediaFileSystem.file(file.path).readAsBytesSync())
              .toString(),
        );
      }
      final before = await sha256OfFile(big);
      final bytes = mediaFileSystem.file(big).readAsBytesSync();
      bytes[sampledSpan + 10] = 0x79;
      mediaFileSystem.file(big).writeAsBytesSync(bytes);
      expect(await sha256OfFile(big), isNot(before));
    });

    test('unchanged files without full hashes are indexed again', () async {
      write('old.mp3', 'legacy');
      await scanner().scan(libraryId);
      final original = (await files()).single;
      await db.delete(db.fileHashes).go();
      final progress = await scanner(policy: ScanPolicy.lean).scan(libraryId);
      expect(progress.updated, 1);
      expect((await files()).single.id, original.id);
      expect((await hashes()).single.kind, HashKind.sha256);
      expect(
        (await scanner(policy: ScanPolicy.lean).scan(libraryId)).changed,
        0,
      );
    });

    test('a move is recognised with lean artwork policy', () async {
      final a = write('a.mp3', 'a' * (3 * sampledSpan));
      await scanner(policy: ScanPolicy.lean).scan(libraryId);
      final before = (await files()).single;

      final moved = p.join(root.path, 'moved', 'a.mp3');
      mediaFileSystem.directory(p.dirname(moved)).createSync(recursive: true);
      mediaFileSystem.file(a).renameSync(moved);
      final progress = await scanner(policy: ScanPolicy.lean).scan(libraryId);

      expect(progress.moved, 1);
      expect(progress.added, 0);
      final after = (await files()).single;
      expect(after.id, before.id);
      expect(after.path, moved);
    });

    test('thumbnails-only keeps the thumbnail and drops the covers', () async {
      write('embedded.mp3', 'aaa');
      write('cover.jpg', 'jpeg');
      await scanner(
        policy: ScanPolicy.lean,
        associate: _lyricsAndCovers,
      ).scan(libraryId);

      final rows = await artworks();
      expect(rows.map((r) => r.role), [ArtworkRole.thumbnail]);
    });

    test(
      'a thumbnail is rendered from folder art at the policy\'s size',
      () async {
        write('plain.mp3', 'aaa');
        write('cover.jpg', 'jpeg');
        int? seenSide;
        ExtractedArtwork? sizedThumb(List<int> bytes, {int longestSide = 256}) {
          seenSide = longestSide;
          return _fakeThumb(bytes, longestSide: longestSide);
        }

        await scanner(
          policy: const ScanPolicy(
            artwork: ArtworkPolicy.thumbnailsOnly,
            thumbnailSide: 96,
          ),
          associate: _lyricsAndCovers,
          thumb: sizedThumb,
        ).scan(libraryId);

        expect(seenSide, 96);
        final rows = await artworks();
        expect(rows.map((r) => r.role), [ArtworkRole.thumbnail]);
      },
    );

    test('no artwork at all means no artwork rows', () async {
      write('embedded.mp3', 'aaa');
      write('cover.jpg', 'jpeg');
      await scanner(
        policy: const ScanPolicy(artwork: ArtworkPolicy.none),
        associate: _lyricsAndCovers,
      ).scan(libraryId);

      expect(await artworks(), isEmpty);
    });

    test('the extraction pipeline applies the policy', () async {
      write('embedded.mp3', 'aaa');
      await scanner(policy: ScanPolicy.lean).scan(libraryId);

      final rows = await hashes();
      expect(rows.single.kind, HashKind.sha256);
      expect((await artworks()).map((r) => r.role), [ArtworkRole.thumbnail]);
    });
  });
}
