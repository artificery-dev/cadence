import 'dart:async';
import 'dart:io';

import 'package:cadence_client/cadence_client.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_preferences.dart';
import 'background_daemon.dart';
import 'embedded_library.dart';
import 'environment.dart';
import 'library_connection.dart';

/// Where the library runs, and the hand that moves it: the built-in host
/// by default, the user's `cadenced` service when they ask Cadence to run
/// in the background. [connect] chooses at boot; [setBackground] moves a
/// running app between the two without the deck stopping.
class HostingController extends ChangeNotifier {
  HostingController({
    required this.environment,
    required this.preferences,
    required this.daemon,
    required this.connection,
    this.notice,
    this.restartGrace = const Duration(seconds: 8),
  }) {
    _lost = connection.lost.listen((_) => unawaited(_recover()));
  }

  /// How long a daemon that dropped out is given to come back — systemd
  /// restarts a failed unit after three seconds — before the app takes
  /// the library back inside.
  final Duration restartGrace;
  StreamSubscription<void>? _lost;

  final AppEnvironment environment;
  final AppPreferences preferences;
  final BackgroundDaemon daemon;
  final LibraryConnection connection;

  /// Something worth telling the user about how the boot went — the
  /// daemon asked for but not reached, say. Read once by the shell.
  final String? notice;

  bool _busy = false;
  String? _error;

  /// Whether the library is currently the daemon's.
  bool get background => connection.hosting == LibraryHosting.daemon;

  /// True while a handover is in progress.
  bool get busy => _busy;

  /// What went wrong the last time a handover was asked for; cleared by
  /// the next attempt.
  String? get error => _error;

  /// Why the switch is greyed out, or null when it can be flipped.
  String? get unavailableReason => daemon.unavailableReason;

  /// The daemon stopped answering. Give it the grace to restart and pick
  /// the line back up; failing that, take the library back inside — and
  /// stop the unit, so a restarting daemon does not keep failing against
  /// the app's lock. The preference is left as it was: the next launch
  /// tries the background again.
  Future<void> _recover() async {
    if (!background || _busy) return;
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      await connection.exchange((current) async {
        await current.close();
        final deadline = DateTime.now().add(restartGrace);
        while (DateTime.now().isBefore(deadline)) {
          if (await daemon.answering()) {
            return (daemon.connect(), LibraryHosting.daemon);
          }
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        try {
          await daemon.halt();
        } on Object {
          // Not ours to stop, or already gone; the lock decides below.
        }
        _error =
            'The background service stopped; the library is running '
            'inside Cadence until it is switched back on.';
        return (await _embed(environment, daemon), LibraryHosting.embedded);
      });
    } on Object catch (error) {
      _error = '$error';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _lost?.cancel();
    super.dispose();
  }

  /// Opens the library the way the preferences and the machine allow: the
  /// daemon when one already answers or was asked for and can be started,
  /// the built-in host otherwise.
  static Future<HostingController> connect({
    required AppEnvironment environment,
    required AppPreferences preferences,
    required BackgroundDaemon daemon,
  }) async {
    String? notice;
    MediaTransport? transport;
    var hosting = LibraryHosting.embedded;
    if (daemon.available) {
      if (await daemon.answering()) {
        transport = daemon.connect();
        hosting = LibraryHosting.daemon;
        if (!preferences.background) await preferences.setBackground(true);
      } else if (preferences.background) {
        try {
          await daemon.start();
          transport = daemon.connect();
          hosting = LibraryHosting.daemon;
        } on Object catch (error) {
          notice =
              'Could not start the background service ($error); '
              'running the library inside Cadence for now.';
        }
      }
    }
    transport ??= await _embed(environment, daemon);
    return HostingController(
      environment: environment,
      preferences: preferences,
      daemon: daemon,
      connection: LibraryConnection(transport, hosting: hosting),
      notice: notice,
    );
  }

  static Future<EmbeddedLibrary> _embed(
    AppEnvironment environment,
    BackgroundDaemon daemon,
  ) => EmbeddedLibrary.spawn(
    databasePath: environment.databasePath,
    cachePath: environment.cacheDir.path,
    probeSearch: [
      if (daemon.bundle case final bundle?) bundle.lib.path,
      p.join(p.dirname(Platform.resolvedExecutable), 'lib'),
    ],
  );

  /// Moves the library to the daemon ([value] true) or back inside the
  /// app. The built-in host is closed before the daemon starts — the
  /// database has one owner at a time — and reopened if the daemon
  /// cannot be reached, so the app is never left without a library.
  Future<void> setBackground(bool value) async {
    if (value == background || _busy) return;
    if (value && !daemon.available) {
      _error = daemon.unavailableReason;
      notifyListeners();
      return;
    }
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      if (value) {
        await connection.exchange((current) async {
          await current.close();
          try {
            if (!await daemon.answering()) await daemon.start();
            return (daemon.connect(), LibraryHosting.daemon);
          } on Object catch (error) {
            _error = 'Could not start the background service: $error';
            // Back to a library of our own before anyone asks for it.
            return (await _embed(environment, daemon), LibraryHosting.embedded);
          }
        });
        await preferences.setBackground(_error == null);
      } else {
        await preferences.setBackground(false);
        await connection.exchange((current) async {
          await current.close();
          try {
            await daemon.stop();
          } on Object catch (error) {
            // Still ours to run: a daemon that would not stop keeps the
            // lock, and the spawn below says so in its own words.
            _error = 'Could not stop the background service: $error';
          }
          return (await _embed(environment, daemon), LibraryHosting.embedded);
        });
      }
    } on Object catch (error) {
      _error = '$error';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
