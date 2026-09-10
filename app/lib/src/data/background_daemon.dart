import 'dart:async';
import 'dart:io';

import 'package:cadence_client/cadence_client.dart';
import 'package:cadence_client/unix.dart';
import 'package:path/path.dart' as p;

import 'environment.dart';

/// Runs a command to completion; the seam tests hand a fake through.
typedef CommandRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// A `cadenced` the app can run: `bin/` and `lib/` in the layout
/// `cadence build` leaves — the copy the `cadenced` package installs under
/// `/usr/lib/cadenced`, the copy the app ships beside its executable, or
/// the workspace's own build.
class DaemonBundle {
  const DaemonBundle(this.directory, {this.installed = false});

  /// Where the `cadenced` package puts its bundle.
  static const packageRoot = '/usr/lib/cadenced';

  final Directory directory;

  /// True for the package's copy: already installed for every user, so
  /// the app runs it in place rather than copying it.
  final bool installed;

  String get executable => p.join(directory.path, 'bin', 'cadenced');
  Directory get lib => Directory(p.join(directory.path, 'lib'));

  /// Whether the native probe rides along; without it the daemon is
  /// started on the pure-Dart tiers alone.
  bool get hasProbe =>
      File(p.join(lib.path, 'libcadence_probe.so')).existsSync();

  /// The bundle the app can reach: `CADENCE_DAEMON_BUNDLE`, then the
  /// `cadenced` package's copy at [packageRoot] (the one the package
  /// manager keeps current, so it wins over anything the app carries),
  /// then `daemon/` beside the app's executable (where the packaged app
  /// keeps it), then the workspace's `build/cli/bundle` from the current
  /// directory or its parent (the dev loop, run from `app/` or the root).
  static DaemonBundle? locate({
    Map<String, String>? environment,
    String? executableDirectory,
    String? currentDirectory,
    String packageRoot = packageRoot,
  }) {
    final env = environment ?? Platform.environment;
    final exeDir =
        executableDirectory ?? p.dirname(Platform.resolvedExecutable);
    final cwd = currentDirectory ?? Directory.current.path;
    final candidates = [
      if (env['CADENCE_DAEMON_BUNDLE'] case final path? when path.isNotEmpty)
        DaemonBundle(Directory(p.normalize(path))),
      DaemonBundle(Directory(packageRoot), installed: true),
      DaemonBundle(Directory(p.join(exeDir, 'daemon'))),
      DaemonBundle(
        Directory(p.normalize(p.join(cwd, 'build', 'cli', 'bundle'))),
      ),
      DaemonBundle(
        Directory(
          p.normalize(p.join(p.dirname(cwd), 'build', 'cli', 'bundle')),
        ),
      ),
    ];
    for (final bundle in candidates) {
      if (File(bundle.executable).existsSync() &&
          File(p.join(bundle.lib.path, 'libsqlite3.so')).existsSync()) {
        return bundle;
      }
    }
    return null;
  }
}

/// `cadenced` as the user's own systemd service: installed from the
/// bundle into the user's data directory, enabled to start with their
/// session, and reached over the socket its unit places in the runtime
/// directory. The unit mirrors `daemon/packaging/systemd/cadenced.user.
/// service.liquid`, but names the library's paths outright so the daemon
/// opens exactly the database the built-in host was using.
class BackgroundDaemon {
  /// [bundle] names the daemon to install; left null it is looked for in
  /// the usual places, unless [locateBundle] is false.
  BackgroundDaemon({
    required this.environment,
    DaemonBundle? bundle,
    bool locateBundle = true,
    Map<String, String>? platform,
    CommandRunner? run,
    bool? linux,
  }) : _platform = platform ?? Platform.environment,
       _run = run ?? Process.run,
       _linux = linux ?? Platform.isLinux,
       bundle =
           bundle ??
           (locateBundle ? DaemonBundle.locate(environment: platform) : null);

  static const unit = 'cadenced.service';

  final AppEnvironment environment;
  final DaemonBundle? bundle;
  final Map<String, String> _platform;
  final CommandRunner _run;
  final bool _linux;

  String get _home =>
      _platform['HOME'] ?? _platform['USERPROFILE'] ?? Directory.current.path;

  String? get _runtimeDir => switch (_platform['XDG_RUNTIME_DIR']) {
    final dir? when dir.isNotEmpty && p.isAbsolute(dir) => dir,
    _ => null,
  };

  /// `$XDG_RUNTIME_DIR/cadence/media.sock` — `RuntimeDirectory=cadence`
  /// in the unit, the daemon's `--socket` beneath it.
  String? get socketPath => switch (_runtimeDir) {
    final dir? => p.join(dir, 'cadence', 'media.sock'),
    null => null,
  };

  String _xdg(String variable, List<String> fallback) =>
      switch (_platform[variable]) {
        final value? when value.isNotEmpty && p.isAbsolute(value) => value,
        _ => p.joinAll([_home, ...fallback]),
      };

  /// `~/.local/share/cadenced` — where the bundle is copied to.
  Directory get installDirectory =>
      Directory(p.join(_xdg('XDG_DATA_HOME', ['.local', 'share']), 'cadenced'));

  /// `~/.config/systemd/user/cadenced.service`.
  File get unitFile => File(
    p.join(_xdg('XDG_CONFIG_HOME', ['.config']), 'systemd', 'user', unit),
  );

