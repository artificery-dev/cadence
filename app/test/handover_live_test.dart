@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';

import 'package:cadence/src/data/app_preferences.dart';
import 'package:cadence/src/data/background_daemon.dart';
import 'package:cadence/src/data/environment.dart';
import 'package:cadence/src/data/hosting.dart';
import 'package:cadence/src/data/library_connection.dart';
import 'package:cadence_media/cadence_media.dart' show LibraryType;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The whole handover against this machine's own systemd: installs the
/// real `cadenced.service` for the current user, moves a library out to
/// it and back, and removes what it installed. Run on purpose only:
///
///     CADENCE_LIVE_SYSTEMD=1 flutter test --tags live test/handover_live_test.dart
void main() {
  final live = Platform.environment['CADENCE_LIVE_SYSTEMD'] == '1';
  test(
    'the library moves out to cadenced and back',
    () async {
      final temp = await Directory.systemTemp.createTemp('cadence_live_');
      final environment = AppEnvironment.fromArgs([
        '--portable-dir=${p.join(temp.path, 'deck')}',
      ]);
      await environment.prepare();
      final preferences = await AppPreferences.load(
        environment.preferencesFile,
      );
      final daemon = BackgroundDaemon(environment: environment);
      expect(daemon.unavailableReason, isNull);
      expect(await daemon.systemdAvailable(), isTrue);
      expect(await daemon.answering(), isFalse, reason: 'no daemon yet');

      final hosting = await HostingController.connect(
        environment: environment,
        preferences: preferences,
        daemon: daemon,
      );
      final connection = hosting.connection;
      try {
        expect(connection.hosting, LibraryHosting.embedded);
        final id = await connection.client.createLibrary(
          'Music',
          LibraryType.music,
        );

        await hosting.setBackground(true);
        expect(hosting.error, isNull);
        expect(connection.hosting, LibraryHosting.daemon);
        expect(await daemon.isActive(), isTrue);
        expect(await daemon.answering(), isTrue);
        expect(preferences.background, isTrue);
        // The same library, now served by the daemon.
        expect((await connection.client.listLibraries()).single.id, id);
        await connection.client.renameLibrary(id, 'Tunes');

        await hosting.setBackground(false);
        expect(hosting.error, isNull);
        expect(connection.hosting, LibraryHosting.embedded);
        expect(await daemon.isActive(), isFalse);
        expect(preferences.background, isFalse);
        expect((await connection.client.listLibraries()).single.name, 'Tunes');

        // Out again — and this time the daemon is stopped from outside, the
        // way an upgrade or a `systemctl --user stop` would: the app
        // notices, waits out the restart grace, and takes the library back.
        await hosting.setBackground(true);
        expect(connection.hosting, LibraryHosting.daemon);
        final recovered = Completer<void>();
        hosting.addListener(() {
          if (!hosting.busy &&
              connection.hosting == LibraryHosting.embedded &&
              !recovered.isCompleted) {
            recovered.complete();
          }
        });
        await Process.run('systemctl', ['--user', 'stop', 'cadenced.service']);
        await recovered.future.timeout(const Duration(seconds: 40));
        expect(hosting.error, contains('stopped'));
        expect(preferences.background, isTrue, reason: 'the wish stands');
        expect((await connection.client.listLibraries()).single.name, 'Tunes');
        await hosting.setBackground(false);
      } finally {
        await connection.client.close();
        // Leave the machine as found.
        await Process.run('systemctl', [
          '--user',
          'disable',
          '--now',
          'cadenced.service',
        ]);
        if (daemon.unitFile.existsSync()) daemon.unitFile.deleteSync();
        await Process.run('systemctl', ['--user', 'daemon-reload']);
        if (daemon.installDirectory.existsSync()) {
          daemon.installDirectory.deleteSync(recursive: true);
        }
        await temp.delete(recursive: true);
      }
    },
    skip: live ? false : 'set CADENCE_LIVE_SYSTEMD=1 to run against systemd',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
