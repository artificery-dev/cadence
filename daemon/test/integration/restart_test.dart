import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:cadence_client/cadence_client.dart';
import 'package:cadence_client/unix.dart';

Future<Process> start(String path) async {
  final process = await Process.start(Platform.resolvedExecutable, [
    'run',
    'bin/cadenced.dart',
    '--database',
    '$path/library.sqlite',
    '--cache',
    '$path/cache',
    '--socket',
    '$path/run/socket',
  ]);
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
      client = CadenceClient(UnixMediaTransport('${dir.path}/run/socket'));
      final lib = await client.createLibrary('Music', 'music');
      await client.addRoot(lib, music.path);
      final nextLib = await client.createLibrary('Next', 'music');
      await client.addRoot(nextLib, music.path);
      final job = await client.scan(lib);
      final nextJob = await client.scan(nextLib);
      expect((await client.job(nextJob['jobId'] as String))['state'], 'queued');
      expect(job['finishedAt'], isNull);
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      process = null;
      await client.close();
      process = await start(dir.path);
      client = CadenceClient(UnixMediaTransport('${dir.path}/run/socket'));
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
      expect((recovered['attempts'] as List).first['state'], 'interrupted');
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
