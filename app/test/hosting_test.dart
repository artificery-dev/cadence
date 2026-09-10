import 'dart:async';
import 'dart:io';

import 'package:cadence/src/data/app_preferences.dart';
import 'package:cadence/src/data/background_daemon.dart';
import 'package:cadence/src/data/environment.dart';
import 'package:cadence/src/data/hosting.dart';
import 'package:cadence/src/data/library_connection.dart';
import 'package:cadence_client/cadence_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A daemon's transport, as far as the app can tell, that hangs up.
class _Daemon implements MediaTransport {
  final events$ = StreamController<Map<String, Object?>>.broadcast();
  bool closed = false;

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async => const {};

  @override
  Future<List<int>?> artwork(int fileId) async => null;

  @override
  Stream<Map<String, Object?>> get events => events$.stream;

  @override
  Future<void> close() async => closed = true;
}

void main() {
  test(
    'a daemon that drops out is halted and the library comes back inside',
    () async {
      final temp = await Directory.systemTemp.createTemp('cadence_hosting_');
      addTearDown(() => temp.delete(recursive: true));
      final environment = AppEnvironment.fromArgs([
        '--portable-dir=${p.join(temp.path, 'deck')}',
      ]);
      await environment.prepare();
      final calls = <List<String>>[];
      final daemon = BackgroundDaemon(
        environment: environment,
        bundle: DaemonBundle(Directory(p.join(temp.path, 'nowhere'))),
        platform: {
          'HOME': temp.path,
          'XDG_RUNTIME_DIR': p.join(temp.path, 'run'),
        },
        linux: true,
        run: (executable, arguments) async {
          calls.add([executable, ...arguments]);
          // The unit reads active until stop has been asked for.
          final stopped = calls.any((c) => c.contains('stop'));
          final active = arguments.contains('is-active') && !stopped;
          return ProcessResult(
            0,
            active || !arguments.contains('is-active') ? 0 : 3,
            '',
            '',
          );
        },
      );
      final transport = _Daemon();
      final connection = LibraryConnection(
        transport,
        hosting: LibraryHosting.daemon,
      );
      final hosting = HostingController(
        environment: environment,
        preferences: await AppPreferences.load(environment.preferencesFile),
        daemon: daemon,
        connection: connection,
        restartGrace: const Duration(milliseconds: 600),
      );
      addTearDown(hosting.dispose);
      final settled = Completer<void>();
      var sawBusy = false;
      hosting.addListener(() {
        if (hosting.busy) sawBusy = true;
        if (sawBusy && !hosting.busy && !settled.isCompleted) {
          settled.complete();
        }
      });

      await transport.events$.close();
      await settled.future.timeout(const Duration(seconds: 30));

      expect(transport.closed, isTrue);
      expect(connection.hosting, LibraryHosting.embedded);
      expect(hosting.error, contains('stopped'));
      expect(
        calls,
        anyElement(equals(['systemctl', '--user', 'stop', 'cadenced.service'])),
      );
      // The replacement is a real host: it answers.
      expect(await connection.client.listLibraries(), isEmpty);
      await connection.client.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isLinux,
  );
}
