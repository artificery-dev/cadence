import 'package:tomeui/tomeui.dart';

/// The seam between the deck and whatever actually makes sound. The
/// [PlaybackController] owns the queue, the modes, and the truth the UI
/// reads; an engine only loads files, runs them, and reports back. Kept
/// abstract so tests can hand the deck a silent stand-in and the real
/// backend stays a detail.
abstract interface class AudioEngine {
  /// Loads [path] and, when [play], starts it — from [start], for the
  /// resumes and the lived-in boots.
  Future<void> load(String path, {Duration start, bool play});

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// 0–1, after mute has spoken — the deck sends what should be heard.
  Future<void> setVolume(double value);

  /// Unloads whatever is playing; the engine goes quiet.
  Future<void> stop();

  Future<void> dispose();

  /// The live picture of whatever is loaded, when this engine can draw
  /// one. Null from engines without eyes — the deck paints a stand-in.
  Widget? videoSurface(BuildContext context);

  /// Where the needle really is, spoken as the file plays.
  Stream<Duration> get positions;

  /// The file ran out — the deck decides what comes next.
  Stream<void> get completed;
}
