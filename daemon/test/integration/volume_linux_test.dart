import 'dart:async';
import 'dart:convert';
import 'package:cadence_client/unix.dart';
import 'dart:io';
import 'package:cadence_client/cadence_client.dart';
import 'package:cadenced/linux_volume.dart';
import 'package:cadenced/local_owner.dart';
import 'package:cadenced/volume.dart';
import 'package:test/test.dart';
import '../core/volume_test.dart' show settle;

void main() {
  if (Platform.environment['CADENCE_MOUNT_TEST'] != '1') {
    test(
      'Linux volume mount integration in private user/mount namespace',
      () async {
        final result = await Process.run(
          'unshare',
          [
            '--user',
            '--map-root-user',
            '--mount',
            Platform.resolvedExecutable,
            'test',
            'test/integration/volume_linux_test.dart',
            '--reporter',
            'expanded',
          ],
          environment: {...Platform.environment, 'CADENCE_MOUNT_TEST': '1'},
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
  Future<void> command(String executable, List<String> args) async {
    final result = await Process.run(executable, args);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  test(
    'lazy detach cannot redirect database, journal or cache writes into mountpoint',
    () async {
      final temp = Directory.systemTemp.createTempSync('cadence-mount-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final source = Directory('${temp.path}/card')..createSync();
      final mount = Directory('${temp.path}/mount')..createSync();
      File('${source.path}/song.mp3').writeAsStringSync('song');
      await command('mount', ['--bind', source.path, mount.path]);
      final lease = LinuxVolumeAttachment.acquire(mount.path, initialize: true);
      final host = PortableVolumeHost(
        reconcileOnAttach: false,
        attach: ({required initialize}) async => lease,
        initialize: true,
      );
      await host.open();
      addTearDown(host.close);
      final client = CadenceClient(host);
      final library = await client.createLibrary('Music', 'music');
      await client.addRoot(library, '/');
      final job = await client.scan(library);
      expect((await settle(client, job['jobId'] as String))['state'], 'done');
      expect(await client.items(library), hasLength(1));
      expect(() => LinuxVolumeAttachment.acquire(mount.path), throwsStateError);
      expect(
        () => LocalOwner.acquire('${mount.path}/.cadence/library.sqlite'),
        throwsStateError,
      );
      await command('umount', ['--lazy', mount.path]);
      expect(lease.isAttached, false);
      // Force a new path-based write through the still-held attachment after the
      // original mount vanished. It must reach the old card, never the fallback.
      lease.fileSystem
          .file('/.cadence/after-detach')
          .writeAsStringSync('pinned');
      expect(
        File('${source.path}/.cadence/after-detach').readAsStringSync(),
        'pinned',
      );
      expect(mount.listSync(), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect((await client.volume())['state'], 'unavailable');
      expect(mount.listSync(), isEmpty);
      await host.close();
      await expectLater(
        Future.sync(
          () => LinuxVolumeAttachment.acquire(mount.path, initialize: true),
        ),
        throwsStateError,
      );
      expect(mount.listSync(), isEmpty);
      await command('mount', ['--bind', source.path, mount.path]);
      final reopened = PortableVolumeHost(
        reconcileOnAttach: false,
        attach: ({required initialize}) async =>
            LinuxVolumeAttachment.acquire(mount.path),
      );
      await reopened.open();
      final next = CadenceClient(reopened);
      expect(await next.items(library), hasLength(1));
      final scan = await next.scan(library);
      expect((await settle(next, scan['jobId'] as String))['discovered'], 0);
      expect((await next.ejectVolume())['readyToUnmount'], true);
      await reopened.close();
      await command('umount', [mount.path]);
    },
  );
  test(
    'standalone card API, notifications, reconnect, reattach and shutdown',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'cadence-volume-daemon-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final card = Directory('${temp.path}/card')..createSync();
      final mount = Directory('${temp.path}/mount')..createSync();
      final secondMount = Directory('${temp.path}/second')..createSync();
      File(
        '../packages/media/test/fixtures/audio/id3v23.mp3',
      ).copySync('${card.path}/song.mp3');
      await command('mount', ['--bind', card.path, mount.path]);
      addTearDown(() async {
        await Process.run('umount', ['--lazy', mount.path]);
        await Process.run('umount', ['--lazy', secondMount.path]);
      });
      final socket = '${temp.path}/run/cadence.sock';
      Future<Process> start(String path, {bool initialize = false}) async {
        final binary = Platform.environment['CADENCE_VOLUME_EXECUTABLE'];
        final process = await Process.start(
          binary ?? Platform.resolvedExecutable,
          [
            if (binary == null) ...['run', 'bin/cadenced.dart'],
            '--native',
            'true',
            '--volume',
            path,
            '--socket',
            socket,
            '--initialize',
            '$initialize',
          ],
        );
        addTearDown(() async {
          process.kill(ProcessSignal.sigkill);
          await process.exitCode;
        });
        process.stderr.transform(utf8.decoder).listen(stderr.write);
        final ready = Completer<void>();
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              print(line);
              if (line.contains('"event":"ready"') && !ready.isCompleted)
                ready.complete();
            });
        await ready.future.timeout(const Duration(seconds: 60));
        return process;
      }

      var process = await start(mount.path, initialize: true);
      var client = CadenceClient(UnixMediaTransport(socket));
      final connected = Completer<void>();
      final added = Completer<void>();
      final fields = Completer<void>();
      final subscription = client.events.listen((event) {
        if (!connected.isCompleted) connected.complete();
        if (event['type'] == 'media-item-added' && !added.isCompleted)
          added.complete();
        if (event['type'] == 'media-item-field-update' && !fields.isCompleted)
          fields.complete();
      });
      await connected.future;
      final library = await client.call('post', '/libraries', {
        'name': 'Music',
        'type': 'music',
      });
      final id = library['id'] as int;
      final volumeId = (await client.volume())['id'];
      await client.addRoot(id, '/');
      final job = await client.scan(id);
      final done = await settle(client, job['jobId'] as String);
      expect(done['state'], 'done');
      await Future.wait([
        added.future,
        fields.future,
      ]).timeout(const Duration(seconds: 5));
      final original = await client.items(id);
      final attachmentStatus = await client.volumeStatus();
      final location = await client.resolveMedia(
        libraryUuid: library['uuid'] as String,
        itemId: (original.single as Map)['id'] as int,
        volumeId: attachmentStatus.id!,
        generation: attachmentStatus.generation!,
      );
      expect(
        File(location.path).readAsBytesSync(),
        File('${card.path}/song.mp3').readAsBytesSync(),
      );
      await expectLater(
        client.resolveMedia(
          libraryUuid: library['uuid'] as String,
          itemId: location.itemId,
          volumeId: attachmentStatus.id!,
          generation: 'old',
        ),
        throwsA(
          isA<MediaError>().having((e) => e.code, 'code', 'stale_generation'),
        ),
      );
      await expectLater(
        client.resolveMedia(
          libraryUuid: 'other-library',
          itemId: location.itemId,
          volumeId: attachmentStatus.id!,
          generation: attachmentStatus.generation!,
        ),
        throwsA(isA<MediaError>().having((e) => e.code, 'code', 'not_found')),
      );

      print(
        jsonEncode({
          'volumeId': volumeId,
          'library': library,
          'job': done,
          'items': original,
        }),
      );
      await subscription.cancel();
      await client.close();
      client = CadenceClient(UnixMediaTransport(socket));
      expect(await client.items(id), original);
      expect((await client.ejectVolume())['readyToUnmount'], true);
      await command('umount', [mount.path]);
      await client.close();
      process.kill(ProcessSignal.sigterm);
      expect(await process.exitCode, 0);
      await command('mount', ['--bind', card.path, secondMount.path]);
      process = await start(secondMount.path);
      client = CadenceClient(UnixMediaTransport(socket));
      expect((await client.volume())['id'], volumeId);
      expect(
        (await client.volumeStatus()).generation,
        isNot(attachmentStatus.generation),
      );
      await expectLater(
        client.resolveMedia(
          libraryUuid: library['uuid'] as String,
          itemId: location.itemId,
          volumeId: attachmentStatus.id!,
          generation: attachmentStatus.generation!,
        ),
        throwsA(
          isA<MediaError>().having((e) => e.code, 'code', 'stale_generation'),
        ),
      );

      expect(
        ((await client.call('get', '/libraries'))['libraries'] as List).single,
        containsPair('uuid', library['uuid']),
      );
      expect(await client.items(id), original);
      final snapshot = await client.snapshot();
      final jobs = snapshot['jobs'] as List;
      expect(
        jobs.length,
        greaterThan(1),
        reason: 'Attach schedules reconciliation',
      );
      for (final job in jobs.cast<Map>()) {
        final finished = await settle(client, job['jobId'] as String);
        if (job['jobId'] != done['jobId']) expect(finished['discovered'], 0);
      }
      print(
        jsonEncode({
          'relocated': await client.volume(),
          'reconciliation': await client.snapshot(),
        }),
      );
      // SIGKILL a live portable queue, then recover using its real card VFS.
      for (var i = 0; i < 500; i++) {
        File(
          '${card.path}/extra-$i.mp3',
        ).writeAsBytesSync(List<int>.filled(2048, i % 256));
      }
      final listening = Completer<void>();
      final interrupted = Completer<void>();
      final crashes = client.events.listen((event) {
        if (!listening.isCompleted) listening.complete();
        if (event['type'] == 'scan-phase-changed' &&
            event['phase'] == 'discover' &&
            !interrupted.isCompleted) {
          process.kill(ProcessSignal.sigkill);
          interrupted.complete();
        }
      }, onError: (Object _) {});
      await listening.future;
      final killedJob = await client.scan(id);
      await interrupted.future.timeout(const Duration(seconds: 15));
      expect(await process.exitCode, isNot(0));
      await crashes.cancel();
      await client.close();
      process = await start(secondMount.path);
      client = CadenceClient(UnixMediaTransport(socket));
      final resumed = await settle(client, killedJob['jobId'] as String);
      expect(resumed['state'], 'done');
      expect(resumed['attemptCount'], 2);
      expect(await client.items(id), hasLength(501));
      print(
        jsonEncode({
          'recoveredJob': resumed['jobId'],
          'attemptCount': resumed['attemptCount'],
        }),
      );
      expect((await client.ejectVolume())['readyToUnmount'], true);
      await command('umount', [secondMount.path]);
      await client.close();
      process.kill(ProcessSignal.sigterm);
      expect(await process.exitCode, 0);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'local datastore gates startup and pins removable roots through removal and normal eject',
    () async {
      final temp = Directory.systemTemp.createTempSync('cadence-local-roots-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final card = Directory('${temp.path}/card/Music')
        ..createSync(recursive: true);
      final internal = Directory('${temp.path}/home/Music')
        ..createSync(recursive: true);
      final mount = Directory('${temp.path}/mount')..createSync();
      File(
        '../packages/media/test/fixtures/audio/id3v23.mp3',
      ).copySync('${internal.path}/internal.mp3');
      File(
        '../packages/media/test/fixtures/audio/tagged.flac',
      ).copySync('${card.path}/external.flac');
      await command('mount', ['--bind', card.parent.path, mount.path]);
      addTearDown(() async {
        await Process.run('umount', ['--lazy', mount.path]);
      });
      String mountId() => File('/proc/self/mountinfo')
          .readAsLinesSync()
          .map((l) => l.split(' '))
          .firstWhere((p) => p[4] == mount.path)[0];
      final socket = '${temp.path}/run/cadence.sock';
      final binary = Platform.environment['CADENCE_VOLUME_EXECUTABLE'];
      final process = await Process.start(
        binary ?? Platform.resolvedExecutable,
        [
          if (binary == null) ...['run', 'bin/cadenced.dart'],
          '--database',
          '${temp.path}/xdg/data/library.sqlite',
          '--cache',
          '${temp.path}/xdg/cache',
          '--socket',
          socket,
          '--availability',
          'host',
          '--native',
          'true',
        ],
      );
      addTearDown(() async {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      });
      process.stderr.transform(utf8.decoder).listen(stderr.write);
      final ready = Completer<void>();
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            print(line);
            if (line.contains('"event":"ready"') && !ready.isCompleted)
              ready.complete();
          });
      await ready.future.timeout(const Duration(seconds: 60));
      final client = CadenceClient(UnixMediaTransport(socket));
      addTearDown(client.close);
      expect((await client.volumeStatus()).rootAvailabilityReady, false);
      final created = await client.call('post', '/libraries', {
        'name': 'Music',
        'type': 'music',
      });
      final library = created['id'] as int;
      final internalRoot = await client.addRoot(library, internal.path);
      final externalRoot =
          (await client.call('post', '/libraries/$library/roots', {
                'path': '${mount.path}/Music',
                'mountPath': mount.path,
              }))['id']
              as int;
      final configured = (await client.snapshot())['roots'] as List;
      expect(
        configured.cast<Map>().firstWhere(
          (r) => r['id'] == externalRoot,
        )['mountPath'],
        mount.path,
      );
      Future<VolumeStatus> observe(bool available, {String? id}) async {
        final status = await client.volumeStatus();
        return client.setRootAvailability(
          expectedId: status.id!,
          expectedGeneration: status.generation!,
          roots: [
            RootAvailability(rootId: internalRoot, available: true),
            RootAvailability(
              rootId: externalRoot,
              available: available,
              mountId: available ? id ?? mountId() : null,
              sourceId: available ? 'cid-A' : null,
            ),
          ],
        );
      }

      await expectLater(
        observe(true, id: 'wrong'),
        throwsA(
          isA<MediaError>().having(
            (e) => e.code,
            'code',
            'root_observation_failed',
          ),
        ),
      );
      expect(
        (await client.snapshot())['queue'],
        containsPair('enabled', false),
      );
      final status = await observe(true);
      Future<void> settleJobs() async {
        for (final job
            in ((await client.snapshot())['jobs'] as List).cast<Map>()) {
          await settle(client, job['jobId'] as String);
        }
      }

      await settleJobs();
      final items = (await client.items(library)).cast<Map>();
      expect(items, hasLength(2));
      final external = items.firstWhere(
        (i) => (i['path'] as String).endsWith('external.flac'),
      );
      expect((external['metadata'] as Map)['title'], 'Lossless Bloom');
      final location = await client.resolveMedia(
        libraryUuid: created['uuid'] as String,
        itemId: external['id'] as int,
        volumeId: status.id!,
        generation: status.generation!,
      );
      expect(
        File(location.path).readAsBytesSync(),
        File('${card.path}/external.flac').readAsBytesSync(),
      );
      await command('umount', ['--lazy', mount.path]);
      File('${mount.path}/Music/external.flac')
        ..createSync(recursive: true)
        ..writeAsStringSync('wrong uncovered file');
      VolumeStatus lost = await client.volumeStatus();
      for (
        var i = 0;
        i < 100 && !lost.quiescentMountPaths.contains(mount.path);
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        lost = await client.volumeStatus();
      }
      expect(lost.quiescentMountPaths, contains(mount.path));
      expect(lost.generation, isNot(status.generation));
      await settleJobs();
      expect(await client.items(library), items);
      expect(File('${mount.path}/.cadence/library.sqlite').existsSync(), false);
      await expectLater(
        client.resolveMedia(
          libraryUuid: created['uuid'] as String,
          itemId: external['id'] as int,
          volumeId: lost.id!,
          generation: lost.generation!,
        ),
        throwsA(
          isA<MediaError>().having((e) => e.code, 'code', 'root_unavailable'),
        ),
      );
      await command('mount', ['--bind', card.parent.path, mount.path]);
      await observe(true);
      await settleJobs();
      expect(await client.items(library), items);
      final jobs = ((await client.snapshot())['jobs'] as List).cast<Map>();
      expect(jobs.last['discovered'], 0);
      expect(jobs.last['changed'], 0);
      final drained = await observe(false);
      expect(drained.quiescentMountPaths, contains(mount.path));
      await command('umount', [
        mount.path,
      ]); // Local DB remains open during normal SD eject.
      expect((await client.volumeStatus()).state, 'attached');
      expect(await client.items(library), items);
      expect((await client.ejectVolume())['readyToUnmount'], true);
      process.kill(ProcessSignal.sigterm);
      expect(await process.exitCode, 0);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
