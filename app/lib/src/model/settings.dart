import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:cadence_media/cadence_media.dart'
    hide File, Directory, FileSystemEntity, FileSystem, Link;
import 'package:tomeui/tomeui.dart';

enum ThemePreference { system, light, dark }

enum ReplayGainMode { off, track, album }

/// What the Now Playing panel draws. A named handful for now; someday a
/// registry that custom-drawn visualizers plug into.
enum VisualizerMode {
  spectrum('Spectrum'),
  scope('Scope'),
  off('Off');

  const VisualizerMode(this.label);

  final String label;

  VisualizerMode get next =>
      VisualizerMode.values[(index + 1) % VisualizerMode.values.length];
}

/// Every colour set tomeui defines, as an enum — any palette slot may wear
/// any of them, and settings store the name, never a loose string.
enum PaletteSet {
  red(Swatch.red),
  orange(Swatch.orange),
  amber(Swatch.amber),
  yellow(Swatch.yellow),
  lime(Swatch.lime),
  green(Swatch.green),
  emerald(Swatch.emerald),
  teal(Swatch.teal),
  cyan(Swatch.cyan),
  sky(Swatch.sky),
  blue(Swatch.blue),
  indigo(Swatch.indigo),
  violet(Swatch.violet),
  purple(Swatch.purple),
  fuchsia(Swatch.fuchsia),
  pink(Swatch.pink),
  rose(Swatch.rose),
  slate(Swatch.slate),
  gray(Swatch.gray),
  zinc(Swatch.zinc),
  ash(Swatch.ash),
  stone(Swatch.stone),
  mauve(Swatch.mauve),
  olive(Swatch.olive),
  mist(Swatch.mist),
  taupe(Swatch.taupe);

  const PaletteSet(this.swatch);

  final Swatch swatch;

  /// How the set reads in a select.
  String get label => name[0].toUpperCase() + name.substring(1);
}

/// The app's settings, declared once — dotted keys live here and nowhere
/// else; call sites speak in definitions.
abstract final class AppSettings {
  static final theme = SettingDef.enumOf(
    'appearance.theme_preference',
    ThemePreference.values,
    ThemePreference.system,
  );
  static final primary = SettingDef.enumOf(
    'appearance.palette.primary',
    PaletteSet.values,
    PaletteSet.sky,
  );
  static final accent = SettingDef.enumOf(
    'appearance.palette.accent',
    PaletteSet.values,
    PaletteSet.emerald,
  );
  static final neutral = SettingDef.enumOf(
    'appearance.palette.neutral',
    PaletteSet.values,
    PaletteSet.mist,
  );
  static final visualizer = SettingDef.enumOf(
    'now_playing.visualizer',
    VisualizerMode.values,
    VisualizerMode.spectrum,
  );
  static final crossfadeSeconds = SettingDef.json<num>(
    'playback.crossfade_seconds',
    4,
  );
  static final gapless = SettingDef.json<bool>('playback.gapless', true);
  static final replayGain = SettingDef.enumOf(
    'playback.replay_gain',
    ReplayGainMode.values,
    ReplayGainMode.album,
  );
  static final resumeOnLaunch = SettingDef.json<bool>(
    'playback.resume_on_launch',
    true,
  );

  /// The deck's level, remembered across sessions.
  static final volume = SettingDef.json<num>('playback.volume', 0.72);

  /// Where the sidebar last pointed, as a small JSON map — the shell
  /// encodes it on every navigation and decodes it at boot, falling
  /// back gracefully when what it names no longer exists.
  static final lastView = SettingDef.json<Map<String, Object?>>(
    'ui.last_view',
    const {},
  );

  /// The order the sidebar's sections were last left in, as ids. Written
  /// when a section is unlocked and its rows dragged.
  static final libraryOrder = _order('sidebar.library_order');
  static final collectionOrder = _order('sidebar.collection_order');

  /// A remembered run of row ids. Hand-rolled rather than [SettingDef.json]
  /// because `jsonDecode` answers `List<dynamic>`, and casting that whole
  /// to `List<int>` throws on the way back in.
  static SettingDef<List<int>> _order(String key) => SettingDef(
    key: key,
    fallback: const [],
    encode: (ids) => ids,
    decode: (raw) => raw is! List
        ? const []
        : [
            for (final id in raw)
              if (id is num) id.toInt(),
          ],
  );
}

/// Rows in the order the sidebar was left in: the remembered ids first, in
/// the order they were remembered, then everything the order has never
/// seen — a library made since — on the end, in creation order.
List<T> inSidebarOrder<T>(
  List<T> rows,
  List<int> order,
  int Function(T row) idOf,
) {
  final waiting = {for (final row in rows) idOf(row): row};
  return [
    for (final id in order) ?waiting.remove(id),
    for (final row in rows)
      if (waiting.containsKey(idOf(row))) row,
  ];
}

/// App settings, and the theme they add up to. State lives here for the
/// widgets; every change writes through to the settings table, and [load]
/// reads it back at startup.
class SettingsModel extends ChangeNotifier {
  SettingsModel(this._client);

  final MediaClient _client;

  ThemePreference _themePreference = AppSettings.theme.fallback;
  PaletteSet _primary = AppSettings.primary.fallback;
  PaletteSet _accent = AppSettings.accent.fallback;
  PaletteSet _neutral = AppSettings.neutral.fallback;
  VisualizerMode _visualizer = AppSettings.visualizer.fallback;
  double _crossfadeSeconds = AppSettings.crossfadeSeconds.fallback.toDouble();
  bool _gapless = AppSettings.gapless.fallback;
  ReplayGainMode _replayGain = AppSettings.replayGain.fallback;
  bool _resumeOnLaunch = AppSettings.resumeOnLaunch.fallback;
  bool _watchFolders = ScannerSettings.watchFolders.fallback;
  List<int> _libraryOrder = AppSettings.libraryOrder.fallback;
  List<int> _collectionOrder = AppSettings.collectionOrder.fallback;
  double _volume = AppSettings.volume.fallback.toDouble();
  Map<String, Object?> _lastView = AppSettings.lastView.fallback;

