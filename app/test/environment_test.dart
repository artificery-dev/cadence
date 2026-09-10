import 'dart:io';

import 'package:cadence/src/data/environment.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('no flag means an installed copy', () {
    final env = AppEnvironment.fromArgs(const ['--verbose']);
    expect(env.portable, isFalse);
    expect(env.portableHome, isNull);
    expect(env.defaultPickerDirectory, isNull);
  });

  test('installed, the library lives where the user service keeps it', () {
    final env = AppEnvironment.fromArgs(
      const [],
      platform: const {'HOME': '/home/deck', 'XDG_CACHE_HOME': '/tmp/cache'},
    );
    expect(env.databasePath, '/home/deck/.local/state/cadence/library.sqlite');
    expect(env.cacheDir.path, '/tmp/cache/cadence');
    expect(env.configDir.path, '/home/deck/.config/cadence');
    expect(env.preferencesFile.path, '/home/deck/.config/cadence/app.json');
  }, skip: !Platform.isLinux);

  test('both flag spellings land on the same absolute root', () {
    final joined = AppEnvironment.fromArgs(const ['--portable-dir=/tmp/deck']);
    final spaced = AppEnvironment.fromArgs(const [
      '--portable-dir',
      '/tmp/deck',
    ]);
    expect(joined.portableRoot!.path, '/tmp/deck');
    expect(spaced.portableRoot!.path, '/tmp/deck');
    expect(joined.databasePath, '/tmp/deck/.cadence/library.sqlite');
    expect(joined.cacheDir.path, '/tmp/deck/.cadence/cache');
    expect(joined.configDir.path, '/tmp/deck/.cadence/config');
    expect(joined.defaultPickerDirectory!.path, '/tmp/deck');
  });

  test('a relative path is made absolute', () {
    final env = AppEnvironment.fromArgs(const ['--portable-dir=storage']);
    expect(p.isAbsolute(env.portableRoot!.path), isTrue);
  });

  test('prepare stands up the .cadence skeleton', () async {
    final root = await Directory.systemTemp.createTemp('cadence_portable');
    addTearDown(() => root.delete(recursive: true));
    final env = AppEnvironment.fromArgs(['--portable-dir=${root.path}']);
    await env.prepare();
    expect(env.stateDir.existsSync(), isTrue);
    expect(env.cacheDir.existsSync(), isTrue);
    expect(env.configDir.existsSync(), isTrue);
  });
}
