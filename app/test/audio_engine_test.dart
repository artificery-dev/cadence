import 'dart:async';

import 'package:cadence/src/model/audio_engine.dart';
import 'package:cadence/src/model/player.dart';
import 'package:cadence_media/cadence_media.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

/// A silent engine that writes down every verb the deck sends it and
/// lets the test speak back through the streams.
class FakeEngine implements AudioEngine {
  final log = <String>[];
  final _positions = StreamController<Duration>.broadcast();
  final _completed = StreamController<void>.broadcast();

  void emitPosition(Duration at) => _positions.add(at);
  void emitCompleted() => _completed.add(null);

  @override
  Future<void> load(
    String path, {
    Duration start = Duration.zero,
    bool play = true,
  }) async {
    log.add('load $path start:${start.inSeconds} play:$play');
  }

  @override
  Future<void> play() async => log.add('play');

  @override
  Future<void> pause() async => log.add('pause');

  @override
  Future<void> seek(Duration position) async =>
      log.add('seek ${position.inSeconds}');

  @override
  Future<void> setVolume(double value) async =>
      log.add('volume ${value.toStringAsFixed(2)}');

  @override
  Future<void> stop() async => log.add('stop');

  @override
  Future<void> dispose() async => log.add('dispose');

  @override
  Widget? videoSurface(BuildContext context) => null;

  @override
  Stream<Duration> get positions => _positions.stream;

  @override
  Stream<void> get completed => _completed.stream;
}

AudioItem _track(int id, String name) => AudioItem(
  id: id,
  fileId: id,
  path: '/music/$name.flac',
  metadata: AudioMetadata(title: name, duration: const Duration(seconds: 100)),
  tags: const [],
);