  /// Reads everything the table remembers, once, before the first frame.
  Future<void> load() async {
    _themePreference = await _client.getSetting(AppSettings.theme);
    _primary = await _client.getSetting(AppSettings.primary);
    _accent = await _client.getSetting(AppSettings.accent);
    _neutral = await _client.getSetting(AppSettings.neutral);
    _visualizer = await _client.getSetting(AppSettings.visualizer);
    _crossfadeSeconds = (await _client.getSetting(
      AppSettings.crossfadeSeconds,
    )).toDouble();
    _gapless = await _client.getSetting(AppSettings.gapless);
    _replayGain = await _client.getSetting(AppSettings.replayGain);
    _resumeOnLaunch = await _client.getSetting(AppSettings.resumeOnLaunch);
    _watchFolders = await _client.getSetting(ScannerSettings.watchFolders);
    _libraryOrder = await _client.getSetting(AppSettings.libraryOrder);
    _collectionOrder = await _client.getSetting(AppSettings.collectionOrder);
    _volume = (await _client.getSetting(
      AppSettings.volume,
    )).toDouble().clamp(0.0, 1.0);
    _lastView = (await _client.getSetting(
      AppSettings.lastView,
    )).cast<String, Object?>();
    notifyListeners();
  }

  ThemePreference get themePreference => _themePreference;
  PaletteSet get primary => _primary;
  PaletteSet get accent => _accent;
  PaletteSet get neutral => _neutral;
  VisualizerMode get visualizer => _visualizer;
  double get crossfadeSeconds => _crossfadeSeconds;
  bool get gapless => _gapless;
  ReplayGainMode get replayGain => _replayGain;
  bool get resumeOnLaunch => _resumeOnLaunch;
  bool get watchFolders => _watchFolders;
  List<int> get libraryOrder => _libraryOrder;
  List<int> get collectionOrder => _collectionOrder;

  set themePreference(ThemePreference value) {
    _themePreference = value;
    _put(AppSettings.theme, value);
  }

  set primary(PaletteSet value) {
    _primary = value;
    _put(AppSettings.primary, value);
  }

  set accent(PaletteSet value) {
    _accent = value;
    _put(AppSettings.accent, value);
  }

  set neutral(PaletteSet value) {
    _neutral = value;
    _put(AppSettings.neutral, value);
  }

  set visualizer(VisualizerMode value) {
    _visualizer = value;
    _put(AppSettings.visualizer, value);
  }

  /// The Winamp gesture: clicking the panel walks the modes.
  void cycleVisualizer() => visualizer = _visualizer.next;

  set crossfadeSeconds(double value) {
    _crossfadeSeconds = value;
    _put(AppSettings.crossfadeSeconds, value);
  }

  set gapless(bool value) {
    _gapless = value;
    _put(AppSettings.gapless, value);
  }

  set replayGain(ReplayGainMode value) {
    _replayGain = value;
    _put(AppSettings.replayGain, value);
  }

  set resumeOnLaunch(bool value) {
    _resumeOnLaunch = value;
    _put(AppSettings.resumeOnLaunch, value);
  }

  /// The scanner's own key, not one of [AppSettings]: the service rewires
  /// its folder watchers the moment the write lands.
  set watchFolders(bool value) {
    _watchFolders = value;
    _put(ScannerSettings.watchFolders, value);
  }

  set libraryOrder(List<int> value) {
    _libraryOrder = value;
    _put(AppSettings.libraryOrder, value);
  }

  set collectionOrder(List<int> value) {
    _collectionOrder = value;
    _put(AppSettings.collectionOrder, value);
  }

  double get volume => _volume;

  /// Silent on purpose: the slider reads the deck, not this — a notify
  /// per drag tick would repaint the whole app for nothing.
  set volume(double value) {
    _volume = value;
    unawaited(_client.setSetting(AppSettings.volume, value));
  }

  Map<String, Object?> get lastView => _lastView;

  /// Silent for the same reason: nothing draws from it — it is read
  /// once, at the next boot.
  set lastView(Map<String, Object?> value) {
    _lastView = value;
    unawaited(_client.setSetting(AppSettings.lastView, value));
  }

  void _put<T>(SettingDef<T> def, T value) {
    unawaited(_write(def, value));
    notifyListeners();
  }

  /// A write the host refuses — a watcher it has no adapter for, a line
  /// that dropped — must not take the app down; the setting keeps the
  /// value shown, and the next boot reads back whatever the host kept.
  Future<void> _write<T>(SettingDef<T> def, T value) async {
    try {
      await _client.setSetting(def, value);
    } on Object catch (error) {
      debugPrint('Setting ${def.key} not saved: $error');
    }
  }

  Brightness get _brightness => switch (_themePreference) {
    ThemePreference.light => Brightness.light,
    ThemePreference.dark => Brightness.dark,
    ThemePreference.system => PlatformDispatcher.instance.platformBrightness,
  };

  /// The whole app's look, assembled from the choices above.
  Theme get theme => Theme(
    typography: const Typography.recursive(),
    palette: Palette(
      brightness: _brightness,
      primary: _primary.swatch,
      accent: _accent.swatch,
      neutral: _neutral.swatch,
    ),
  );
}
