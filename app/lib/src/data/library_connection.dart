import 'dart:async';

import 'package:cadence_client/cadence_client.dart';
import 'package:cadence_media/cadence_media.dart'
    hide File, Directory, FileSystemEntity, FileSystem, Link;
import 'package:flutter/foundation.dart';

/// Who is hosting the library the app is talking to.
enum LibraryHosting {
  /// A host of our own, in an isolate of this process — gone when the
  /// app is.
  embedded('Running inside Cadence'),

  /// The user's `cadenced`, reached over its socket; it outlives the app.
  daemon('Running in the background'),

  /// A service handed in already wired — the test harness, nothing to
  /// swap.
  direct('Direct');

  const LibraryHosting(this.label);

  final String label;
}

/// The app's one line to the library, whoever hosts it: a typed
/// [MediaClient] over a [MediaTransport] that can be exchanged while the
/// app runs — the built-in host handing over to the background daemon and
/// back — without anyone holding the client noticing more than a pause.
///
/// Every request goes through [_send], which waits out an exchange in
/// progress; the transport's event stream is re-listened after each swap
/// and surfaces as [events] throughout.
class LibraryConnection extends ChangeNotifier {
  LibraryConnection(MediaTransport transport, {required LibraryHosting hosting})
    // ignore: prefer_initializing_formals
    : _transport = transport,
      // ignore: prefer_initializing_formals
      _hosting = hosting {
    client = MediaClient(_send, onClose: _closeTransport);
    _listen();
  }

  /// A client wired some other way — the service in-process, for tests.
  /// Nothing to exchange; artwork rides the client's own route.
  LibraryConnection.fixed(this.client)
    : _transport = null,
      _hosting = LibraryHosting.direct;

  late final MediaClient client;
  MediaTransport? _transport;
  LibraryHosting _hosting;
  Completer<void>? _switching;
  StreamSubscription<Map<String, Object?>>? _subscription;
  final _events = StreamController<Map<String, Object?>>.broadcast();
  final _lost = StreamController<void>.broadcast();
  bool _closed = false;

  LibraryHosting get hosting => _hosting;

  /// True while [exchange] is between transports; requests wait, and
  /// the UI may say so.
  bool get switching => _switching != null;

  /// The host's notifications — `change` after any write, `progress`
  /// while work runs, and the item events a scan emits — from whichever
  /// transport is current. Ends only when the connection closes.
  Stream<Map<String, Object?>> get events => _events.stream;

  /// The line went dead: the host's event stream ended or a request could
  /// not reach it at all — a daemon that stopped, most likely. Fires once
  /// per loss, never during an exchange; whoever owns the hosting decides
  /// what to do about it.
  Stream<void> get lost => _lost.stream;

  void _reportLost() {
    if (_closed || _switching != null || _lost.isClosed) return;
    _lost.add(null);
  }

  Future<Map<String, Object?>> _send(Map<String, Object?> request) async {
    await _switching?.future;
    final transport = _transport;
    if (transport == null || _closed) {
      throw StateError('Library connection closed');
    }
    final id = request['id'] as int;
    try {
      final body = await transport.request(
        request['method'] as String,
        request['path'] as String,
        (request['body'] as Map?)?.cast<String, Object?>(),
      );
      return {'id': id, 'status': 200, 'body': body};
    } on MediaError catch (error) {
      // The service envelope's shape for a refusal; the typed client
      // reads the status and the message the same way it always did.
      return {
        'id': id,
        'status': error.status,
        'body': {'error': error.message, 'code': error.code},
      };
    } on IOException catch (error) {
      // Nobody on the other end: say so in the envelope, and raise the
      // alarm for the hosting to answer.
      if (identical(transport, _transport)) _reportLost();
      return {
        'id': id,
        'status': 503,
        'body': {'error': '$error', 'code': 'unreachable'},
      };
    }
  }

  /// The picture for a file, as bytes — the transport's binary path when
  /// there is one, the base64 route otherwise.
  Future<Uint8List?> artwork(int fileId) async {
    final transport = _transport;
    if (transport == null) return (await client.artwork(fileId))?.bytes;
    await _switching?.future;
    final bytes = await transport.artwork(fileId);
    return switch (bytes) {
      null => null,
      final Uint8List typed => typed,
      _ => Uint8List.fromList(bytes),
    };
  }

  /// Replaces the transport. [swap] receives the current one — already
  /// unsubscribed — and answers the replacement and who hosts it; every
  /// request that arrives meanwhile waits for it. A swap that has torn
  /// the old transport down must answer with a working one rather than
  /// throw: throwing leaves the current transport in place, closed or not.
  Future<void> exchange(
    Future<(MediaTransport, LibraryHosting)> Function(MediaTransport current)
    swap,
  ) async {
    final current = _transport;
    if (current == null) throw StateError('Nothing to exchange');
    if (_switching != null) throw StateError('An exchange is in progress');
    final gate = _switching = Completer<void>();
    notifyListeners();
    await _subscription?.cancel();
    _subscription = null;
    try {
      final (transport, hosting) = await swap(current);
      _transport = transport;
      _hosting = hosting;
    } finally {
      _listen();
      _switching = null;
      gate.complete();
      notifyListeners();
    }
  }

  void _listen() {
    final transport = _transport;
    if (transport == null || _closed) return;
    _subscription = transport.events.listen(
      (event) {
        if (!_events.isClosed) _events.add(event);
      },
      onError: (Object _) {
        if (identical(transport, _transport)) _reportLost();
      },
      onDone: () {
        // A live host never hangs up its own event line; one that did
        // has gone away.
        if (identical(transport, _transport)) _reportLost();
      },
      cancelOnError: true,
    );
  }

  Future<void> _closeTransport() async {
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    await _events.close();
    await _lost.close();
    await _transport?.close();
  }

  @override
  void dispose() {
    if (!_closed) unawaited(client.close());
    super.dispose();
  }
}
