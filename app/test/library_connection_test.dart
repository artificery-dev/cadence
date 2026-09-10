import 'dart:async';
import 'dart:io';

import 'package:cadence/src/data/library_connection.dart';
import 'package:cadence_client/cadence_client.dart';
import 'package:cadence_media/cadence_media.dart' show ServiceMethod;
import 'package:flutter_test/flutter_test.dart';

/// A transport that answers from a script: every request echoes its path
/// under the name it was given, artwork is one byte, events are whatever
/// the test pushes.
class _Scripted implements MediaTransport {
  _Scripted(this.name);

  final String name;
  final events$ = StreamController<Map<String, Object?>>.broadcast();
  final requests = <String>[];
  bool closed = false;
  MediaError? refuse;
  bool unreachable = false;

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    requests.add('$method $path');
    if (unreachable) throw const SocketException('nobody home');
    if (refuse case final error?) throw error;
    return {'by': name, 'path': path};
  }

  @override
  Future<List<int>?> artwork(int fileId) async => fileId == 1 ? [7] : null;

  @override
  Stream<Map<String, Object?>> get events => events$.stream;

  @override
  Future<void> close() async => closed = true;
}

void main() {
  lostTests();
  test('requests ride the current transport as service envelopes', () async {
    final a = _Scripted('a');
    final connection = LibraryConnection(a, hosting: LibraryHosting.embedded);
    final response = await connection.client.send(
      ServiceMethod.get,
      '/libraries',
    );
    expect(response.status, 200);
    expect(response.body, {'by': 'a', 'path': '/libraries'});
    expect(a.requests, ['get /libraries']);
    expect(await connection.artwork(1), [7]);
    expect(await connection.artwork(2), isNull);
  });

  test('a refusal becomes a status the typed client reads', () async {
    final a = _Scripted('a')
      ..refuse = MediaError('not_found', 'No such setting', 404);
    final connection = LibraryConnection(a, hosting: LibraryHosting.embedded);
    final response = await connection.client.send(
      ServiceMethod.get,
      '/settings/x',
    );
    expect(response.status, 404);
    expect(response.body['error'], 'No such setting');
    expect(response.body['code'], 'not_found');
  });

  test('an exchange holds requests until the new transport is in', () async {
    final a = _Scripted('a');
    final b = _Scripted('b');
    final connection = LibraryConnection(a, hosting: LibraryHosting.embedded);
    final heard = <String>[];
    connection.events.listen((event) => heard.add('${event['type']}'));
    a.events$.add({'type': 'from-a'});
    await Future<void>.delayed(Duration.zero);

    final gate = Completer<void>();
    final swapping = connection.exchange((current) async {
      expect(current, same(a));
      await gate.future;
      return (b, LibraryHosting.daemon);
    });
    expect(connection.switching, isTrue);
    // Sent mid-exchange: waits, then lands on b.
    final held = connection.client.send(ServiceMethod.get, '/held');
    await Future<void>.delayed(Duration.zero);
    expect(b.requests, isEmpty);
    gate.complete();
    await swapping;
    expect((await held).body['by'], 'b');
    expect(connection.hosting, LibraryHosting.daemon);
    expect(connection.switching, isFalse);

    // Events now come from b, and a's are no longer heard.
    b.events$.add({'type': 'from-b'});
    a.events$.add({'type': 'from-a-again'});
    await Future<void>.delayed(Duration.zero);
    expect(heard, ['from-a', 'from-b']);

    await connection.client.close();
    expect(b.closed, isTrue);
  });
}

void lostTests() {
  test(
    'a hung-up event line and an unreachable host both report lost',
    () async {
      final a = _Scripted('a');
      final connection = LibraryConnection(a, hosting: LibraryHosting.daemon);
      var losses = 0;
      connection.lost.listen((_) => losses++);
      await a.events$.close();
      await Future<void>.delayed(Duration.zero);
      expect(losses, 1);

      final b = _Scripted('b')..unreachable = true;
      final other = LibraryConnection(b, hosting: LibraryHosting.daemon);
      var otherLosses = 0;
      other.lost.listen((_) => otherLosses++);
      final response = await other.client.send(ServiceMethod.get, '/x');
      expect(response.status, 503);
      expect(response.body['code'], 'unreachable');
      await Future<void>.delayed(Duration.zero);
      expect(otherLosses, 1);
    },
  );
}
