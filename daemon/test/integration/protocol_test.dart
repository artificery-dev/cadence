import 'dart:convert';
import 'dart:io' as io;
import 'package:test/test.dart';
import 'package:drift/native.dart';
import 'package:file/memory.dart';
import 'package:cadence_media/cadence_media.dart';
import 'package:cadenced/host.dart';
import 'package:cadenced/server.dart';
import 'package:cadenced/local_owner.dart';

void main() {
  test('live sockets and symbolic links are never replaced', () async {
    final dir = io.Directory.systemTemp.createTempSync('cadenced-live-socket-');
    final host = await MediaHost.open(
      database: MediaDatabase(NativeDatabase.memory()),
      fileSystem: MemoryFileSystem.test(),
    );
    final path = '${dir.path}/socket';
    final listener = await io.ServerSocket.bind(
      io.InternetAddress(path, type: io.InternetAddressType.unix),
      0,
    );
    final connections = listener.listen((socket) => socket.destroy());
    addTearDown(() async {
      await connections.cancel();
      await listener.close();
      await host.close();
      dir.deleteSync(recursive: true);
    });
    await expectLater(UnixMediaServer.bind(host, path), throwsStateError);
    expect(
      io.FileSystemEntity.typeSync(path),
      io.FileSystemEntityType.unixDomainSock,
    );
    final sentinel = io.File('${dir.path}/keep')..writeAsStringSync('keep');
    final link = io.Link('${dir.path}/link')..createSync(sentinel.path);
    await expectLater(UnixMediaServer.bind(host, link.path), throwsStateError);
    expect(link.existsSync(), isTrue);
    io.Link('${dir.path}/other.owner').createSync(sentinel.path);
    await expectLater(
      UnixMediaServer.bind(host, '${dir.path}/other'),
      throwsStateError,
    );
    expect(sentinel.readAsStringSync(), 'keep');
  });
  test(
    'socket path safety, malformed frames, versions and binary-only artwork',
    () async {
      final dir = io.Directory.systemTemp.createTempSync('cadenced-protocol-');
      final fs = MemoryFileSystem.test();
      final host = await MediaHost.open(
        database: MediaDatabase(NativeDatabase.memory()),
        fileSystem: fs,
      );
      final socket = '${dir.path}/socket';
      final sentinel = io.File(socket)..writeAsStringSync('keep');
      await expectLater(UnixMediaServer.bind(host, socket), throwsStateError);
      expect(sentinel.readAsStringSync(), 'keep');
      sentinel.deleteSync();
      LocalOwner.chmod(dir.path, 493);
      await expectLater(UnixMediaServer.bind(host, socket), throwsStateError);
      LocalOwner.chmod(dir.path, 448);
      final server = await UnixMediaServer.bind(host, socket);
      addTearDown(() async {
        await server.close();
        dir.deleteSync(recursive: true);
      });
      final http = io.HttpClient();
      http.connectionFactory = (_, _, _) => io.Socket.startConnect(
        io.InternetAddress(socket, type: io.InternetAddressType.unix),
        0,
      );
      addTearDown(() => http.close(force: true));
      Future<Map> send(Object value, {bool raw = false}) async {
        final request = await http.postUrl(
          Uri.parse('http://localhost/v1/rpc'),
        );
        request.write(raw ? value : jsonEncode(value));
        final response = await request.close();
        return jsonDecode(await response.transform(utf8.decoder).join()) as Map;
      }

      for (final body in ['{broken', '[]', 'null']) {
        final reply = await send(body, raw: true);
        expect(reply['status'], 400);
        expect((reply['body'] as Map)['error'], isA<Map>());
      }
      expect(
        (await send({
          'version': 2,
          'id': 1,
          'method': 'get',
          'path': '/snapshot',
        }))['status'],
        400,
      );
      expect(
        (await send({
          'version': 1,
          'id': 2,
          'method': 'get',
          'path': '/files/1/artwork',
        }))['status'],
        400,
      );
      expect(
        (await send({
          'version': 1,
          'id': 3,
          'method': 'get',
          'path': '/unknown',
        }))['status'],
        404,
      );
      expect(
        (await send({
          'version': 1,
          'id': 4,
          'method': 'get',
          'path': '/capabilities',
        }))['status'],
        200,
      );
      expect((await send('x' * (1024 * 1024 + 1), raw: true))['status'], 413);
      expect(
        (await send({
          'version': 1,
          'id': 5,
          'method': 'get',
          'path': '/snapshot',
        }))['id'],
        5,
      );
    },
  );
  test(
    'extractors accept explicit filesystems outside an ambient scope',
    () async {
      final fs = MemoryFileSystem.test();
      final extractor = defaultMediaExtractor(fileSystem: fs);
      fs.file('/note.txt').writeAsStringSync('hello world');
      final result = await extractor.extract('/note.txt', MediaKind.document);
      expect(result.metadata.toJson()['title'], 'note');
    },
  );
}
