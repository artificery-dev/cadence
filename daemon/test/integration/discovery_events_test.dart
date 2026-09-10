import 'dart:async';
import 'dart:io' as io;
import 'package:cadence_client/cadence_client.dart';
import 'package:cadence_client/unix.dart';
import 'package:cadence_media/cadence_media.dart';
import 'package:cadenced/host.dart';
import 'package:cadenced/local_owner.dart';
import 'package:cadenced/server.dart';
import 'package:drift/native.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';
import '../core/discovery_test.dart' show MetadataGate;
import '../core/host_test.dart' show settle;

void main() {
  test(
    'Unix clients receive committed additions and field updates while jobs run',
    () async {
      final directory = io.Directory.systemTemp.createTempSync(
        'cadence-events-',
      );
      // Dart's temp directories follow the umask, and the server refuses a
      // socket parent that is not 0700.
      LocalOwner.chmod(directory.path, 448);
      final fs = MemoryFileSystem.test();
      fs.file('/music/a.mp3')
        ..createSync(recursive: true)
        ..writeAsStringSync('a');
      final gate = MetadataGate();
      final host = await MediaHost.open(
        database: MediaDatabase(NativeDatabase.memory()),
        fileSystem: fs,
        buildExtractor: () => MediaExtractor([gate]),
      );
      final server = await UnixMediaServer.bind(
        host,
        '${directory.path}/socket',
      );
      final client = CadenceClient(UnixMediaTransport(server.socketPath));
      addTearDown(() async {
        if (!gate.release.isCompleted) gate.release.complete();
        await client.close();
        await server.close();
        directory.deleteSync(recursive: true);
      });
      final connected = Completer<void>();
      final added = Completer<Map<String, Object?>>();
      final updated = Completer<Map<String, Object?>>();
      final subscription = client.events.listen((event) {
        if (!connected.isCompleted) connected.complete();
        if (event['type'] == 'media-item-added' && !added.isCompleted)
          added.complete(event);
        if (event['type'] == 'media-item-field-update' && !updated.isCompleted)
          updated.complete(event);
      });
      addTearDown(subscription.cancel);
      await connected.future.timeout(const Duration(seconds: 5));
      final library = await client.createLibrary('Music', 'music');
      await client.addRoot(library, '/music');
      final job = await client.scan(library);
      final notification = await added.future.timeout(
        const Duration(seconds: 5),
      );
      await gate.entered.future.timeout(const Duration(seconds: 5));
      final item = (await client.items(library)).single as Map;
      expect(item['id'], notification['itemId']);
      expect((item['metadata'] as Map)['title'], 'a');
      expect((await client.job(job['jobId'] as String))['finishedAt'], isNull);
      gate.release.complete();
      final fields = await updated.future.timeout(const Duration(seconds: 5));
      expect(fields['fields'], containsPair('title', 'Song'));
      expect(fields['itemId'], item['id']);
      expect((await settle(host, job['jobId'] as String))['state'], 'done');
    },
  );
}
