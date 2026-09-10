import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:cadence_client/cadence_client.dart';
import 'package:cadence_media/cadence_media.dart'
    hide File, Directory, FileSystemEntity, FileSystem, Link;
import 'package:cadenced/endpoint.dart';
import 'package:cadenced/host.dart';
import 'package:cadenced/local_store.dart';
import 'package:cadenced/probe.dart';
import 'package:cadenced/volume.dart';
import 'package:cadenced/watch.dart';
import 'package:drift/native.dart';
import 'package:file/local.dart';

/// The library hosted by this very process: `cadenced`'s own host, opened
/// on the same database and cache the user service would use, running in
/// an isolate so the interface never waits on SQLite. Spoken to through
/// [MediaTransport] like any other host, so the app can hand the library
/// over to the daemon — or take it back — by swapping transports.
///
/// The host mirrors `cadenced --database … --cache …`: a lean scan policy,
/// artwork deferred to its queue, the folder watcher wired to the scan
/// queue, and the native probe when its library can be found. Closing
/// releases the database's ownership lock, which is what lets the daemon
/// pick the library up afterwards.
class EmbeddedLibrary implements MediaTransport {
  EmbeddedLibrary._(this._isolate, this._commands, this._events);

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _events;
  late final Stream<Map<String, Object?>> _eventStream = _events
      .map((message) => (message as Map).cast<String, Object?>())
      .asBroadcastStream();
  bool _closed = false;

  /// Opens the library at [databasePath] with its cache at [cachePath].
  /// [probeSearch] names directories to look for the native probe in
  /// before the usual places. Throws [StateError] with the host's own
  /// words when it cannot open — the database owned by a running daemon,
  /// most likely.
  static Future<EmbeddedLibrary> spawn({
    required String databasePath,
    required String cachePath,
    List<String> probeSearch = const [],
  }) async {
    final handshake = ReceivePort();
    final events = ReceivePort();
    final isolate = await Isolate.spawn(
      _serve,
      _Boot(
        handshake: handshake.sendPort,
        events: events.sendPort,
        databasePath: databasePath,
        cachePath: cachePath,
        probeSearch: probeSearch,
      ),
      debugName: 'cadence-library-host',
    );
    final first = await handshake.first;
    handshake.close();
    if (first is SendPort) return EmbeddedLibrary._(isolate, first, events);
    events.close();
    isolate.kill(priority: Isolate.immediate);
    throw StateError('${(first as Map)['error']}');
  }

  Future<Object?> _ask(String verb, [Object? a, Object? b, Object? c]) async {
    if (_closed) throw StateError('Embedded library closed');
    final reply = ReceivePort();
    _commands.send((reply.sendPort, verb, a, b, c));
    final answer = (await reply.first) as Map;
    reply.close();
    if (answer.containsKey('error')) {
      final [code, message, status] = answer['error'] as List;
      throw MediaError(code as String, message as String, status as int);
    }
    return answer['ok'];
  }

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async => ((await _ask('request', method, path, body)) as Map)
      .cast<String, Object?>();

  @override
  Future<List<int>?> artwork(int fileId) async =>
      (await _ask('artwork', fileId)) as List<int>?;

  @override
  Stream<Map<String, Object?>> get events => _eventStream;

  /// Closes the host — every scan paused where it stands, to be resumed
  /// by whoever opens the library next — and lets the isolate go.
  @override
  Future<void> close() async {
    if (_closed) return;
    try {
      await _ask('close').timeout(const Duration(seconds: 90));
    } finally {
      _closed = true;
      _events.close();
      _isolate.kill(priority: Isolate.beforeNextEvent);
    }
  }
}

class _Boot {
  const _Boot({
    required this.handshake,
    required this.events,
    required this.databasePath,
    required this.cachePath,
    required this.probeSearch,
  });

  final SendPort handshake;
  final SendPort events;
  final String databasePath;
  final String cachePath;
  final List<String> probeSearch;
}

/// The isolate's whole life: open the host, forward its events, answer
/// commands until told to close.
Future<void> _serve(_Boot boot) async {
  final MediaEndpoint host;
  try {
    host = await _openHost(boot);
  } on Object catch (error) {
    boot.handshake.send({'error': '$error'});
    return;
  }
  final forwarding = host.events.listen(boot.events.send);
  final commands = ReceivePort();
  boot.handshake.send(commands.sendPort);
  await for (final message in commands) {
    final (SendPort reply, String verb, Object? a, Object? b, Object? c) =
        message as (SendPort, String, Object?, Object?, Object?);
    if (verb == 'close') {
      await forwarding.cancel();
      try {
        await host.close();
        reply.send(const {'ok': null});
      } on Object catch (error) {
        reply.send({
          'error': ['close_failed', '$error', 500],
        });
      }
      commands.close();
      return;
    }
    unawaited(() async {
      try {
        reply.send({
          'ok': switch (verb) {
            'request' => await host.request(
              a as String,
              b as String,
              (c as Map?)?.cast<String, Object?>(),
            ),
            'artwork' => await host.artwork(a as int),
            _ => throw MediaError('invalid_request', 'Unknown verb', 400),
          },
        });
      } on MediaError catch (error) {
        reply.send({
          'error': [error.code, error.message, error.status],
        });
      } on Object catch (error) {
        reply.send({
          'error': ['internal_error', '$error', 500],
        });
      }
    }());
  }
}

/// The daemon's local-store host, as `cadenced.dart` builds it for
/// `--database`/`--cache`; on the desktops without its Linux store, a
/// plain host over the same database — no ownership lock, no handover.
Future<MediaEndpoint> _openHost(_Boot boot) async {
  final probe = ProbeExtractor.tryLoad(searchFirst: boot.probeSearch);
  MediaExtractor buildExtractor() =>
      MediaExtractor([...defaultMediaExtractor().tiers, ?probe]);
  const policy = ScanPolicy(artwork: ArtworkPolicy.deferred);
  if (!Platform.isLinux) {
    final database = MediaDatabase(NativeDatabase(File(boot.databasePath)));
    return MediaHost.open(
      database: database,
      fileSystem: const LocalFileSystem(),
      cacheDirectory: boot.cachePath,
      nativeAvailable: probe != null,
      policy: policy,
      buildExtractor: buildExtractor,
    );
  }
  late final ManagedLibraryHost host;
  host = ManagedLibraryHost(
    attach: ({required initialize}) async =>
        LinuxLocalStore.acquire(boot.databasePath, boot.cachePath),
    nativeAvailable: probe != null,
    reconcileOnAttach: false,
    policy: policy,
    buildExtractor: buildExtractor,
    watch: (coordinator) => LocalLibraryWatchService(
      coordinator.db,
      coordinator,
      submit: (id, dirs) async {
        try {
          await host.request('post', '/libraries/$id/scan');
          return true;
        } catch (_) {
          return false;
        }
      },
    ),
  );
  await host.open();
  return host;
}
