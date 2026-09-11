import 'dart:io';

import 'package:cadence/src/data/embedded_library.dart';
import 'package:cadence/src/data/library_connection.dart';
import 'package:cadence_client/cadence_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('cadence_embedded_');
  });
  tearDown(() => temp.delete(recursive: true));

  test(
    'the embedded host answers, owns its database, and lets go',
    () async {
      final database = p.join(temp.path, 'library.sqlite');
      final cache = p.join(temp.path, 'cache');
      final host = await EmbeddedLibrary.spawn(
        databasePath: database,
        cachePath: cache,
      );
      final connection = LibraryConnection(
        host,
        hosting: LibraryHosting.embedded,
      );
      final client = connection.client;
      final id = await client.createLibrary('Music', LibraryType.music);
      expect((await client.listLibraries()).single.name, 'Music');
      expect(await connection.artwork(1), isNull);
      // The host refuses what it does not serve, in its own words.
      await expectLater(
        host.request('post', '/scan'),
        throwsA(isA<MediaError>().having((e) => e.status, 'status', 405)),
      );
      // Events flow: a write is announced.
      final change = connection.events.firstWhere((e) => e['type'] == 'change');
      await client.renameLibrary(id, 'Tunes');
      await change.timeout(const Duration(seconds: 5));

      // One owner at a time: a second host on the same database is refused
      // until the first closes.
      await expectLater(
        EmbeddedLibrary.spawn(databasePath: database, cachePath: cache),
        throwsA(isA<StateError>()),
      );
      await client.close();
      final again = await EmbeddedLibrary.spawn(
        databasePath: database,
        cachePath: cache,
      );
      final rows = (await again.request('get', '/libraries'))['libraries'];
      expect((rows as List).single, containsPair('name', 'Tunes'));
      await again.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isLinux,
  );
}
