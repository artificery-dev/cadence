import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:cadence_client/cadence_client.dart';
import 'package:cadence_client/unix.dart';

void main() {
  test(
    'client deadlines, correlation validation and closed connections',
    () async {
      final dir = Directory.systemTemp.createTempSync('cadenced-client-');
      final socket = '${dir.path}/socket';
      final server = await HttpServer.bind(
        InternetAddress(socket, type: InternetAddressType.unix),
        0,
      );
      final pending = <Future<void>>[];
      server.listen((request) {
        pending.add(() async {
          try {
            final value =
                jsonDecode(await utf8.decoder.bind(request).join()) as Map;
            if (value['path'] == '/slow')
              await Future<void>.delayed(const Duration(milliseconds: 100));
            request.response.write(
              jsonEncode({
                'version': 1,
                'id': value['path'] == '/bad' ? -1 : value['id'],
                'status': 200,
                'body': {},
              }),
            );
            await request.response.close();
          } catch (_) {
            /* Closing a timed-out connection is expected. */
          }
        }());
      });
      final normal = CadenceClient(UnixMediaTransport(socket));
      final short = CadenceClient(
        UnixMediaTransport(socket, timeout: const Duration(milliseconds: 20)),
      );
      addTearDown(() async {
        await normal.close();
        await short.close();
        await Future.wait(pending);
        await server.close(force: true);
        dir.deleteSync(recursive: true);
      });
      await expectLater(
        short.call('get', '/slow'),
        throwsA(isA<TimeoutException>()),
      );
      await expectLater(
        normal.call('get', '/bad'),
        throwsA(
          isA<MediaError>().having((e) => e.code, 'code', 'invalid_response'),
        ),
      );
      expect(await normal.call('get', '/ok'), isEmpty);
      await short.close();
      await expectLater(short.call('get', '/ok'), throwsStateError);
    },
  );
}
