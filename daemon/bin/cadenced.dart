import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cadence_media/cadence_media.dart'
    hide File, Directory, FileSystemEntity;
import 'package:cadenced/local_store.dart';
import 'package:cadenced/server.dart';
import 'package:cadenced/watch.dart';
import 'package:cadenced/probe.dart';
import 'package:cadenced/priority.dart';
import 'package:cadenced/volume.dart';
import 'package:cadenced/linux_volume.dart';
import 'package:cadenced/endpoint.dart';
import 'package:cadenced/declared_store.dart';
import 'package:path/path.dart' as p;
import 'package:cadenced/relocate_command.dart';

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
  if (args.firstOrNull == 'relocate')
    return runRelocationCommand(args.skip(1).toList());
  final options = <String, String>{};
  for (var i = 0; i < args.length; i += 2) {
    if (i + 1 >= args.length ||
        ![
          '--database',
          '--cache',
          '--socket',
          '--policy',
          '--native',
          '--volume',
          '--store',
          '--store-kind',
          '--media-root',
          '--media-mount',
          '--initialize',
          '--availability',
        ].contains(args[i])) {
      stderr.writeln(
        'Usage: cadenced --socket PATH (--store PATH/.cadence --store-kind directory|mount --media-root ROOT [--media-mount MOUNT] | --volume MOUNT | --database PATH --cache DIR) [--initialize true|false] [--policy lean|full] [--native true|false] [--availability filesystem|host]',
      );
      exitCode = 64;
      return;
    }
    options[args[i]] = args[i + 1];
  }
  final portable = options.containsKey('--volume');
  final declared = options.containsKey('--store');
  final rooted = portable || declared;
  if (!options.containsKey('--socket') ||
      (portable && declared) ||
      (rooted
          ? options.containsKey('--database') || options.containsKey('--cache')
          : !['--database', '--cache'].every(options.containsKey)) ||
      (!rooted && options.containsKey('--initialize')) ||
      !['true', 'false'].contains(options['--initialize'] ?? 'false') ||
      ![
        'filesystem',
        'host',
      ].contains(options['--availability'] ?? 'filesystem') ||
      (portable && options['--availability'] == 'host') ||
      (declared &&
          options.containsKey('--availability') &&
          options['--availability'] != 'host') ||
      (declared && !['directory', 'mount'].contains(options['--store-kind'])) ||
      (!declared &&
          [
            '--store-kind',
            '--media-root',
            '--media-mount',
          ].any(options.containsKey)) ||
      !['lean', 'full'].contains(options['--policy'] ?? 'lean') ||
      !['true', 'false'].contains(options['--native'] ?? 'false')) {
    stderr.writeln(
      'Choose --store with --store-kind and --media-root, --volume MOUNT, or --database PATH --cache DIR; --socket is required. Declared stores require host availability.',
    );
    exitCode = 64;
    return;
  }
  MediaEndpoint? host;
  UnixMediaServer? server;
  final signals = <StreamSubscription<ProcessSignal>>[];
  try {
    if (!Platform.isLinux)
      throw UnsupportedError('Standalone hosting currently supports Linux');

    lowerThreadPriority();
    final probe = options['--native'] == 'true'
        ? ProbeExtractor.tryLoad()
        : null;
    if (options['--native'] == 'true' && probe == null)
      throw StateError('Requested native probe could not load');
    final hostAvailability = declared || options['--availability'] == 'host';
    final storePath = options['--store'];
    final declaration = options['--media-root'];
    final mediaMount = options['--media-mount'];
    if (declared) {
      if (!p.isAbsolute(storePath!) ||
          p.normalize(storePath) != storePath ||
          p.basename(storePath) != '.cadence')
        throw ArgumentError('--store must be an absolute .cadence directory');
      if (declaration != null &&
          declaration != '.' &&
          (!p.isAbsolute(declaration) ||
              p.normalize(declaration) != declaration))
        throw ArgumentError(
          '--media-root must be . or a canonical absolute directory',
        );
    }
    final managed = ManagedLibraryHost(
      attach: ({required initialize}) async => portable
          ? LinuxVolumeAttachment.acquire(
              options['--volume']!,
              initialize: initialize,
            )
          : declared
          ? DeclaredMediaStore(
              metadata: options['--store-kind'] == 'mount'
                  ? LinuxVolumeAttachment.acquire(
                      p.dirname(storePath!),
                      initialize: initialize,
                    )
                  : LinuxVolumeAttachment.acquireDirectory(
                      p.dirname(storePath!),
                      initialize: initialize,
                    ),
              declaredMediaRoot: declaration,
              metadataRoot: p.dirname(storePath),
              mediaMount: mediaMount,
              acquireMediaRoot: (root, mount, mountId) => mount == null
                  ? LinuxRootLease.acquireDirectory(root)
                  : LinuxRootLease.acquire(mount, mountId!),
              playerPath: (path) =>
                  path.replaceFirst('/proc/self/', '/proc/$pid/'),
            )
          : LinuxLocalStore.acquire(
              options['--database']!,
              options['--cache']!,
              hostAvailability: hostAvailability,
            ),
      initialize: options['--initialize'] == 'true',
      hostRootAvailability: hostAvailability,
      reconcileOnAttach: rooted || hostAvailability,
      nativeAvailable: probe != null,
      policy: options['--policy'] == 'full'
          ? ScanPolicy.full
          : const ScanPolicy(artwork: ArtworkPolicy.deferred),
      buildExtractor: () =>
          MediaExtractor([...defaultMediaExtractor().tiers, ?probe]),
      hashFile: probe?.sampledSha256 ?? sampledSha256OfFile,
      watch: rooted || hostAvailability
          ? null
          : (coordinator) => LocalLibraryWatchService(
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
    host = managed;
    try {
      await managed.open();
    } catch (e) {
      if (!rooted) rethrow;
      log('volume-unavailable', {'message': '$e'});
    }
    server = await UnixMediaServer.bind(host, options['--socket']!);
    final stopped = Completer<void>();
    for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
      signals.add(
        signal.watch().listen((_) {
          if (!stopped.isCompleted) stopped.complete();
        }),
      );
    }
    log('ready', {
      'apiVersion': 1,
      'socket': options['--socket'],
      'native': probe != null,
      'volume': managed.status,
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
  }
}
