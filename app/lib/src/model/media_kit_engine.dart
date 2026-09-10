import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:tomeui/tomeui.dart';

import 'audio_engine.dart';

/// The real sound: an [AudioEngine] over package:media_kit's [Player]
/// (libmpv underneath). Call [MediaKitEngine.ensureInitialized] once
/// before the first construction — main does, on the way up.
class MediaKitEngine implements AudioEngine {
  MediaKitEngine() : _player = Player();

  final Player _player;

  /// The texture the surfaces draw — made on first ask, so audio-only
  /// sessions never spin the video plumbing up.
  VideoController? _video;

  /// Hands media_kit its natives. Idempotent, cheap to call again.
  static void ensureInitialized() => MediaKit.ensureInitialized();

  @override
  Widget videoSurface(BuildContext context) => Video(
    controller: _video ??= VideoController(_player),
    // The deck's bar owns every control; the surface only shows.
    controls: NoVideoControls,
  );

  @override
  Future<void> load(
    String path, {
    Duration start = Duration.zero,
    bool play = true,
  }) async {
    // Open paused, place the needle, then let it go — a seek folded
    // into the open would race the file's headers.
    await _player.open(Media(path), play: false);
    if (start > Duration.zero) await _player.seek(start);
    if (play) await _player.play();
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(double value) =>
      _player.setVolume((value.clamp(0.0, 1.0)) * 100);

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() => _player.dispose();

  @override
  Stream<Duration> get positions => _player.stream.position;

  @override
  Stream<void> get completed => _player.stream.completed.where((done) => done);
}