/// Lets the deck's fire-and-forget engine calls land.
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  final library = [for (var i = 0; i < 5; i++) _track(i + 1, 'track$i')];

  test('the deck loads, pauses, and resumes through the engine', () async {
    final engine = FakeEngine();
    final player = PlaybackController(List.of(library), engine: engine);

    // A fresh engine is told the deck's level before anything sounds.
    await settle();
    expect(engine.log, ['volume 0.72']);
    engine.log.clear();

    // Play loads the file from the top and lets it run.
    player.play(library.first);
    await settle();
    expect(engine.log, ['load /music/track0.flac start:0 play:true']);
    engine.log.clear();

    // Pause and resume speak to the standing file — no reload.
    player.toggle();
    await settle();
    expect(engine.log, ['pause']);
    engine.log.clear();
    player.toggle();
    await settle();
    expect(engine.log, ['play']);

    player.dispose();
    await settle();
    expect(engine.log.last, 'dispose');
  });

  test('the lived-in boot resumes from where it sat', () async {
    final engine = FakeEngine();
    final player = PlaybackController(List.of(library), engine: engine);
    await settle();
    engine.log.clear();

    // The deck boots paused mid-song; the first toggle loads the
    // current track from that very second.
    player.toggle();
    await settle();
    expect(engine.log, ['load ${player.current!.path} start:67 play:true']);

    player.dispose();
  });

  test('seeks and hops reach the engine; the needle leads', () async {
    final engine = FakeEngine();
    final player = PlaybackController(List.of(library), engine: engine);
    player.play(library.first);
    await settle();
    engine.log.clear();

    player.seekTo(0.5);
    await settle();
    expect(engine.log, ['seek 50']);
    engine.log.clear();

    player.skipBy(const Duration(seconds: 10));
    await settle();
    expect(engine.log, ['seek 60']);

    // The engine's own clock reports land on the deck's position (the
    // deck extrapolates between reports, so whole seconds is the ask).
    engine.emitPosition(const Duration(seconds: 61));
    await settle();
    expect(player.position.inSeconds, 61);

    player.dispose();
  });

  test('a finished file advances the queue through the engine', () async {
    final engine = FakeEngine();
    final player = PlaybackController(List.of(library), engine: engine);
    player.play(library.first);
    await settle();
    engine.log.clear();

    engine.emitCompleted();
    await settle();
    expect(player.current?.id, library[1].id);
    expect(engine.log, ['load /music/track1.flac start:0 play:true']);

    player.dispose();
  });

  test('volume and mute are the engine\'s to obey', () async {
    final engine = FakeEngine();
    final player = PlaybackController(List.of(library), engine: engine);
    await settle();
    engine.log.clear();

    player.volume = 0.3;
    await settle();
    expect(engine.log, ['volume 0.30']);
    engine.log.clear();

    player.toggleMute();
    await settle();
    expect(engine.log, ['volume 0.00']);

    player.dispose();
  });

  const film = MediaItem(
    id: 50,
    fileId: 50,
    path: '/videos/concert.mkv',
    metadata: VideoMetadata(
      title: 'Concert',
      duration: Duration(minutes: 96),
      chapters: [
        ChapterMark('Overture', Duration.zero),
        ChapterMark('First Set', Duration(minutes: 12)),
        ChapterMark('Encore', Duration(minutes: 80)),
      ],
    ),
    tags: [],
  );

  test('a film plays through the engine, and ends where it ends', () async {
    final engine = FakeEngine();
    final player = PlaybackController(List.of(library), engine: engine);
    await settle();
    engine.log.clear();

    player.open(film);
    await settle();
    expect(engine.log, ['load /videos/concert.mkv start:0 play:true']);
    expect(player.playing, isTrue);
    engine.log.clear();

    // The engine's clock reports land on the watching face too.
    engine.emitPosition(const Duration(minutes: 30));
    await settle();
    expect(player.position.inMinutes, 30);

    // Pause and scrub speak to the engine.
    player.toggle();
    await settle();
    expect(engine.log, ['pause']);
    engine.log.clear();
    player.seekTo(0.5);
    await settle();
    expect(engine.log, ['seek ${48 * 60}']);

    // Credits: the clock stops at the end; no queue plays behind a film.
    player.toggle();
    engine.emitCompleted();
    await settle();
    expect(player.playing, isFalse);
    expect(player.position, const Duration(minutes: 96));
    expect(player.current, isNotNull, reason: 'the audio queue kept its place');

    player.dispose();
  });

  test('the stop hops walk a film\'s scenes', () async {
    final engine = FakeEngine();
    final player = PlaybackController(List.of(library), engine: engine);
    player.open(film);
    await settle();
    engine.log.clear();

    // Ahead: the first stop past the needle.
    engine.emitPosition(const Duration(minutes: 13));
    await settle();
    player.nextStop();
    await settle();
    expect(engine.log, ['seek ${80 * 60}']);
    engine.log.clear();

    // Deep into a scene: back to its top…
    engine.emitPosition(const Duration(minutes: 30));
    await settle();
    player.previousStop();
    await settle();
    expect(engine.log, ['seek ${12 * 60}']);
    engine.log.clear();

    // …and from its top, back to the one before.
    player.previousStop();
    await settle();
    expect(engine.log, ['seek 0']);

    player.dispose();
  });

  test('an audiobook\'s chapters hop the same way', () async {
    final chaptered = AudioItem(
      id: 60,
      fileId: 60,
      path: '/books/the_carrier_tone.m4b',
      metadata: const AudioMetadata(
        title: 'The Carrier Tone',
        duration: Duration(hours: 9),
        chapters: [
          ChapterMark('One', Duration.zero),
          ChapterMark('Two', Duration(hours: 3)),
        ],
      ),
      tags: const [],
    );
    final engine = FakeEngine();
    final player = PlaybackController(List.of(library), engine: engine);
    player.play(chaptered);
    await settle();
    engine.log.clear();

    expect(player.stops, hasLength(2));
    player.nextStop();
    await settle();
    expect(engine.log, ['seek ${3 * 3600}']);

    player.dispose();
  });

  test('opening a still kind sets the sound aside', () async {
    final engine = FakeEngine();
    final player = PlaybackController(List.of(library), engine: engine);
    player.play(library.first);
    await settle();
    engine.log.clear();

    player.open(
      const MediaItem(
        id: 99,
        fileId: 99,
        path: '/comics/issue.cbz',
        metadata: DocumentMetadata(title: 'Issue', pageCount: 24),
        tags: [],
      ),
    );
    await settle();
    expect(engine.log, ['pause']);

    // The engine's trailing position reports no longer move the deck —
    // the page counter holds it now.
    engine.emitPosition(const Duration(seconds: 42));
    await settle();
    expect(player.progress, 0);

    player.dispose();
  });
}
