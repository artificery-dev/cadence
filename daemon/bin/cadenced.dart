import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cadence_media/cadence_media.dart'
    hide File, Directory, FileSystemEntity;
import 'package:file/local.dart';
import 'package:drift/native.dart';
import 'package:cadenced/host.dart';
import 'package:cadenced/local_owner.dart';
import 'package:cadenced/server.dart';
import 'package:cadenced/watch.dart';
import 'package:cadenced/probe.dart';
import 'package:cadenced/priority.dart';

void log(String event, [Map<String, Object?> data = const {}]) =>
    stdout.writeln(
      jsonEncode({
        'time': DateTime.now().toUtc().toIso8601String(),
        'event': event,
        ...data,
      }),
    );
void main(List<String> args) {
  runZonedGuarded(() => run(args), (Object error, StackTrace stack) {
    log('fatal', {'message': '$error'});
    exit(1);
  });
}

Future<void> run(List<String> args) async {
  final options = <String, String>{};
  for (var i = 0; i < args.length; i += 2) {
    if (i + 1 >= args.length ||
        ![
          '--database',
          '--cache',
          '--socket',
          '--policy',
          '--native',
        ].contains(args[i])) {
      stderr.writeln(
        'Usage: cadenced --database PATH --cache DIR --socket PATH [--policy lean|full] [--native true|false]',
      );
      exitCode = 64;
      return;
    }
    options[args[i]] = args[i + 1];
  }
  if (!['--database', '--cache', '--socket'].every(options.containsKey) ||
      !['lean', 'full'].contains(options['--policy'] ?? 'lean') ||
      !['true', 'false'].contains(options['--native'] ?? 'false')) {
    stderr.writeln(
      'Required: --database PATH --cache DIR --socket PATH; policy is lean or full',
    );
    exitCode = 64;
    return;
  }
  LocalOwner? lock;
  MediaHost? host;
  UnixMediaServer? server;
  final signals = <StreamSubscription<ProcessSignal>>[];
  try {
    if (!Platform.isLinux)
      throw UnsupportedError('Standalone hosting currently supports Linux');
    lock = LocalOwner.acquire(options['--database']!);
    Directory(options['--cache']!).createSync(recursive: true);
    LocalOwner.chmod(options['--cache']!, 448);
    lowerThreadPriority();
    final probe = options['--native'] == 'true'
        ? ProbeExtractor.tryLoad()
        : null;
    if (options['--native'] == 'true' && probe == null)
      throw StateError('Requested native probe could not load');
    host = await MediaHost.open(
      database: MediaDatabase(NativeDatabase(File(lock.path))),
      fileSystem: const LocalFileSystem(),
      cacheDirectory: options['--cache'],
      nativeAvailable: probe != null,
      autoStartJobs: false,
      policy: options['--policy'] == 'full'
          ? ScanPolicy.full
          : const ScanPolicy(artwork: ArtworkPolicy.deferred),
      buildExtractor: () =>
          MediaExtractor([...defaultMediaExtractor().tiers, ?probe]),
      watch: (coordinator) => LocalLibraryWatchService(
        coordinator.db,
        coordinator,
        submit: (id, dirs) async {
          try {
            await host!.request('post', '/libraries/$id/scan');
            return true;
          } catch (_) {
            return false;
          }
        },
        log: (message) => log('watch', {'message': message}),
      ),
    );
    server = await UnixMediaServer.bind(host, options['--socket']!);
    final stopped = Completer<void>();
    for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
      signals.add(
        signal.watch().listen((_) {
          if (!stopped.isCompleted) stopped.complete();
        }),
      );
    }
    host.resumeJobs();
    log('ready', {
      'apiVersion': 1,
      'socket': options['--socket'],
      'native': probe != null,
    });
    await stopped.future;
    log('stopping');
    await server.close();
    server = null;
    host = null;
    log('stopped');
  } catch (e) {
    log('fatal', {'message': '$e'});
    exitCode = 1;
  } finally {
    for (final subscription in signals) {
      await subscription.cancel();
    }
    if (server != null) {
      await server.close();
    } else {
      await host?.close();
    }
    lock?.close();
  }
}
