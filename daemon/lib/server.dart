import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cadence_client/cadence_client.dart';
import 'host.dart';
import 'local_owner.dart';

class UnixMediaServer {
  UnixMediaServer._(this.host, this.server, this.socketPath, this._socketOwner);
  final LocalOwner _socketOwner;
  final MediaHost host;
  final HttpServer server;
  final String socketPath;
  final _active = <Future<void>>{};
  bool _closing = false;
  final _stopping = Completer<void>();
  static Future<UnixMediaServer> bind(MediaHost host, String socketPath) async {
    final parent = Directory(File(socketPath).absolute.parent.path);
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
      LocalOwner.chmod(parent.path, 448);
    }
    if ((parent.statSync().mode & 63) != 0)
      throw StateError('Socket parent must be private (0700): ${parent.path}');
    // All cadenced processes sharing this path must hold the same lock inode.
    // Keep the sidecar after exit: unlinking it would permit split ownership.
    final lockPath = '$socketPath.owner';
    final lockType = FileSystemEntity.typeSync(lockPath, followLinks: false);
    if (lockType != FileSystemEntityType.notFound &&
        lockType != FileSystemEntityType.file) {
      throw StateError('Invalid socket ownership file');
    }
    final socketOwner = LocalOwner.acquire(lockPath);
    HttpServer? server;
    try {
      final type = FileSystemEntity.typeSync(socketPath, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        if (type != FileSystemEntityType.unixDomainSock) {
          throw StateError('Socket path exists and is not a socket');
        }
        try {
          final peer = await Socket.connect(
            InternetAddress(socketPath, type: InternetAddressType.unix),
            0,
            timeout: const Duration(seconds: 1),
          );
          peer.destroy();
          throw StateError('Socket already has a listener');
        } on SocketException catch (error) {
          // Linux ECONNREFUSED is the only result permitting stale cleanup.
          // Timeouts, permission errors and other failures are not proof of staleness.
          if (error.osError?.errorCode != 111) rethrow;
          if (FileSystemEntity.typeSync(socketPath, followLinks: false) !=
              FileSystemEntityType.unixDomainSock) {
            throw StateError('Socket path changed while checking it');
          }
          File(socketPath).deleteSync();
        }
      }
      server = await HttpServer.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      LocalOwner.chmod(socketPath, 384);
      server.idleTimeout = const Duration(seconds: 15);
      final owner = UnixMediaServer._(host, server, socketPath, socketOwner);
      server.listen((request) {
        late final Future<void> future;
        future = owner
            ._handle(request)
            .whenComplete(() => owner._active.remove(future));
        owner._active.add(future);
      });
      return owner;
    } catch (_) {
      await server?.close(force: true);
      socketOwner.close();
      rethrow;
    }
  }

  Future<void> _handle(HttpRequest request) async {
    Object? id;
    try {
      if (_closing) throw MediaError('closing', 'Server shutting down', 503);
      if (request.method == 'GET' && request.uri.path == '/v1/events') {
        request.response.bufferOutput = false;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write(
          'data: ${jsonEncode({'type': 'snapshot-required', 'epoch': host.epoch})}\n\n',
        );
        await request.response.flush();
        final disconnected = Completer<void>();
        Future<void> writes = Future.value();
        void send(Map<String, Object?> event) {
          writes = writes.then((_) async {
            if (_closing || disconnected.isCompleted) return;
            try {
              request.response.write('data: ${jsonEncode(event)}\n\n');
              await request.response.flush().timeout(
                const Duration(seconds: 5),
              );
            } catch (_) {
              if (!disconnected.isCompleted) disconnected.complete();
            }
          });
        }

        final events = host.events.listen(send);
        final heartbeat = Timer.periodic(
          const Duration(seconds: 1),
          (_) => send({'type': 'heartbeat'}),
        );
        await Future.any([disconnected.future, _stopping.future]);
        heartbeat.cancel();
        await events.cancel();
        await writes;
      } else if (request.method == 'GET' &&
          RegExp(r'^/v1/artwork/[1-9][0-9]*$').hasMatch(request.uri.path)) {
        final bytes = await host.artwork(
          int.parse(request.uri.pathSegments.last),
        );
        if (bytes == null) {
          request.response.statusCode = 404;
        } else {
          request.response.headers.contentType = ContentType.binary;
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
        }
      } else if (request.method == 'POST' && request.uri.path == '/v1/rpc') {
        final bytes = <int>[];
        var oversized = false;
        await request
            .forEach((chunk) {
              if (bytes.length + chunk.length > 1024 * 1024) oversized = true;
              if (!oversized) bytes.addAll(chunk);
            })
            .timeout(const Duration(seconds: 10));
        if (oversized)
          throw MediaError('too_large', 'Request limit is 1 MiB', 413);
        final value = jsonDecode(utf8.decode(bytes));
        if (value is! Map<String, dynamic>)
          throw const FormatException('Expected object');
        id = value['id'];
        if (id is! int || value['version'] != 1)
          throw MediaError(
            'protocol_version',
            'Integer id and version 1 required',
            400,
          );
        if (!['get', 'post', 'put', 'delete'].contains(value['method']) ||
            value['path'] is! String ||
            !(value['path'] as String).startsWith('/') ||
            (value['body'] != null && value['body'] is! Map<String, dynamic>)) {
          throw const FormatException('Invalid method, path or body');
        }
        final result = await host.request(
          value['method'] as String,
          value['path'] as String,
          (value['body'] as Map?)?.cast<String, Object?>(),
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({'version': 1, 'id': id, 'status': 200, 'body': result}),
        );
      } else {
        throw MediaError('not_found', 'Unknown API route', 404);
      }
    } catch (e) {
      try {
        final error = e is MediaError
            ? e
            : MediaError(
                'invalid_request',
                e is FormatException
                    ? e.message
                    : 'Invalid request or unavailable operation',
                400,
              );
        request.response.statusCode = error.status;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'version': 1,
            'id': id,
            'status': error.status,
            'body': {
              'error': {'code': error.code, 'message': error.message},
            },
          }),
        );
      } catch (_) {
        /* Client disconnected; jobs remain owned by host. */
      }
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _stopping.complete();
    await server.close(force: true);
    await Future.wait(_active);
    try {
      await host.close();
    } finally {
      _socketOwner.close();
    }
    // Dart removes its Unix socket when closing the listener.
  }
}
