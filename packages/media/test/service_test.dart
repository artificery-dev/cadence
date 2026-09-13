import 'test_filesystem.dart';
import 'package:cadence_media/cadence_media.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart'
    hide test, setUp, tearDown, setUpAll, tearDownAll, addTearDown;

void main() => memoryTests(registerTests);
void registerTests() {
  group('direct transport', () {
    late MediaClient client;

    setUp(() {
      client = MediaClient.direct(MediaDatabase(NativeDatabase.memory()));
    });

    tearDown(() => client.close());

    Future<(int, int)> seedOne() async {
      final libraryId = await client.createLibrary('Music', LibraryType.music);
      final itemId = await client.addItem(
        libraryId: libraryId,
        path: '/music/carrier_tone.flac',
        sizeBytes: 31337,
        modifiedAt: DateTime.utc(1997, 6, 1),
        metadata: const AudioMetadata(
          title: 'Carrier Tone',
          artist: 'Velvet Modem',
          album: 'Static Bloom',
          duration: Duration(minutes: 4, seconds: 12),
        ),
        hashes: const {HashKind.sampledSha256: 'deadbeef'},
        tags: [Tag.ofFormat('flac')],
      );
      return (libraryId, itemId);
    }

    test('the read budget is set and read over the wire', () async {
      expect(await client.scanBudget(), isNull);
      expect(await client.setScanBudget(4 << 20), 4 << 20);
      expect(await client.scanBudget(), 4 << 20);
      expect(await client.setScanBudget(0), isNull, reason: 'zero lifts it');
      await expectLater(
        client.send(ServiceMethod.put, '/scan/budget', {'bytesPerSecond': -1}),
        completion(predicate<ServiceResponse>((r) => r.status == 400)),
      );
      await expectLater(
        client.send(ServiceMethod.put, '/scan/budget', {
          'bytesPerSecond': 'fast',
        }),
        completion(predicate<ServiceResponse>((r) => r.status == 400)),
      );
    });

    test('libraries round-trip through the protocol', () async {
      final (libraryId, itemId) = await seedOne();

      final libraries = await client.listLibraries();
      expect(libraries.single.name, 'Music');
      expect(libraries.single.type, LibraryType.music);

      final items = await client.audioItems(libraryId);
      expect(items.single.id, itemId);
      expect(items.single.metadata.title, 'Carrier Tone');
      expect(
        items.single.tags.map((t) => t.canonical),
        containsAll(['kind/audio', 'format/flac']),
      );

      await client.renameLibrary(libraryId, 'Records');
      expect((await client.listLibraries()).single.name, 'Records');

      await client.deleteLibrary(libraryId);
      expect(await client.listLibraries(), isEmpty);
      expect(
        await client.search('carrier'),
        isEmpty,
        reason: 'the index let go with the library',
      );
    });

    test('artwork answers best-first, by role, or not at all', () async {
      final db = MediaDatabase(NativeDatabase.memory());
      final artClient = MediaClient.direct(db);
      addTearDown(artClient.close);
      final libraryId = await artClient.createLibrary(
        'Music',
        LibraryType.music,
      );
      await artClient.addItem(
        libraryId: libraryId,
        path: '/music/carrier_tone.flac',
        sizeBytes: 31337,
        modifiedAt: DateTime.utc(1997, 6, 1),
        metadata: const AudioMetadata(title: 'Carrier Tone'),
      );
      final fileId = (await artClient.audioItems(libraryId)).single.fileId;

      // A bare file has nothing to show.
      expect(await artClient.artwork(fileId), isNull);

      final scanner = ScannerRepository(db);
      await scanner.replaceArtwork(fileId, ArtworkRole.embedded, const [
        ExtractedArtwork(
          bytes: [1, 2, 3],
          mime: 'image/png',
          role: ArtworkRole.embedded,
        ),
      ]);
      await scanner.replaceArtwork(fileId, ArtworkRole.thumbnail, const [
        ExtractedArtwork(
          bytes: [9, 9],
          mime: 'image/jpeg',
          role: ArtworkRole.thumbnail,
        ),
      ]);

      // Left alone, the thumbnail wins; a named role is honoured; a role
      // the file lacks reads as bare.
      final best = await artClient.artwork(fileId);
      expect(best!.role, ArtworkRole.thumbnail);
      expect(best.mime, 'image/jpeg');
      expect(best.bytes, [9, 9]);
      final full = await artClient.artwork(fileId, role: ArtworkRole.embedded);
      expect(full!.bytes, [1, 2, 3]);
      expect(await artClient.artwork(fileId, role: ArtworkRole.folder), isNull);
    });

    test('collections, settings, search, plays speak the same wire', () async {
      final (libraryId, itemId) = await seedOne();

      final playlist = await client.createCollection('Road Trip');
      await client.setCollectionEntries(playlist, [itemId]);
      expect(await client.collectionEntries(playlist), [itemId]);
      expect((await client.listCollections()).single.name, 'Road Trip');

      final crossfade = SettingDef.json<num>('playback.crossfade_seconds', 4);
      expect(await client.getSetting(crossfade), 4);
      await client.setSetting(crossfade, 9);
      expect(await client.getSetting(crossfade), 9);

      expect(await client.search('velv'), [itemId]);

      await client.recordPlay(itemId);
      await client.setProgress(itemId, const Duration(seconds: 42));
    });

    test('a scan asks politely and the scanner takes the job', () async {
      final (libraryId, _) = await seedOne();
      final outcome = await client.scan(libraryId);
      expect(outcome.status, 202);
      expect(outcome.accepted, isTrue);
      // Let the (rootless, instant) scan settle before teardown closes up.
      while ((await client.scanStatus(libraryId)).running) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });

    test('an unknown route answers 404, a broken body 400', () async {
      final lost = await client.send(ServiceMethod.get, '/teapots');
      expect(lost.status, 404);

      final broken = await client.send(ServiceMethod.post, '/libraries', {
        'nope': true,
      });
      expect(broken.status, 400);
    });
  });

  test('tracks come compact: a row per playable track', () async {
    final client = MediaClient.direct(MediaDatabase(NativeDatabase.memory()));
    addTearDown(client.close);

    final libraryId = await client.createLibrary('Music', LibraryType.music);
    await client.addItem(
      libraryId: libraryId,
      path: '/music/01.flac',
      sizeBytes: 1,
      modifiedAt: DateTime.utc(1999),
      metadata: const AudioMetadata(
        title: 'Hometown Glory',
        artist: 'Adele',
        album: '19',
        albumArtist: 'Adele',
        trackNumber: 3,
        discNumber: 1,
        duration: Duration(minutes: 4, seconds: 31),
        year: 2008,
        genres: ['Pop', 'Soul'],
        extra: {'a raw tag': 'that a list never needs'},
      ),
    );
    await client.addItem(
      libraryId: libraryId,
      path: '/music/clip.mp4',
      sizeBytes: 1,
      modifiedAt: DateTime.utc(1999),
      metadata: const VideoMetadata(title: 'Not a track'),
    );

    final tracks = await client.tracks(libraryId);
    final track = tracks.single;
    expect(track.title, 'Hometown Glory');
    expect(track.artist, 'Adele');
    expect(track.album, '19');
    expect(track.shelfArtist, 'Adele');
    expect(track.trackNumber, 3);
    expect(track.discNumber, 1);
    expect(track.duration, const Duration(minutes: 4, seconds: 31));
    expect(track.year, 2008);
    expect(track.genre, 'Pop');
    expect(track.path, '/music/01.flac');
    expect(track.toJson().containsKey('extra'), isFalse);
  });

  test('the embedded transport carries the protocol', () async {
    final client = MediaClient.direct(MediaDatabase(NativeDatabase.memory()));
    addTearDown(client.close);

    final libraryId = await client.createLibrary('Shows', LibraryType.shows);
    await client.addItem(
      libraryId: libraryId,
      path: '/shows/e01.mkv',
      sizeBytes: 1,
      modifiedAt: DateTime.utc(1999),
      metadata: const VideoMetadata(
        title: 'The Sign-On Ceremony',
        series: 'Test Pattern After Dark',
        season: 1,
        episode: 1,
      ),
    );

    final libraries = await client.listLibraries();
    expect(libraries.single.type, LibraryType.shows);
    final items = await client.mediaItems(libraryId);
    expect(items.single.metadata, isA<VideoMetadata>());
    expect(await client.search('sign-on'), isNotEmpty);
  });
}