  /// Why the background service cannot be offered here, or null when it
  /// can — before asking systemd anything.
  String? get unavailableReason {
    if (!_linux) return 'Background mode needs Linux with systemd.';
    if (_runtimeDir == null) {
      return 'No session runtime directory: is this a systemd user session?';
    }
    if (bundle == null) return 'This build of Cadence does not carry cadenced.';
    return null;
  }

  bool get available => unavailableReason == null;

  Future<ProcessResult> _systemctl(List<String> arguments) =>
      _run('systemctl', ['--user', ...arguments]);

  /// Whether the user's systemd manager answers at all.
  Future<bool> systemdAvailable() async {
    if (!available) return false;
    try {
      return (await _systemctl(['show', '-p', 'ActiveState', unit])).exitCode ==
          0;
    } on ProcessException {
      return false;
    }
  }

  /// Whether the unit is running right now.
  Future<bool> isActive() async {
    if (!available) return false;
    try {
      return (await _systemctl(['is-active', unit])).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// Whether a daemon answers on the socket — whoever started it.
  Future<bool> answering() async {
    final path = socketPath;
    if (path == null || !File(path).existsSync()) return false;
    final transport = UnixMediaTransport(
      path,
      timeout: const Duration(seconds: 3),
    );
    try {
      await transport.request('get', '/capabilities');
      return true;
    } on Object {
      return false;
    } finally {
      await transport.close();
    }
  }

  /// A transport to the daemon's socket.
  MediaTransport connect() {
    final path = socketPath;
    if (path == null) throw StateError(unavailableReason!);
    return UnixMediaTransport(path);
  }

  /// Puts the daemon where the unit will run it and writes the unit. The
  /// package's copy is run in place; any other is copied into the user's
  /// data directory. Safe to repeat; a running daemon keeps its old binary
  /// until it restarts.
  Future<void> install() async {
    final source = bundle;
    if (source == null) throw StateError(unavailableReason!);
    final String executable;
    if (source.installed) {
      executable = source.executable;
    } else {
      final target = installDirectory;
      await target.create(recursive: true);
      for (final part in ['bin', 'lib']) {
        final from = Directory(p.join(source.directory.path, part));
        final to = Directory(p.join(target.path, part));
        await to.create(recursive: true);
        await for (final entry in from.list(followLinks: false)) {
          if (entry is! File) continue;
          final copy = p.join(to.path, p.basename(entry.path));
          await entry.copy(copy);
          if (part == 'bin') await _run('chmod', ['755', copy]);
        }
      }
      executable = p.join(target.path, 'bin', 'cadenced');
    }
    await unitFile.parent.create(recursive: true);
    await unitFile.writeAsString(
      unitText(
        executable: executable,
        databasePath: environment.databasePath,
        cachePath: environment.cacheDir.path,
        native: source.hasProbe,
      ),
      flush: true,
    );
    _check(await _systemctl(['daemon-reload']), 'daemon-reload');
  }

  /// Installs, enables and starts the service, and waits until it
  /// answers on the socket.
  Future<void> start() async {
    await install();
    _check(await _systemctl(['enable', '--now', unit]), 'enable --now');
    await _await(
      () => answering(),
      const Duration(seconds: 20),
      'cadenced did not answer on ${socketPath!}',
    );
  }

  /// Stops and disables the service, and waits for it to let the
  /// library go.
  Future<void> stop() async {
    _check(await _systemctl(['disable', '--now', unit]), 'disable --now');
    await _settled();
  }

  /// Stops the service for now, leaving it enabled for the next session:
  /// the move when it dropped out and the app takes the library back —
  /// a unit left running would keep restarting into the app's lock.
  Future<void> halt() async {
    _check(await _systemctl(['stop', unit]), 'stop');
    await _settled();
  }

  Future<void> _settled() => _await(
    () async => !await isActive() && !await answering(),
    const Duration(seconds: 75),
    'cadenced did not stop',
  );

  Future<void> _await(
    Future<bool> Function() condition,
    Duration limit,
    String failure,
  ) async {
    final deadline = DateTime.now().add(limit);
    while (!await condition()) {
      if (DateTime.now().isAfter(deadline)) throw StateError(failure);
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  void _check(ProcessResult result, String what) {
    if (result.exitCode != 0) {
      final detail = '${result.stderr}'.trim();
      throw StateError(
        'systemctl --user $what failed'
        '${detail.isEmpty ? '' : ': $detail'}',
      );
    }
  }

  /// The unit, rendered. Paths are quoted the way systemd reads them —
  /// `%` doubled, `$` doubled, quotes and backslashes escaped.
  static String unitText({
    required String executable,
    required String databasePath,
    required String cachePath,
    required bool native,
  }) {
    String q(String value) =>
        '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('%', '%%').replaceAll(r'$', r'$$')}"';
    return '''
[Unit]
Description=Cadence media library daemon
# Written by Cadence. Mirrors daemon/packaging/systemd/cadenced.user.service.liquid
# with the library's own paths, so the daemon opens what the app was using.

[Service]
Type=simple
RuntimeDirectory=cadence
RuntimeDirectoryMode=0700
UMask=0077
ExecStart=${q(executable)} --database ${q(databasePath)} --cache ${q(cachePath)} --socket "%t/cadence/media.sock" --policy lean${native ? ' --native true' : ''}
Restart=on-failure
RestartSec=3
TimeoutStopSec=60
NoNewPrivileges=true

[Install]
WantedBy=default.target
''';
  }
}
