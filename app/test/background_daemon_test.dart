import 'dart:io';

import 'package:cadence/src/data/app_preferences.dart';
import 'package:cadence/src/data/background_daemon.dart';
import 'package:cadence/src/data/environment.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('cadence_daemon_');
  });
  tearDown(() => temp.delete(recursive: true));

  Future<DaemonBundle> fakeBundle({
    bool probe = true,
    String name = 'bundle',
  }) async {
    final root = Directory(p.join(temp.path, name));
    await Directory(p.join(root.path, 'bin')).create(recursive: true);
    await Directory(p.join(root.path, 'lib')).create(recursive: true);
    await File(
      p.join(root.path, 'bin', 'cadenced'),
    ).writeAsString('#!/bin/sh\n');
    await File(p.join(root.path, 'lib', 'libsqlite3.so')).writeAsString('');
    if (probe) {
      await File(
        p.join(root.path, 'lib', 'libcadence_probe.so'),
      ).writeAsString('');
    }
    return DaemonBundle(root);
  }

  test('the bundle is found beside the executable or under build/', () async {
    final bundle = await fakeBundle();
    expect(
      DaemonBundle.locate(
        environment: const {},
        executableDirectory: temp.path,
        currentDirectory: '/nowhere',
        packageRoot: '/nowhere/usr/lib/cadenced',
      ),
      isNull,
    );
    // The package's copy, when present, beats the app's own.
    final packaged = await fakeBundle(name: 'usr-lib-cadenced');
    final found = DaemonBundle.locate(
      environment: const {},
      executableDirectory: temp.path,
      currentDirectory: '/nowhere',
      packageRoot: packaged.directory.path,
    );
    expect(found?.installed, isTrue);
    expect(found?.directory.path, packaged.directory.path);
    expect(
      DaemonBundle.locate(
        environment: {'CADENCE_DAEMON_BUNDLE': bundle.directory.path},
        executableDirectory: '/nowhere',
        currentDirectory: '/nowhere',
      )?.directory.path,
      bundle.directory.path,
    );
    final exe = Directory(p.join(temp.path, 'app'));
    await Directory(p.join(exe.path, 'daemon', 'bin')).create(recursive: true);
    await Directory(p.join(exe.path, 'daemon', 'lib')).create(recursive: true);
    await File(p.join(exe.path, 'daemon', 'bin', 'cadenced')).writeAsString('');
    await File(
      p.join(exe.path, 'daemon', 'lib', 'libsqlite3.so'),
    ).writeAsString('');
    expect(
      DaemonBundle.locate(
        environment: const {},
        executableDirectory: exe.path,
        currentDirectory: '/nowhere',
      )?.directory.path,
      p.join(exe.path, 'daemon'),
    );
    expect(bundle.hasProbe, isTrue);
    expect((await fakeBundle(probe: false, name: 'bare')).hasProbe, isFalse);
  });

  test('the unit names the library outright and quotes for systemd', () {
    final text = BackgroundDaemon.unitText(
      executable: '/home/x/.local/share/cadenced/bin/cadenced',
      databasePath: r'/home/x/.local/state/cadence/library.sqlite',
      cachePath: r'/home/x/cache 100%/$odd',
      native: true,
    );
    expect(
      text,
      contains(
        'ExecStart="/home/x/.local/share/cadenced/bin/cadenced" '
        '--database "/home/x/.local/state/cadence/library.sqlite" '
        r'--cache "/home/x/cache 100%%/$$odd" '
        '--socket "%t/cadence/media.sock" --policy lean --native true',
      ),
    );
    expect(text, contains('RuntimeDirectory=cadence'));
    expect(text, contains('WantedBy=default.target'));
    expect(
      BackgroundDaemon.unitText(
        executable: '/x',
        databasePath: '/d',
        cachePath: '/c',
        native: false,
      ),
      isNot(contains('--native')),
    );
  });

  test('install copies the bundle, writes the unit, reloads', () async {
    final bundle = await fakeBundle();
    final calls = <List<String>>[];
    final home = Directory(p.join(temp.path, 'home'));
    final environment = AppEnvironment.fromArgs([
      '--portable-dir=${p.join(temp.path, 'deck')}',
    ]);
    final daemon = BackgroundDaemon(
      environment: environment,
      bundle: bundle,
      platform: {
        'HOME': home.path,
        'XDG_RUNTIME_DIR': p.join(temp.path, 'run'),
      },
      linux: true,
      run: (executable, arguments) async {
        calls.add([executable, ...arguments]);
        return ProcessResult(0, 0, '', '');
      },
    );
    expect(daemon.available, isTrue);
    expect(
      daemon.socketPath,
      p.join(temp.path, 'run', 'cadence', 'media.sock'),
    );
    await daemon.install();
    final installed = p.join(home.path, '.local', 'share', 'cadenced');
    expect(File(p.join(installed, 'bin', 'cadenced')).existsSync(), isTrue);
    expect(
      File(p.join(installed, 'lib', 'libcadence_probe.so')).existsSync(),
      isTrue,
    );
    final unit = File(
      p.join(home.path, '.config', 'systemd', 'user', 'cadenced.service'),
    );
    expect(unit.existsSync(), isTrue);
    expect(
      await unit.readAsString(),
      contains('--database "${environment.databasePath}"'),
    );
    expect(calls, [
      ['chmod', '755', p.join(installed, 'bin', 'cadenced')],
      ['systemctl', '--user', 'daemon-reload'],
    ]);
  });

  test('the package copy is run in place: only the unit is written', () async {
    final packaged = await fakeBundle(name: 'pkg');
    final installed = DaemonBundle(packaged.directory, installed: true);
    final calls = <List<String>>[];
    final home = Directory(p.join(temp.path, 'home'));
    final daemon = BackgroundDaemon(
      environment: AppEnvironment.fromArgs(const []),
      bundle: installed,
      platform: {
        'HOME': home.path,
        'XDG_RUNTIME_DIR': p.join(temp.path, 'run'),
      },
      linux: true,
      run: (executable, arguments) async {
        calls.add([executable, ...arguments]);
        return ProcessResult(0, 0, '', '');
      },
    );
    await daemon.install();
    expect(daemon.installDirectory.existsSync(), isFalse);
    expect(
      await daemon.unitFile.readAsString(),
      contains('ExecStart="${installed.executable}"'),
    );
    expect(calls, [
      ['systemctl', '--user', 'daemon-reload'],
    ]);
  });

  test('unavailable off Linux, without a session, or without a bundle', () {
    final environment = AppEnvironment.fromArgs(const []);
    expect(
      BackgroundDaemon(
        environment: environment,
        bundle: DaemonBundle(Directory('/b')),
        platform: const {'XDG_RUNTIME_DIR': '/run/user/1'},
        linux: false,
      ).unavailableReason,
      contains('Linux'),
    );
    expect(
      BackgroundDaemon(
        environment: environment,
        bundle: DaemonBundle(Directory('/b')),
        platform: const {},
        linux: true,
      ).unavailableReason,
      contains('runtime directory'),
    );
    expect(
      BackgroundDaemon(
        environment: environment,
        locateBundle: false,
        platform: const {'XDG_RUNTIME_DIR': '/run/user/1'},
        linux: true,
      ).unavailableReason,
      contains('cadenced'),
    );
  });

  test('preferences round-trip through their file', () async {
    final file = File(p.join(temp.path, 'cfg', 'app.json'));
    final fresh = await AppPreferences.load(file);
    expect(fresh.background, isFalse);
    await fresh.setBackground(true);
    expect((await AppPreferences.load(file)).background, isTrue);
    await file.writeAsString('not json');
    expect((await AppPreferences.load(file)).background, isFalse);
  });
}
