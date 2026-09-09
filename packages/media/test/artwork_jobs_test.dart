import 'test_filesystem.dart';
import 'dart:async';

import 'package:cadence_media/cadence_media.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart'
    hide test, setUp, tearDown, setUpAll, tearDownAll, addTearDown;

/// A tier that answers from the filename: files with `embedded` in their
/// name carry art, the rest are bare.
class _CannedTier implements MetadataExtractor {
  const _CannedTier();

  @override
  bool handles(MediaKind kind, String extension) => true;

  @override
  Future<ExtractionResult?> extract(String path, MediaKind kind) async {
    final title = p.basenameWithoutExtension(path);
    return ExtractionResult(
      metadata: AudioMetadata(title: title),
      artwork: title.contains('embedded')
          ? [
              ExtractedArtwork(
                bytes: title.codeUnits,
                mime: 'image/jpeg',
                role: ArtworkRole.embedded,
              ),
            ]
          : const [],
    );
  }
}

MediaExtractor _buildCanned() => const MediaExtractor([_CannedTier()]);

/// Renders whatever it is given back as a "thumbnail" of the same bytes,
/// and writes down the order it was asked in.
final List<String> _rendered = [];

ExtractedArtwork? _recordingThumb(List<int> bytes, {int longestSide = 256}) {
  _rendered.add(String.fromCharCodes(bytes));
  return ExtractedArtwork(
    bytes: [longestSide, ...bytes],
    mime: 'image/png',
    role: ArtworkRole.thumbnail,
  );
}

Map<String, List<SidecarMatch>> _covers({
  required List<String> mediaFiles,
  required List<String> otherFiles,
}) {
  final out = <String, List<SidecarMatch>>{};
  for (final media in mediaFiles) {
    for (final other in otherFiles) {
      if (p.dirname(other) == p.dirname(media) &&
          p.basename(other) == 'cover.jpg') {
        out[media] = [SidecarMatch(other, SidecarKind.artwork)];
      }
    }
  }
  return out;
}

