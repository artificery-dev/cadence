import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:cadence_client/cadence_client.dart';
import 'package:cadence_client/unix.dart';
import 'package:cadenced/local_owner.dart';

void main() {
  test(
    'standalone readiness, progress, reconnect, queries, ownership and shutdown',
    () async {
      final dir = Directory.systemTemp.createTempSync('cadenced-integration-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final root = Directory('${dir.path}/music')..createSync();
      File(
        '../packages/media/test/fixtures/audio/id3v23.mp3',
      ).copySync('${root.path}/track.mp3');
      final socket = '${dir.path}/run/media.sock';
      final database = '${dir.path}/library.sqlite';
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        'bin/cadenced.dart',
        '--database',
        database,
        '--cache',
        '${dir.path}/cache',
        '--socket',
        socket,
      ]);
      final lines = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream();
      final errors = process.stderr.transform(utf8.decoder).join();
      addTearDown(() async {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      });
      final ready = await lines
          .firstWhere((line) => line.contains('"ready"'))
          .timeout(const Duration(seconds: 90));
      expect(jsonDecode(ready)['apiVersion'], 1);
      expect(FileStat.statSync(socket).mode & 511, 384);
      expect(() => LocalOwner.acquire(database), throwsStateError);
      final client = CadenceClient(UnixMediaTransport(socket));
      final notifications = <Map<String, Object?>>[];
      final observed = Completer<void>();
      final events = client.events.listen((event) {
        notifications.add(event);
        if (!observed.isCompleted) observed.complete();
      });
      await observed.future.timeout(const Duration(seconds: 5));
      final lib = await client.createLibrary('Music', 'music');
      await client.addRoot(lib, root.path);
      final job = await client.scan(lib);
      await client.close();
      await events.cancel();
      final reconnected = CadenceClient(UnixMediaTransport(socket));
      addTearDown(reconnected.close);
      Map<String, Object?> status;
      do {
        status = await reconnected.job(job['jobId'] as String);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      } while (status['finishedAt'] == null);
      expect(status['state'], 'done');
      expect(status['added'], 1);
      expect(await reconnected.items(lib), hasLength(1));
      expect((await reconnected.snapshot())['jobs'], hasLength(1));
      expect(notifications, isNotEmpty);
      await expectLater(
        reconnected.call('post', '/libraries', {'bad': true}),
        throwsA(isA<MediaError>()),
      );
      final peers = List.generate(
        8,
        (_) => CadenceClient(UnixMediaTransport(socket)),
      );
      await Future.wait(peers.map((c) => c.snapshot()));
      await Future.wait(peers.map((c) => c.close()));
      process.kill(ProcessSignal.sigterm);
      expect(
        await process.exitCode.timeout(const Duration(seconds: 15)),
        0,
        reason: await errors,
      );
      final owner = LocalOwner.acquire(database);
      owner.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
