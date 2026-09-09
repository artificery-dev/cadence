import 'test_filesystem.dart';
import 'package:cadence_media/cadence_media.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart'
    hide test, setUp, tearDown, setUpAll, tearDownAll, addTearDown;

/// A tier that answers from a script — the facade under test, the disk
/// left out of it.
class _CannedTier implements MetadataExtractor {
  _CannedTier(this.result, {this.claims = true, this.throws = false});

  final ExtractionResult? result;
  final bool claims;
  final bool throws;

  @override
  bool handles(MediaKind kind, String extension) => claims;

  @override
  Future<ExtractionResult?> extract(String path, MediaKind kind) async {
    if (throws) throw StateError('this tier is having a day');
    return result;
  }
}

void main() => memoryTests(registerTests);
void registerTests() {
  group('ScannerRepository', () {
    late MediaDatabase db;
    late ScannerRepository repo;
    late int libraryId;

    setUp(() async {
      db = MediaDatabase(NativeDatabase.memory());
      repo = ScannerRepository(db);
      libraryId = await LibraryRepository(
        db,
      ).createLibrary('Music', LibraryType.music);
    });

    tearDown(() => db.close());

    Future<int> seedFile(String path, {String title = 'Song'}) =>
        repo.upsertFileByPath(
          path: path,
          sizeBytes: 100,
          modifiedAt: DateTime.utc(2001),
          metadata: AudioMetadata(title: title),
          scannedAt: DateTime.utc(2020),
        );

    test('addRoot claims, rootsOf lists, removeRoot releases', () async {
      final rootId = await repo.addRoot(libraryId, '/music');
      await repo.addRoot(libraryId, '/more');
      final roots = await repo.rootsOf(libraryId);
      expect([for (final r in roots) r.path], ['/music', '/more']);

      expect(await repo.removeRoot(rootId), isTrue);
      expect(await repo.removeRoot(rootId), isFalse);
      expect((await repo.rootsOf(libraryId)).single.path, '/more');
    });

    test('a duplicate root is refused; another library may claim it', () async {
      await repo.addRoot(libraryId, '/music');
      await expectLater(
        repo.addRoot(libraryId, '/music'),
        throwsA(isA<StateError>()),
      );
      final other = await LibraryRepository(
        db,
      ).createLibrary('Mirror', LibraryType.music);
      await repo.addRoot(other, '/music');
      expect((await repo.rootsOf(other)).single.path, '/music');
    });

    test('upsertFileByPath inserts, then refreshes in place', () async {
      final id = await seedFile('/music/a.mp3');
      final again = await repo.upsertFileByPath(
        path: '/music/a.mp3',
        sizeBytes: 200,
        modifiedAt: DateTime.utc(2002),
        metadata: const AudioMetadata(title: 'Renamed'),
        scannedAt: DateTime.utc(2021),
      );
      expect(again, id);
      final row = (await repo.fileByPath('/music/a.mp3'))!;
      expect(row.sizeBytes, 200);
      expect(row.modifiedAt.toUtc(), DateTime.utc(2002));
      expect(row.scannedAt!.toUtc(), DateTime.utc(2021));
      expect(row.metadata, contains('Renamed'));
    });

    test('an upserted file is by definition not missing', () async {
      final id = await seedFile('/music/a.mp3');
      await repo.markMissing([id], DateTime.utc(2010));
      await seedFile('/music/a.mp3');
      expect((await repo.fileByPath('/music/a.mp3'))!.missingSince, isNull);
    });

    test('fileByPath answers null for a stranger', () async {
      expect(await repo.fileByPath('/nowhere.mp3'), isNull);
    });

    test('filesUnderRoots is directory-honest', () async {
      await seedFile('/music/a.mp3');
      await seedFile('/music/sub/b.flac');
      await seedFile('/musical/c.mp3');
      await seedFile('/video/d.mp4');

      final underMusic = await repo.filesUnderRoots(['/music']);
      expect([
        for (final f in underMusic) f.path,
      ], unorderedEquals(['/music/a.mp3', '/music/sub/b.flac']));
      final slashed = await repo.filesUnderRoots(['/music/']);
      expect(slashed, hasLength(2));
      final both = await repo.filesUnderRoots(['/music', '/video']);
      expect(both, hasLength(3));
      expect(await repo.filesUnderRoots([]), isEmpty);
    });

    test('replaceHashes swaps the whole set', () async {
      final id = await seedFile('/music/a.mp3');
      await repo.replaceHashes(id, {HashKind.sha256: 'aaaa'});
      await repo.replaceHashes(id, {
        HashKind.sha256: 'bbbb',
        HashKind.textSimhash: 'cccc',
      });
      final rows = await db.select(db.fileHashes).get();
      expect(rows, hasLength(2));
      expect(
        {for (final r in rows) r.kind: r.value},
        {HashKind.sha256: 'bbbb', HashKind.textSimhash: 'cccc'},
      );
    });

    test('replaceArtwork replaces one role and spares the rest', () async {
      final id = await seedFile('/music/a.mp3');
      const thumb = ExtractedArtwork(
        bytes: [9, 9],
        mime: 'image/jpeg',
        role: ArtworkRole.thumbnail,
      );
      await repo.replaceArtwork(id, ArtworkRole.thumbnail, [thumb]);
      await repo.replaceArtwork(id, ArtworkRole.embedded, [
        const ExtractedArtwork(
          bytes: [1, 2],
          mime: 'image/jpeg',
          role: ArtworkRole.embedded,
        ),
      ]);
      // A new embedded haul lands; the stray folder entry is ignored; the
      // thumbnail row stays put.
      await repo.replaceArtwork(id, ArtworkRole.embedded, [
        const ExtractedArtwork(
          bytes: [3, 4],
          mime: 'image/png',
          role: ArtworkRole.embedded,
        ),
        const ExtractedArtwork(
          bytes: [5, 6],
          mime: 'image/png',
          role: ArtworkRole.folder,
        ),
      ]);
      final rows = await db.select(db.artworks).get();
      expect(rows, hasLength(2));
      final byRole = {for (final r in rows) r.role: r};
      expect(byRole[ArtworkRole.embedded]!.mime, 'image/png');
      expect(byRole[ArtworkRole.embedded]!.data, [3, 4]);
      expect(byRole[ArtworkRole.thumbnail]!.data, [9, 9]);
      expect(byRole.containsKey(ArtworkRole.folder), isFalse);
    });

    test('sidecars upsert by key and clear by kind', () async {
      final id = await seedFile('/music/a.mp3');
      await repo.upsertSidecar(
        fileId: id,
        path: '/music/a.lrc',
        kind: SidecarKind.lyrics,
        modifiedAt: DateTime.utc(2001),
      );
      await repo.upsertSidecar(
        fileId: id,
        path: '/music/a.lrc',
        kind: SidecarKind.lyrics,
        modifiedAt: DateTime.utc(2002),
      );
      await repo.upsertSidecar(
        fileId: id,
        path: '/music/cover.jpg',
        kind: SidecarKind.artwork,
        modifiedAt: DateTime.utc(2001),
      );
      var rows = await db.select(db.sidecars).get();
      expect(rows, hasLength(2));
      expect(
        rows.firstWhere((r) => r.kind == SidecarKind.lyrics).modifiedAt.toUtc(),
        DateTime.utc(2002),
      );

      await repo.clearSidecars(id, SidecarKind.artwork);
      rows = await db.select(db.sidecars).get();
      expect(rows.single.kind, SidecarKind.lyrics);
    });

    test('ensureItem creates once, tags automatically, feeds FTS', () async {
      final id = await seedFile('/music/a.mp3', title: 'Carrier Tone');
      final first = await repo.ensureItem(
        libraryId,
        id,
        tags: [Tag.ofFormat('mp3')],
      );
      expect(first.wasNew, isTrue);
      final again = await repo.ensureItem(libraryId, id);
      expect(again.wasNew, isFalse);
      expect(again.itemId, first.itemId);

      final tags = await LibraryRepository(db).tagsOf(first.itemId);
      expect(
        tags,
        containsAll([Tag.ofKind(MediaKind.audio), Tag.ofFormat('mp3')]),
      );
      expect(
        await SearchRepository(db).search('carrier'),
        contains(first.itemId),
      );
    });

    test('ensureItem re-indexes after a metadata refresh', () async {
      final id = await seedFile('/music/a.mp3', title: 'Old Name');
      final item = await repo.ensureItem(libraryId, id);
      await seedFile('/music/a.mp3', title: 'New Name');
      await repo.ensureItem(libraryId, id);
      final search = SearchRepository(db);
      expect(await search.search('new'), contains(item.itemId));
      expect(await search.search('old'), isEmpty);
    });

    test('markMissing stamps only the unstamped', () async {
      final a = await seedFile('/music/a.mp3');
      final b = await seedFile('/music/b.mp3');
      await repo.markMissing([a], DateTime.utc(2010));
      await repo.markMissing([a, b], DateTime.utc(2011));
      expect(
        (await repo.fileByPath('/music/a.mp3'))!.missingSince!.toUtc(),
        DateTime.utc(2010),
      );
      expect(
        (await repo.fileByPath('/music/b.mp3'))!.missingSince!.toUtc(),
        DateTime.utc(2011),
      );

      await repo.clearMissing(a);
      expect((await repo.fileByPath('/music/a.mp3'))!.missingSince, isNull);
      await repo.markMissing([], DateTime.utc(2012));
    });

    test('rewritePath moves the row, keeps the item, clears missing', () async {
      final id = await seedFile('/music/a.mp3');
      final item = await repo.ensureItem(libraryId, id);
      await repo.markMissing([id], DateTime.utc(2010));

      await repo.rewritePath(id, '/music/moved/a.mp3');
      expect(await repo.fileByPath('/music/a.mp3'), isNull);
      final row = (await repo.fileByPath('/music/moved/a.mp3'))!;
      expect(row.id, id);
      expect(row.missingSince, isNull);

      final items = await LibraryRepository(db).mediaItems(libraryId);
      expect(items.single.id, item.itemId);
      expect(items.single.path, '/music/moved/a.mp3');
    });
  });

  group('MediaExtractor facade', () {
    ExtractionResult audio(
      String title, {
      String? artist,
      int? year,
      Map<String, Object?> extra = const {},
      List<ExtractedArtwork> artwork = const [],
    }) => ExtractionResult(
      metadata: AudioMetadata(
        title: title,
        artist: artist,
        year: year,
        extra: extra,
      ),
      artwork: artwork,
    );

    test('later tiers fill nulls; earlier typed values win', () async {
      final extractor = MediaExtractor([
        _CannedTier(audio('Kept', year: 2001)),
        _CannedTier(audio('Ignored', artist: 'Filled', year: 1999)),
      ]);
      final result = await extractor.extract('/x/a.mp3', MediaKind.audio);
      final metadata = result.metadata as AudioMetadata;
      expect(metadata.title, 'Kept');
      expect(metadata.artist, 'Filled');
      expect(metadata.year, 2001);
    });

    test('extra maps merge, earlier keys winning', () async {
      final extractor = MediaExtractor([
        _CannedTier(audio('A', extra: {'TXXX:MOOD': 'wistful'})),
        _CannedTier(
          audio('B', extra: {'TXXX:MOOD': 'loud', 'ENCODER': 'LAME'}),
        ),
      ]);
      final result = await extractor.extract('/x/a.mp3', MediaKind.audio);
      expect((result.metadata as AudioMetadata).extra, {
        'TXXX:MOOD': 'wistful',
        'ENCODER': 'LAME',
      });
    });

    test('an empty title yields to a later tier with a real one', () async {
      final extractor = MediaExtractor([
        _CannedTier(audio('', artist: 'First')),
        _CannedTier(audio('Found Later')),
      ]);
      final result = await extractor.extract('/x/a.mp3', MediaKind.audio);
      expect((result.metadata as AudioMetadata).title, 'Found Later');
    });

    test('the filename steps in when every tier leaves title empty', () async {
      final extractor = MediaExtractor([_CannedTier(audio(''))]);
      final result = await extractor.extract(
        '/x/Carrier Tone.mp3',
        MediaKind.audio,
      );
      expect((result.metadata as AudioMetadata).title, 'Carrier Tone');
    });

    test('no tier, no answer — still a filename-titled result', () async {
      final extractor = MediaExtractor([
        _CannedTier(null),
        _CannedTier(audio('Never'), claims: false),
      ]);
      final result = await extractor.extract('/x/b.flac', MediaKind.audio);
      expect((result.metadata as AudioMetadata).title, 'b');
    });

    test('a throwing tier is a tier with nothing to say', () async {
      final extractor = MediaExtractor([
        _CannedTier(audio('Loud'), throws: true),
        _CannedTier(audio('Quiet')),
      ]);
      final result = await extractor.extract('/x/a.mp3', MediaKind.audio);
      expect((result.metadata as AudioMetadata).title, 'Quiet');
    });

    test('artwork lands once per distinct image', () async {
      const cover = ExtractedArtwork(
        bytes: [1, 2, 3],
        mime: 'image/jpeg',
        role: ArtworkRole.embedded,
      );
      const other = ExtractedArtwork(
        bytes: [4, 5, 6],
        mime: 'image/png',
        role: ArtworkRole.embedded,
      );
      final extractor = MediaExtractor([
        _CannedTier(audio('A', artwork: [cover, cover])),
        _CannedTier(audio('B', artwork: [cover, other])),
      ]);
      final result = await extractor.extract('/x/a.mp3', MediaKind.audio);
      expect(result.artwork, hasLength(2));
      expect(result.artwork.first.bytes, [1, 2, 3]);
      expect(result.artwork.last.bytes, [4, 5, 6]);
    });
  });
}