void main() => memoryTests(registerTests);
void registerTests() {
  late MediaDatabase db;
  late Directory root;
  late int libraryId;

  setUp(() async {
    _rendered.clear();
    db = MediaDatabase(NativeDatabase.memory());
    root = mediaFileSystem.systemTempDirectory.createTempSync('cadence_art');
    libraryId = await LibraryRepository(
      db,
    ).createLibrary('Music', LibraryType.music);
    await ScannerRepository(db).addRoot(libraryId, root.path);
  });

  tearDown(() async {
    await db.close();
    root.deleteSync(recursive: true);
  });

  String write(String relative, [String? content]) {
    final file = mediaFileSystem.file(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content ?? relative, flush: true);
    return file.path;
  }

  Future<ScanProgress> scan() => LibraryScanner(
    db,
    buildExtractor: _buildCanned,
    renderThumbnail: _recordingThumb,
    associate: _covers,

    policy: const ScanPolicy(
      identity: IdentityHash.sampled,
      artwork: ArtworkPolicy.deferred,
      thumbnailSide: 64,
    ),
  ).scan(libraryId);

  ArtworkQueue queue() => ArtworkQueue(
    db,
    buildExtractor: _buildCanned,
    renderThumbnail: _recordingThumb,
    thumbnailSide: 64,
  );

  Future<Map<String, int>> idsByTitle() async => {
    for (final row in await db.select(db.files).get())
      p.basenameWithoutExtension(row.path): row.id,
  };

  Future<List<ArtworkRow>> thumbnails() async =>
      (await db.select(db.artworks).get())
          .where((a) => a.role == ArtworkRole.thumbnail)
          .toList();

  group('ArtworkPolicy.deferred', () {
    test('the scan lands no pictures and renders none', () async {
      write('a embedded.mp3');
      write('cover.jpg', 'jpeg');
      final progress = await scan();
      expect(progress.added, 1);
      expect(progress.artwork, 0);
      expect(await db.select(db.artworks).get(), isEmpty);
      expect(_rendered, isEmpty);
      // But the cover beside it was noticed, for the queue's benefit.
      expect(await db.select(db.sidecars).get(), hasLength(1));
    });
  });

  group('ArtworkQueue', () {
    test(
      'a sweep renders every file without a thumbnail, and only those',
      () async {
        write('one embedded.mp3');
        write('two embedded.mp3');
        write('bare.mp3');
        await scan();
        final q = queue();
        addTearDown(q.close);

        expect(await q.sweep(libraryId), 3);
        await q.idle();

        final thumbs = await thumbnails();
        expect(thumbs, hasLength(2));
        expect(q.rendered, 2);
        expect(q.bare, 1);
        expect(thumbs.first.data.first, 64, reason: 'at the policy\'s size');

        // Swept again, there is nothing left to do but look at the bare one.
        _rendered.clear();
        expect(await q.sweep(libraryId), 1);
        await q.idle();
        expect(_rendered, isEmpty);
        expect(await thumbnails(), hasLength(2));
      },
    );

    test('a folder cover stands in for a file with no embedded art', () async {
      write('album/track.mp3');
      write('album/cover.jpg', 'the cover');
      await scan();
      final q = queue();
      addTearDown(q.close);

      await q.sweep();
      await q.idle();
      expect(_rendered, ['the cover']);
      expect(await thumbnails(), hasLength(1));
    });

    test(
      'promoted files jump the queue, in the order they were promoted',
      () async {
        for (var i = 0; i < 6; i++) {
          write('${i.toString().padLeft(2, '0')} embedded.mp3');
        }
        await scan();
        // The sweep goes by file id, which is the order the walk met
        // them - not the alphabet.
        final byId = {
          for (final MapEntry(:key, :value) in (await idsByTitle()).entries)
            value: key,
        };
        final ids = byId.keys.toList()..sort();
        final q = ArtworkQueue(
          db,
          buildExtractor: _buildCanned,
          renderThumbnail: _recordingThumb,
        );
        addTearDown(q.close);

        // The sweep takes the first id in hand at once; the promotion
        // lands before that render finishes its breath.
        await q.sweep();
        q.promote([ids[4], ids[5]]);
        await q.idle();

        expect(_rendered.first, byId[ids[0]], reason: 'already in hand');
        expect(_rendered.sublist(1, 3), [byId[ids[4]], byId[ids[5]]]);
        expect(_rendered, hasLength(6));
      },
    );

    test(
      'ensure waits for the picture, and answers null for a bare file',
      () async {
        write('wanted embedded.mp3');
        write('bare.mp3');
        await scan();
        final ids = await idsByTitle();
        final q = queue();
        addTearDown(q.close);

        final row = await q.ensure(ids['wanted embedded']!);
        expect(row, isNotNull);
        expect(row!.role, ArtworkRole.thumbnail);
        expect(await q.ensure(ids['wanted embedded']!), isNotNull);
        expect(await q.ensure(ids['bare']!), isNull);
        expect(await q.ensure(ids['bare']!), isNull, reason: 'remembered bare');
        expect(_rendered, ['wanted embedded']);
      },
    );

    test('the coordinator sweeps a library when its scan lands', () async {
      write('a embedded.mp3');
      final q = queue();
      addTearDown(q.close);
      final desk = ScanCoordinator(
        db,
        scanner: LibraryScanner(
          db,
          buildExtractor: _buildCanned,
          renderThumbnail: _recordingThumb,
          associate: _covers,

          policy: const ScanPolicy(artwork: ArtworkPolicy.deferred),
        ),
        onFinished: (id) => unawaited(q.sweep(id)),
      );

      await desk.start(libraryId);
      await desk.wait(libraryId);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await q.idle();
      expect(await thumbnails(), hasLength(1));
    });

    test('the render pipeline applies the policy and tiers', () async {
      write('a embedded.mp3');
      await scan();
      final q = ArtworkQueue(
        db,
        buildExtractor: _buildCanned,
        renderThumbnail: _recordingThumb,
        thumbnailSide: 32,
      );
      addTearDown(q.close);

      await q.sweep();
      await q.idle();
      final thumbs = await thumbnails();
      expect(thumbs, hasLength(1));
      expect(thumbs.single.data.first, 32);
    });
  });

  group('the service', () {
    test(
      'artwork renders on demand, prefetch promotes, sweep answers 202',
      () async {
        write('a embedded.mp3');
        write('bare.mp3');
        final q = queue();
        final client = MediaClient.direct(
          db,
          service: MediaService(db, artwork: q),
        );
        addTearDown(client.close);
        await scan();
        final ids = await idsByTitle();

        final art = await client.artwork(ids['a embedded']!);
        expect(art, isNotNull);
        expect(art!.role, ArtworkRole.thumbnail);
        expect(await client.artwork(ids['bare']!), isNull);

        await client.prefetchArtwork([ids['bare']!, ids['a embedded']!]);
        final status = await client.artworkQueue();
        expect(status['rendered'], 1);

        final swept = await client.send(ServiceMethod.post, '/artwork/sweep', {
          'libraryId': libraryId,
        });
        expect(swept.status, 202);
      },
    );
  });
}
