import 'test_filesystem.dart';
import 'package:cadence_media/cadence_media.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart'
    hide test, setUp, tearDown, setUpAll, tearDownAll, addTearDown;

void main() => memoryTests(registerTests);
void registerTests() {
  late MediaDatabase db;
  late LibraryRepository libraries;

  setUp(() {
    db = MediaDatabase(NativeDatabase.memory());
    libraries = LibraryRepository(db);
  });

  tearDown(() => db.close());

  Future<(int, int)> seedOne() async {
    final libraryId = await libraries.createLibrary('Music', LibraryType.music);
    final itemId = await libraries.addItem(
      libraryId: libraryId,
      path: '/music/velvet_modem/carrier_tone.flac',
      sizeBytes: 31337,
      modifiedAt: DateTime.utc(1997, 6, 1),
      metadata: const AudioMetadata(
        title: 'Carrier Tone',
        artist: 'Velvet Modem',
        album: 'Static Bloom',
        year: 1997,
        trackNumber: 1,
        duration: Duration(minutes: 4, seconds: 12),
        bitrateKbps: 320,
      ),
      hashes: const {HashKind.sha256: 'deadbeef'},
      tags: [Tag.ofFormat('flac')],
    );
    return (libraryId, itemId);
  }

  test('tags speak the canonical namespace/name form', () {
    expect(TagNamespace.format.tag('mp3').canonical, 'format/mp3');
    expect(Tag.ofKind(MediaKind.audio).canonical, 'kind/audio');
    expect(Tag.parse('mood/rainy'), const Tag('mood', 'rainy'));
    expect(Tag.parse('loose').canonical, 'loose');
  });

  test('audio metadata survives the JSON round trip', () {
    const before = AudioMetadata(
      title: 'Handshake',
      artist: 'Velvet Modem',
      album: 'Static Bloom',
      year: 1997,
      trackNumber: 3,
      duration: Duration(minutes: 5, seconds: 2),
      bitrateKbps: 320,
    );
    final after = AudioMetadata.fromJson(before.toJson());
    expect(after.title, before.title);
    expect(after.duration, before.duration);
    expect(after.bitrateKbps, before.bitrateKbps);
  });

  test('episodic video metadata survives the JSON round trip', () {
    const before = VideoMetadata(
      title: 'Vertical Hold',
      year: 1999,
      duration: Duration(minutes: 24),
      series: 'Test Pattern After Dark',
      season: 1,
      episode: 3,
    );
    final after =
        MediaMetadata.fromJson(MediaKind.video, before.toJson())
            as VideoMetadata;
    expect(after.series, before.series);
    expect(after.season, 1);
    expect(after.episode, 3);
  });

  test('an item goes in whole and comes back typed', () async {
    final (libraryId, itemId) = await seedOne();

    final items = await libraries.audioItems(libraryId);
    expect(items, hasLength(1));
    final item = items.single;
    expect(item.id, itemId);
    expect(item.metadata.title, 'Carrier Tone');
    expect(item.metadata.duration, const Duration(minutes: 4, seconds: 12));
    // The automatic kind tag arrived without being asked for.
    expect(
      item.tags.map((t) => t.canonical),
      containsAll(['kind/audio', 'format/flac']),
    );
  });

  test('mediaItems returns every kind, typed by its metadata', () async {
    final (libraryId, _) = await seedOne();
    await libraries.addItem(
      libraryId: libraryId,
      path: '/videos/live_at_the_loop.mp4',
      sizeBytes: 1,
      modifiedAt: DateTime.utc(1998, 6, 1),
      metadata: const VideoMetadata(title: 'Live at the Loop', year: 1998),
    );

    final items = await libraries.mediaItems(libraryId);
    expect(items, hasLength(2));
    expect(items.first.metadata, isA<AudioMetadata>());
    expect(items.last.metadata, isA<VideoMetadata>());
    expect(items.last.tags.map((t) => t.canonical), contains('kind/video'));
  });

  test('search finds by title, artist, and tag; prefixes count', () async {
    final (_, itemId) = await seedOne();
    final search = SearchRepository(db);

    expect(await search.search('carrier'), [itemId]);
    expect(await search.search('velv'), [itemId]);
    expect(await search.search('flac'), [itemId]);
    expect(await search.search('polka'), isEmpty);

    // A rebuild reaches the same answer from the tables alone.
    await db.customStatement('DELETE FROM search_index');
    expect(await search.search('carrier'), isEmpty);
    await search.rebuild();
    expect(await search.search('carrier'), [itemId]);
  });

  test('tag edits reindex', () async {
    final (_, itemId) = await seedOne();
    final search = SearchRepository(db);

    await libraries.addTag(itemId, const Tag('mood', 'rainy'));
    expect(await search.search('rainy'), [itemId]);
    await libraries.removeTag(itemId, const Tag('mood', 'rainy'));
    expect(await search.search('rainy'), isEmpty);
  });

  test('settings hold their shape through definitions', () async {
    final store = SettingsStore(db);
    final crossfade = SettingDef.json<num>('playback.crossfade_seconds', 4);
    final kind = SettingDef.enumOf(
      'library.default_kind',
      MediaKind.values,
      MediaKind.audio,
    );

    expect(await store.get(crossfade), 4);
    await store.set(crossfade, 8);
    expect(await store.get(crossfade), 8);

    expect(await store.get(kind), MediaKind.audio);
    await store.set(kind, MediaKind.video);
    expect(await store.get(kind), MediaKind.video);
  });

  test('collections keep their order and rewrite it whole', () async {
    final (libraryId, itemId) = await seedOne();
    final second = await libraries.addItem(
      libraryId: libraryId,
      path: '/music/velvet_modem/handshake.flac',
      sizeBytes: 1,
      modifiedAt: DateTime.utc(1997, 6, 1),
      metadata: const AudioMetadata(title: 'Handshake'),
    );
    final collections = CollectionsRepository(db);

    final playlist = await collections.create('Road Trip');
    final rows = await collections.listCollections();
    expect(rows.single.name, 'Road Trip');
    await collections.setEntries(playlist, [second, itemId]);
    expect(await collections.entries(playlist), [second, itemId]);
    await collections.setEntries(playlist, [itemId, second]);
    expect(await collections.entries(playlist), [itemId, second]);
  });

  test('plays count and progress resumes', () async {
    final (_, itemId) = await seedOne();
    final log = PlayLog(db);

    await log.recordPlay(itemId);
    await log.recordPlay(itemId, completed: true);
    expect(await log.playCount(itemId), 2);

    expect(await log.progressOf(itemId), isNull);
    await log.setProgress(itemId, const Duration(seconds: 67));
    expect(await log.progressOf(itemId), const Duration(seconds: 67));
  });
}
