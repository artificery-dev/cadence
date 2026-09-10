import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cadence_client/cadence_client.dart';
import 'package:cadenced/declared_store.dart';
import 'package:cadenced/linux_volume.dart';
import 'package:cadenced/volume.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import '../core/volume_test.dart' show settle;

void main() {
  if (Platform.environment['CADENCE_RELOCATION_TEST'] != '1') {
    test(
      'Linux relocation in private mount namespace',
      () async {
        final result = await Process.run(
          'unshare',
          [
            '--user',
            '--map-root-user',
            '--mount',
            Platform.resolvedExecutable,
            'test',
            'test/integration/relocation_linux_test.dart',
            '--reporter',
            'expanded',
          ],
          environment: {
            ...Platform.environment,
            'CADENCE_RELOCATION_TEST': '1',
          },
        );
        stdout.write(result.stdout);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
      skip: !Platform.isLinux,
    );
    return;
  }
  test(
    'CLI move recovers SIGKILL, preserves IDs and media base, and reverses safely',
    () async {
      final temp = Directory.systemTemp.createTempSync('cadence-relocation-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final home = Directory('${temp.path}/home')..createSync();
      final card = Directory('${temp.path}/card')..createSync();
      final mount = Directory('${temp.path}/mount')..createSync();
      Directory('${card.path}/Music').createSync();
      File(
        '../packages/media/test/fixtures/audio/id3v23.mp3',
      ).copySync('${card.path}/Music/song.mp3');
      final mounted = await Process.run('mount', [
        '--bind',
        card.path,
        mount.path,
      ]);
      expect(mounted.exitCode, 0, reason: '${mounted.stderr}');
      addTearDown(() async {
        await Process.run('umount', ['--lazy', mount.path]);
      });
      final mountId = File('/proc/self/mountinfo')
          .readAsLinesSync()
          .map((line) => line.split(' '))
          .firstWhere((parts) => parts[4] == mount.path)[0];
      ManagedLibraryHost openHost(bool portable, {bool initialize = false}) =>
          ManagedLibraryHost(
            initialize: initialize,
            hostRootAvailability: true,
            attach: ({required initialize}) async => DeclaredMediaStore(
              metadata: portable
                  ? LinuxVolumeAttachment.acquire(
                      mount.path,
                      initialize: initialize,
                    )
                  : LinuxVolumeAttachment.acquireDirectory(
                      home.path,
                      initialize: initialize,
                    ),
              metadataRoot: portable ? mount.path : home.path,
              declaredMediaRoot: initialize ? mount.path : null,
              mediaMount: initialize ? mount.path : null,
              acquireMediaRoot: (root, mount, id) => mount == null
                  ? LinuxRootLease.acquireDirectory(root)
                  : LinuxRootLease.acquire(mount, id!),
              playerPath: (path) =>
                  path.replaceFirst('/proc/self/', '/proc/$pid/'),
            ),
          );
      var host = openHost(false, initialize: true);
      await host.open();
      var client = CadenceClient(host);
      final library = await client.call('post', '/libraries', {
        'name': 'Music',
        'type': 'music',
      });
      final libId = library['id'] as int;
      final rootId = await client.addRoot(libId, '/Music');
      Future<void> observe() async {
        final status = await client.volumeStatus();
        await client.setRootAvailability(
          expectedId: status.id!,
          expectedGeneration: status.generation!,
          roots: [
            RootAvailability(
              rootId: rootId,
              available: true,
              mountId: mountId,
              sourceId: 'card-A',
            ),
          ],
        );
      }

      Future<Map<String, Object?>> latest() async {
        final jobs = (await client.snapshot())['jobs'] as List;
        return settle(client, (jobs.last as Map)['jobId'] as String);
      }

      await observe();
      expect((await latest())['discovered'], 1);
      final original = (await client.items(libId)).single as Map;
      final id = (await client.volumeStatus()).id!;
      final executable = Platform.environment['CADENCE_VOLUME_EXECUTABLE'];
      List<String> args({bool reverse = false, String? observedMount}) => [
        if (executable == null) ...['run', 'bin/cadenced.dart'],
        'relocate',
        '--source',
        '${reverse ? mount.path : home.path}/.cadence',
        '--source-kind',
        reverse ? 'mount' : 'directory',
        '--destination',
        '${reverse ? home.path : mount.path}/.cadence',
        '--destination-kind',
        reverse ? 'directory' : 'mount',
        reverse ? '--source-mount-id' : '--destination-mount-id',
        observedMount ?? mountId,
        '--operation-id',
        reverse ? 'back' : 'forward',
        '--expected-id',
        id,
      ];
      Future<ProcessResult> command({
        bool reverse = false,
        String? observedMount,
      }) => Process.run(
        executable ?? Platform.resolvedExecutable,
        args(reverse: reverse, observedMount: observedMount),
      );
      expect(
        (await command()).exitCode,
        75,
        reason: 'Active source owner must reject relocation',
      );
      await host.close();
      expect((await command(observedMount: 'wrong')).exitCode, 75);
      expect(
        Directory('${card.path}/.cadence').existsSync(),
        false,
        reason: 'Wrong mount must be rejected before initialization',
      );
      final bytes = Uint8List(16 * 1024 * 1024);
      final key = sha256.convert(bytes).toString();
      File('${home.path}/.cadence/cache/$key')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes, flush: true);
      final interrupted = await Process.start(
        executable ?? Platform.resolvedExecutable,
        args(),
      );
      final log = StringBuffer();
      interrupted.stderr.transform(utf8.decoder).listen(log.write);
      var killed = false;
      interrupted.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            log.writeln(line);
            if (line.contains('"phase":"copying-database"') && !killed) {
              killed = true;
              interrupted.kill(ProcessSignal.sigkill);
            }
          });
      expect(await interrupted.exitCode, isNot(0));
      expect(killed, true, reason: '$log');
      final blocked = openHost(false);
      await expectLater(
        blocked.open(),
        throwsA(
          isA<MediaError>().having((e) => e.code, 'code', 'relocation_pending'),
        ),
      );
      await blocked.close();
      final moved = await command();
      expect(moved.exitCode, 0, reason: '${moved.stdout}\n${moved.stderr}');
      final complete = (moved.stdout as String)
          .split('\n')
          .where((line) => line.startsWith('{'))
          .map((line) => jsonDecode(line) as Map)
          .last;
      expect(complete['event'], 'relocation-complete');
      expect(complete['datastoreId'], id);
      expect(complete['mediaRoot'], '.');
      expect(
        (await command()).exitCode,
        0,
        reason: 'Acknowledgement-lost retry is idempotent',
      );
      final retired = openHost(false);
      await expectLater(
        retired.open(),
        throwsA(
          isA<MediaError>().having((e) => e.code, 'code', 'datastore_retired'),
        ),
      );
      await retired.close();
      host = openHost(true);
      await host.open();
      client = CadenceClient(host);
      expect((await client.volume())['mediaRoot'], '.');
      expect((await client.volumeStatus()).id, id);
      expect((await client.items(libId)).single, original);
      await observe();
      expect((await latest())['discovered'], 0);
      final status = await client.volumeStatus();
      final resolved = await client.resolveMedia(
        libraryUuid: library['uuid'] as String,
        itemId: original['id'] as int,
        volumeId: status.id!,
        generation: status.generation!,
      );
      expect(
        File(resolved.path).readAsBytesSync(),
        File('${card.path}/Music/song.mp3').readAsBytesSync(),
      );
      await host.close();
      final back = await command(reverse: true);
      expect(back.exitCode, 0, reason: '${back.stdout}\n${back.stderr}');
      host = openHost(false);
      await host.open();
      client = CadenceClient(host);
      expect((await client.volume())['mediaRoot'], mount.path);
      expect((await client.items(libId)).single, original);
      await host.close();
      final unmounted = await Process.run('umount', [mount.path]);
      expect(unmounted.exitCode, 0, reason: '${unmounted.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
