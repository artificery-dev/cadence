import 'dart:async';
import 'dart:convert';
import 'dart:io' hide File, Directory;
import 'context.dart';
import 'package:cadence_client/cadence_client.dart';
import 'package:cadence_client/unix.dart';

/// Linux demonstration; processes and Unix sockets are platform capabilities.
Future<void> runDemo(ToolContext context, String? executable) async {
  final fs = context.fileSystem;
  final p = context.path;
  final temp = fs.systemTempDirectory.createTempSync('cadenced-demo-');
  Process? process;
  CadenceClient? client;
  StreamSubscription<Map<String, Object?>>? subscription;
  try {
    final music = fs.directory(p.join(temp.path, 'music'))..createSync();
    fs
        .file(context.at('packages/media/test/fixtures/audio/id3v23.mp3'))
        .copySync(p.join(music.path, 'fixture.mp3'));
    final socket = p.join(temp.path, 'run', 'media.sock');
    process = await Process.start(executable ?? context.dartExecutable, [
      if (executable == null) ...['run', 'bin/cadenced.dart'],
      '--database',
      p.join(temp.path, 'library.sqlite'),
      '--cache',
      p.join(temp.path, 'cache'),
      '--socket',
      socket,
    ], workingDirectory: context.at('daemon'));
    final ready = Completer<void>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          stdout.writeln(line);
          if (line.contains('"event":"ready"') && !ready.isCompleted)
            ready.complete();
        });
    process.stderr.transform(utf8.decoder).listen(stderr.write);
    await ready.future.timeout(const Duration(seconds: 60));
    client = CadenceClient(UnixMediaTransport(socket));
    final observed = Completer<void>();
    final added = Completer<void>();
    final enriched = Completer<void>();
    subscription = client.events.listen((event) {
      stdout.writeln(jsonEncode({'notification': event}));
      if (event['type'] == 'media-item-added' && !added.isCompleted)
        added.complete();
      if (event['type'] == 'media-item-field-update' && !enriched.isCompleted)
        enriched.complete();
      if (!observed.isCompleted) observed.complete();
    });
    await observed.future;
    final lib = await client.createLibrary('Fixture Music', 'music');
    await client.addRoot(lib, music.path);
    final job = await client.scan(lib);
    stdout.writeln(jsonEncode({'accepted': job}));
    Map<String, Object?> status;
    do {
      status = await client.job(job['jobId'] as String);
      stdout.writeln(jsonEncode({'progress': status}));
      if (status['finishedAt'] == null)
        await Future<void>.delayed(const Duration(milliseconds: 50));
    } while (status['finishedAt'] == null);
    if (status['state'] != 'done' || status['errorCount'] != 0)
      throw StateError('Fixture scan failed: $status');
    await Future.wait([
      added.future,
      enriched.future,
    ]).timeout(const Duration(seconds: 5));
    await subscription.cancel();
    subscription = null;
    await client.close();
    client = CadenceClient(UnixMediaTransport(socket));
    stdout.writeln(jsonEncode({'reconnected': await client.snapshot()}));
    final items = await client.items(lib);
    stdout.writeln(jsonEncode({'items': items}));
    if (items.length != 1) throw StateError('Expected one fixture item');
    await client.close();
    client = null;
    process.kill(ProcessSignal.sigterm);
    final code = await process.exitCode.timeout(const Duration(seconds: 15));
    if (code != 0) throw StateError('Daemon exited $code');
    process = null;
    stdout.writeln(jsonEncode({'demo': 'passed'}));
  } finally {
    await subscription?.cancel();
    await client?.close();
    if (process != null) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
    temp.deleteSync(recursive: true);
  }
}
