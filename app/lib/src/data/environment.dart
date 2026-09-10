import 'dart:io';

import 'package:path/path.dart' as p;

/// Where the app keeps itself.
///
/// Installed normally, the platform decides — the XDG directories on
/// Linux, the usual application folders elsewhere — and [portableRoot] is
/// null. Handed `--portable-dir=<path>`, everything an installed copy
/// would scatter across `~/.local/state`, `~/.cache` and `~/.config` lives
/// together under `<path>/.cadence/`, and file pickers (a new library, an
/// import) open at the portable root.
///
/// The installed layout is the one `cadenced`'s user service uses —
/// `library.sqlite` in the state directory, the cache directory beside —
/// so the built-in host and the background daemon read the same library,
/// and handing over between them is a matter of who holds the lock.
class AppEnvironment {
  const AppEnvironment._({this.portableRoot, Map<String, String>? platform})
    : _platform = platform; // ignore: prefer_initializing_formals

  /// An installed copy: platform directories, no portable root.
  const AppEnvironment.installed({Map<String, String>? platform})
    : this._(platform: platform);

  /// The directory `--portable-dir` named, absolute, or null when the app
  /// is running as an installed copy.
  final Directory? portableRoot;

  /// The environment variables the platform directories are read from;
  /// null means the process's own.
  final Map<String, String>? _platform;

  Map<String, String> get _env => _platform ?? Platform.environment;

  bool get portable => portableRoot != null;

  /// `<root>/.cadence` — the portable twin of the install's directories.
  Directory? get portableHome =>
      portable ? Directory(p.join(portableRoot!.path, '.cadence')) : null;

  String get _home =>
      _env['HOME'] ?? _env['USERPROFILE'] ?? Directory.current.path;

  String _xdg(String variable, List<String> fallback) {
    final value = _env[variable];
    if (value != null && value.isNotEmpty && p.isAbsolute(value)) {
      return p.join(value, 'cadence');
    }
    return p.joinAll([_home, ...fallback, 'cadence']);
  }

  /// Where the library database lives: `<root>/.cadence/library.sqlite`
  /// portable, `$XDG_STATE_HOME/cadence/library.sqlite` installed.
  String get databasePath => portable
      ? p.join(portableHome!.path, 'library.sqlite')
      : p.join(stateDir.path, 'library.sqlite');

  /// The state half (`~/.local/state/cadence` at home): the database.
  Directory get stateDir => Directory(
    portable
        ? portableHome!.path
        : Platform.isLinux
        ? _xdg('XDG_STATE_HOME', ['.local', 'state'])
        : _appSupport,
  );

  /// The cache half (`~/.cache/cadence` at home): rendered artwork.
  Directory get cacheDir => Directory(
    portable
        ? p.join(portableHome!.path, 'cache')
        : Platform.isLinux
        ? _xdg('XDG_CACHE_HOME', ['.cache'])
        : p.join(_appSupport, 'cache'),
  );

  /// The config half (`~/.config/cadence` at home): the few preferences
  /// that must be read before the library is reached.
  Directory get configDir => Directory(
    portable
        ? p.join(portableHome!.path, 'config')
        : Platform.isLinux
        ? _xdg('XDG_CONFIG_HOME', ['.config'])
        : _appSupport,
  );

  /// The one application folder the other desktops offer.
  String get _appSupport => Platform.isMacOS
      ? p.join(_home, 'Library', 'Application Support', 'cadence')
      : Platform.isWindows
      ? p.join(
          _env['APPDATA'] ?? p.join(_home, 'AppData', 'Roaming'),
          'cadence',
        )
      : p.join(_home, '.cadence');

  /// The preferences file, in [configDir].
  File get preferencesFile => File(p.join(configDir.path, 'app.json'));

  /// Where file pickers open first — the portable root, when there is one.
  Directory? get defaultPickerDirectory => portableRoot;

  /// Reads `--portable-dir=<path>` (or `--portable-dir <path>`) out of the
  /// program arguments. Anything else is left alone.
  static AppEnvironment fromArgs(
    List<String> args, {
    Map<String, String>? platform,
  }) {
    String? path;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--portable-dir' && i + 1 < args.length) {
        path = args[i + 1];
      } else if (arg.startsWith('--portable-dir=')) {
        path = arg.substring('--portable-dir='.length);
      }
    }
    if (path == null || path.isEmpty) {
      return AppEnvironment._(platform: platform);
    }
    return AppEnvironment._(
      portableRoot: Directory(p.normalize(p.absolute(path))),
      platform: platform,
    );
  }

  /// Stands up the directories the app writes into.
  Future<void> prepare() async {
    await stateDir.create(recursive: true);
    await cacheDir.create(recursive: true);
    await configDir.create(recursive: true);
  }
}
