import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:cadence_client/cadence_client.dart';
import 'package:cadence_client/unix.dart';

Future<Process> start(String path) async {
  final executable = Platform.environment['CADENCE_VOLUME_EXECUTABLE'];
  final process = await Process.start(
    executable ?? Platform.resolvedExecutable,
    [
      if (executable == null) ...['run', 'bin/cadenced.dart'],
      '--database',
      '$path/library.sqlite',
      '--cache',
      '$path/cache',
      '--socket',
      '$path/run/socket',
    ],
  );
  process.stderr.drain<void>();
  final ready = Completer<void>();
  process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (line) {
      if (line.contains('"ready"') && !ready.isCompleted) ready.complete();
    },
  );
  await ready.future.timeout(const Duration(seconds: 60));
  return process;
}

/// Status requests share the owner isolate with the 2000-file scans this
/// test drives, and loaded CI runners have stalled them past the client's
/// default 30 seconds; the test is about recovery, not latency.
const patience = Duration(seconds: 120);

void main() {
  test(
    'SIGKILL restarts the durable queue and safely replaces its stale socket',
    () async {
      final dir = Directory.systemTemp.createTempSync('cadenced-restart-');
      Process? process;
      CadenceClient? client;
      addTearDown(() async {
        await client?.close();
        if (process != null) {
          process.kill(ProcessSignal.sigkill);
          await process.exitCode;
        }
        dir.deleteSync(recursive: true);
      });
      final music = Directory('${dir.path}/music')..createSync();
      for (var i = 0; i < 2000; i++) {
        File('${music.path}/$i.mp3').writeAsStringSync('fixture');
      }
      process = await start(dir.path);
      client = CadenceClient(
        UnixMediaTransport('${dir.path}/run/socket', timeout: patience),
      );
      final lib = await client.createLibrary('Music', 'music');
      await client.addRoot(lib, music.path);
      final nextLib = await client.createLibrary('Next', 'music');
      await client.addRoot(nextLib, music.path);
      final added = Completer<Map<String, Object?>>();
      final connected = Completer<void>();
      final events = client.events.listen(
        (event) {
          if (!connected.isCompleted) connected.complete();
          if (event['type'] == 'media-item-added' && !added.isCompleted)
            added.complete(event);
        },
        onError: (Object _) {
          /* SIGKILL deliberately severs the stream. */
        },
      );
      await connected.future.timeout(const Duration(seconds: 5));
      final job = await client.scan(lib);
      final nextJob = await client.scan(nextLib);
      expect((await client.job(nextJob['jobId'] as String))['state'], 'queued');
      expect(job['finishedAt'], isNull);
      final firstItem = await added.future.timeout(const Duration(seconds: 30));
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      await events.cancel();
      process = null;
      await client.close();
      process = await start(dir.path);
      client = CadenceClient(
        UnixMediaTransport('${dir.path}/run/socket', timeout: patience),
      );
      Future<Map<String, Object?>> wait(String id) async {
        for (var i = 0; i < 3000; i++) {
          final status = await client!.job(id);
          if (status['finishedAt'] != null) return status;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        throw StateError('Recovery timed out');
      }

      final recovered = await wait(job['jobId'] as String);
      expect(recovered['state'], 'done');
      expect(recovered['attemptCount'], 2);
      expect(recovered['discovered'] as int, lessThan(2000));
      expect((recovered['attempts'] as List).first['state'], 'interrupted');
      final restoredItems = await client.items(lib);
      expect(
        restoredItems.where(
          (item) => (item as Map)['fileId'] == firstItem['fileId'],
        ),
        hasLength(1),
      );
      final next = await wait(nextJob['jobId'] as String);
      expect(next['state'], 'done');
      expect(next['attemptCount'], 1);
      expect((await client.snapshot())['jobs'], hasLength(2));
      expect(
        (await client.call('get', '/libraries/$lib/items', {
          'limit': 5000,
        }))['items'],
        hasLength(2000),
      );
      process.kill(ProcessSignal.sigterm);
      expect(await process.exitCode.timeout(const Duration(seconds: 15)), 0);
      process = null;
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
