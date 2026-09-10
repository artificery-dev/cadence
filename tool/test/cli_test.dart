import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:args/command_runner.dart';
import 'package:cadence_tool/cli.dart';
import 'package:cadence_tool/src/fixtures.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

class FakeProcesses implements ProcessRunner {
  final calls = <(String, List<String>, String)>[];
  final environments = <Map<String, String>?>[];
  int result = 0;
  void Function(String, List<String>)? onRun;
  @override
  Future<int> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    Map<String, String>? environment,
  }) async {
    calls.add((executable, arguments, workingDirectory));
    environments.add(environment);
    onRun?.call(executable, arguments);
    return result;
  }
}

void main() {
  for (final style in [FileSystemStyle.posix, FileSystemStyle.windows]) {
    late MemoryFileSystem fs;
    late FakeProcesses processes;
    late ToolContext context;
    late CadenceTool cli;
    setUp(() {
      fs = MemoryFileSystem.test(style: style);
      final root = style == FileSystemStyle.windows
          ? r'C:\cadence'
          : '/cadence';
      fs.directory(root).createSync(recursive: true);
      fs.currentDirectory = root;
      processes = FakeProcesses();
      context = ToolContext(
        fileSystem: fs,
        root: root,
        processes: processes,
        dartExecutable: 'dart-test',
        write: (_) {},
      );
      cli = CadenceTool(context);
    });

    /// Fakes the outputs `cargo build` and `dart build cli` leave behind so
    /// the assembly step has something to gather.
    void fakeBuildOutputs(String executable, List<String> args) {
      if (executable == 'cargo') {
        final triple = args.contains('--target')
            ? '${args[args.indexOf('--target') + 1]}/'
            : '';
        final profile = args.contains('--release') ? 'release' : 'debug';
        fs.file(context.at('build/rust/${triple}$profile/libcadence_probe.so'))
          ..createSync(recursive: true)
          ..writeAsStringSync('probe');
      } else if (args.first == 'build') {
        final output = args[args.indexOf('--output') + 1];
        final name = context.path.basenameWithoutExtension(
          args[args.indexOf('--target') + 1],
        );
        fs.file(context.path.join(output, 'bundle', 'bin', name))
          ..createSync(recursive: true)
          ..writeAsStringSync(name);
        fs.file(context.path.join(output, 'bundle', 'lib', 'libsqlite3.so'))
          ..createSync(recursive: true)
          ..writeAsStringSync('sqlite');
      }
    }

    test('build keeps Rust and Dart outputs separate ($style)', () async {
      fs.file(context.at('LICENSE')).writeAsStringSync('MIT');
      processes.onRun = fakeBuildOutputs;
      await cli.run(['build']);
      expect(processes.calls.first.$1, 'cargo');
      expect(processes.calls.first.$2, [
        'build',
        '--locked',
        '--workspace',
        '--release',
      ]);
      expect(processes.calls.first.$3, context.root);
      final dartBuilds = processes.calls.where((c) => c.$1 == 'dart-test');
      expect(dartBuilds, hasLength(2));
      expect(dartBuilds.first.$2.last, context.at('build/cli'));
      expect(dartBuilds.first.$3, context.at('daemon'));
      expect(dartBuilds.last.$2, contains('bin/cadencectl.dart'));
      expect(dartBuilds.last.$2.last, context.at('build/cli/cadencectl'));
      final bundle = context.at('build/cli/bundle');
      for (final relative in [
        'bin/cadenced',
        'bin/cadencectl',
        'lib/libsqlite3.so',
        'lib/libcadence_probe.so',
        'LICENSE',
      ]) {
        expect(
          fs
              .file(
                context.path.join(
                  bundle,
                  context.path.joinAll(relative.split('/')),
                ),
              )
              .existsSync(),
          isTrue,
          reason: relative,
        );
      }
      processes.calls.clear();
      await cli.run(['build', '--arch', 'armhf', '--debug']);
      expect(processes.calls.first.$2, [
        'build',
        '--locked',
        '--workspace',
        '--target',
        'armv7-unknown-linux-gnueabihf',
        '--config',
        'target.armv7-unknown-linux-gnueabihf.linker="arm-linux-gnueabihf-gcc"',
      ]);
      expect(
        processes.calls[1].$2,
        containsAllInOrder(['--target-os', 'linux', '--target-arch', 'arm']),
      );
      expect(processes.calls[1].$2.last, context.at('build/cli/armhf'));
      expect(
        fs
            .file(context.at('build/cli/armhf/bundle/lib/libcadence_probe.so'))
            .existsSync(),
        isTrue,
      );
      await expectLater(
        cli.run(['build', '--arch', 'mips']),
        throwsA(isA<UsageException>()),
      );
      processes.calls.clear();
      await cli.run(['native', 'build', '--debug', '--', '--offline']);
      expect(processes.calls.single.$2, [
        'build',
        '--locked',
        '-p',
        'cadence-probe',
        '--offline',
      ]);
    });
    test(
      'failed subprocess stops checks and preserves exit status ($style)',
      () async {
        processes.result = 23;
        await expectLater(
          cli.run(['check']),
          throwsA(isA<ToolFailure>().having((e) => e.exitCode, 'exitCode', 23)),
        );
        expect(processes.calls, hasLength(1));
        await expectLater(
          cli.run(['build', '--unknown']),
          throwsA(isA<UsageException>()),
        );
      },
    );
    test(
      'check runs integration suites against a compiled daemon ($style)',
      () async {
        fs.file(context.at('LICENSE')).writeAsStringSync('MIT');
        processes.onRun = fakeBuildOutputs;
        await cli.run(['check']);
        final integration = processes.calls.indexWhere(
          (c) => c.$2.join(' ') == 'test test/integration',
        );
        expect(integration, greaterThan(0));
        expect(processes.calls[integration].$3, context.at('daemon'));
        expect(processes.environments[integration], {
          'CADENCE_VOLUME_EXECUTABLE': context.at(
            'build/cli/bundle/bin/cadenced',
          ),
        });
        final buildIndex = processes.calls.indexWhere(
          (c) => c.$1 == 'cargo' && c.$2.contains('--release'),
        );
        expect(buildIndex, lessThan(integration));
        expect(processes.calls.last.$2, ['test', '--locked', '--workspace']);
        processes.calls.clear();
        await cli.run(['check', '--no-integration']);
        expect(processes.calls.where((c) => c.$1 == 'cargo'), hasLength(1));
        expect(
          processes.calls.any((c) => c.$2.join(' ') == 'test test/integration'),
          isFalse,
        );
      },
    );

    test(
      'Liquid renderer uses injected paths and escapes systemd arguments ($style)',
      () async {
        for (final scope in ['user', 'system']) {
          fs.file(
              context.at(
                'daemon/packaging/systemd/cadenced.$scope.service.liquid',
              ),
            )
            ..createSync(recursive: true)
            ..writeAsStringSync(
              'ExecStart={{ executable }}{% if volume != "" %} --volume {{ volume }}{% endif %}{% if native == "true" %} --native true{% endif %}\nStateDirectory={{ name }}\n{% if service_user != "" %}User={{ service_user }}\n{% endif %}',
            );
        }
        final output = context.at('build/package/cadenced.service');
        await cli.run([
          'package',
          'systemd',
          '--scope',
          'system',
          '--executable',
          r'/opt/cadence/daemon/a "quoted" $bin%name',
          '--service-user',
          'cadence',
          '--service-group',
          'cadence',
          '--output',
          output,
        ]);
        final result = fs.file(output).readAsStringSync();
        expect(
          result,
          contains(r'ExecStart="/opt/cadence/daemon/a \"quoted\" $$bin%%name"'),
        );
        expect(result, contains('User=cadence'));
        expect(result, isNot(contains('--native')));
        await cli.run([
          'package',
          'systemd',
          '--scope',
          'system',
          '--executable',
          '/usr/bin/cadenced',
          '--service-user',
          'cadence',
          '--service-group',
          'cadence',
          '--native',
          '--output',
          output,
        ]);
        expect(fs.file(output).readAsStringSync(), contains(' --native true'));
        await cli.run([
          'package',
          'systemd',
          '--scope',
          'user',
          '--executable',
          '/usr/bin/cadenced',
          '--output',
          output,
        ]);
        expect(fs.file(output).readAsStringSync(), isNot(contains('User=')));
        expect(fs.file(output).readAsStringSync(), isNot(contains('--volume')));
        await cli.run([
          'package',
          'systemd',
          '--scope',
          'user',
          '--executable',
          '/usr/bin/cadenced',
          '--volume',
          '/mnt/my card',
          '--output',
          output,
        ]);
        expect(
          fs.file(output).readAsStringSync(),
          contains('--volume "/mnt/my card"'),
        );
        for (final extra in [
          ['--volume', 'relative'],
          ['--service-user', 'cadence'],
          ['--executable', 'relative'],
          ['--name', '../escape'],
          ['--executable', '/bin/foo\nExecStart=bad'],
        ]) {
          await expectLater(
            cli.run([
              'package',
              'systemd',
              '--scope',
              'user',
              '--executable',
              '/bin/cadenced',
              '--output',
              output,
              ...extra,
            ]),
            throwsA(isA<ToolFailure>()),
          );
        }
      },
    );

    /// A complete bundle with one fake ELF binding GLIBC_2.34 and a probe
    /// binding GLIBC_2.28; the package must ask for the newer floor.
    String fakeBundle() {
      final bundle = context.at('build/cli/arm64/bundle');
      final elf = [0x7f, 0x45, 0x4c, 0x46];
      for (final entry in {
        'bin/cadenced': [...elf, ...utf8.encode('x GLIBC_2.17 GLIBC_2.34 y')],
        'bin/cadencectl': [...elf, ...utf8.encode('GLIBC_2.29')],
        'lib/libsqlite3.so': [...elf, ...utf8.encode('GLIBC_2.4')],
        'lib/libcadence_probe.so': [...elf, ...utf8.encode('GLIBC_2.28')],
        'LICENSE': utf8.encode('MIT GLIBC_2.99 is only text here'),
      }.entries) {
        fs.file(
            context.path.join(
              bundle,
              context.path.joinAll(entry.key.split('/')),
            ),
          )
          ..createSync(recursive: true)
          ..writeAsBytesSync(entry.value);
      }
      return bundle;
    }

    test('bundle packaging writes a Tempo-style manifest ($style)', () async {
      final bundle = fakeBundle();
      final output = context.at('build/dist/cadenced-1.0.0-linux-arm64.tar.gz');
      const commit = '0123456789abcdef0123456789abcdef01234567';
      await cli.run([
        'package',
        'bundle',
        '--bundle',
        bundle,
        '--arch',
        'arm64',
        '--source-commit',
        commit,
        '--dart-version',
        '3.13.2',
        '--output',
        output,
      ]);
      final manifest =
          jsonDecode(
                fs
                    .file(context.path.join(bundle, 'manifest.json'))
                    .readAsStringSync(),
              )
              as Map;
      expect(manifest['sourceCommit'], commit);
      expect(manifest['dart'], '3.13.2');
      expect(manifest['target'], 'arm64');
      final files = manifest['files'] as Map;
      expect(
        files.keys,
        unorderedEquals([
          'bin/cadenced',
          'bin/cadencectl',
          'lib/libsqlite3.so',
          'lib/libcadence_probe.so',
          'LICENSE',
        ]),
      );
      expect(
        files['LICENSE'],
        sha256
            .convert(
              fs.file(context.path.join(bundle, 'LICENSE')).readAsBytesSync(),
            )
            .toString(),
      );
      final archive = TarDecoder().decodeBytes(
        GZipDecoder().decodeBytes(fs.file(output).readAsBytesSync()),
      );
      final names = [for (final f in archive) f.name];
      expect(
        names,
        unorderedEquals([
          'cadenced/bin/cadenced',
          'cadenced/bin/cadencectl',
          'cadenced/lib/libsqlite3.so',
          'cadenced/lib/libcadence_probe.so',
          'cadenced/LICENSE',
          'cadenced/manifest.json',
        ]),
      );
      expect(archive.find('cadenced/bin/cadenced')!.mode & 0x49, 0x49);
      expect(archive.find('cadenced/LICENSE')!.mode & 0x49, 0);
      // A second run replaces the manifest instead of hashing the old one.
      await cli.run([
        'package',
        'bundle',
        '--bundle',
        bundle,
        '--arch',
        'arm64',
        '--source-commit',
        commit,
        '--dart-version',
        '3.13.2',
        '--output',
        output,
      ]);
      expect(
        (jsonDecode(
              fs
                  .file(context.path.join(bundle, 'manifest.json'))
                  .readAsStringSync(),
            )
            as Map)['files'],
        isNot(contains('manifest.json')),
      );
      for (final bad in [
        ['--source-commit', 'abc'],
        ['--dart-version', 'latest'],
      ]) {
        await expectLater(
          cli.run([
            'package',
            'bundle',
            '--bundle',
            bundle,
            '--arch',
            'arm64',
            '--source-commit',
            commit,
            '--dart-version',
            '3.13.2',
            '--output',
            output,
            ...bad,
          ]),
          throwsA(isA<ToolFailure>()),
        );
      }
      fs
          .file(context.path.join(bundle, 'lib', 'libcadence_probe.so'))
          .deleteSync();
      await expectLater(
        cli.run([
          'package',
          'bundle',
          '--bundle',
          bundle,
          '--arch',
          'arm64',
          '--source-commit',
          commit,
          '--dart-version',
          '3.13.2',
          '--output',
          output,
        ]),
        throwsA(isA<ToolFailure>()),
      );
    });

    test('Debian packaging stages a policy-shaped tree ($style)', () async {
      final bundle = fakeBundle();
      fs.file(context.at('LICENSE')).writeAsStringSync('MIT');
      fs.file(
          context.at('daemon/packaging/systemd/cadenced.system.service.liquid'),
        )
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'ExecStart={{ executable }} --policy lean{% if native == "true" %} --native true{% endif %}\nUser={{ service_user }}\n',
        );
      await cli.run([
        'package',
        'deb',
        '--bundle',
        bundle,
        '--arch',
        'arm64',
        '--version',
        '1.0.0~git20260910.abc1234',
        '--maintainer',
        'Cadence Maintainers <cadence@example.org>',
        '--output',
        context.at('build/dist'),
      ]);
      final staging = context.at(
        'build/deb/arm64/cadenced_1.0.0~git20260910.abc1234_arm64',
      );
      String read(String relative) => fs
          .file(
            context.path.join(
              staging,
              context.path.joinAll(relative.split('/')),
            ),
          )
          .readAsStringSync();
      final control = read('DEBIAN/control');
      expect(control, contains('Package: cadenced\n'));
      expect(control, contains('Version: 1.0.0~git20260910.abc1234\n'));
      expect(control, contains('Architecture: arm64\n'));
      expect(
        control,
        contains('Depends: libc6 (>= 2.34), libgcc-s1, adduser\n'),
      );
      expect(
        control,
        contains('Maintainer: Cadence Maintainers <cadence@example.org>\n'),
      );
      expect(control, matches(RegExp(r'Installed-Size: [1-9]\d*\n')));
      final unit = read('usr/lib/systemd/system/cadenced.service');
      expect(
        unit,
        contains(
          'ExecStart="/usr/lib/cadenced/bin/cadenced" --policy lean --native true',
        ),
      );
      expect(unit, contains('User=cadence'));
      expect(read('usr/share/doc/cadenced/copyright'), 'MIT');
      expect(read('DEBIAN/postinst'), contains('adduser --system'));
      expect(read('DEBIAN/postrm'), contains('rm -rf /var/lib/cadenced'));
      expect(read('DEBIAN/prerm'), contains('stop cadenced.service'));
      final sums = read('DEBIAN/md5sums');
      expect(sums, contains('  usr/lib/cadenced/bin/cadenced\n'));
      expect(sums, contains('  usr/lib/systemd/system/cadenced.service\n'));
      expect(sums, isNot(contains('DEBIAN')));
      expect(
        fs
            .link(context.path.join(staging, 'usr', 'sbin', 'cadenced'))
            .targetSync(),
        '../lib/cadenced/bin/cadenced',
      );
      expect(
        fs
            .link(context.path.join(staging, 'usr', 'bin', 'cadencectl'))
            .targetSync(),
        '../lib/cadenced/bin/cadencectl',
      );
      final chmods = processes.calls.where((c) => c.$1 == 'chmod').toList();
      expect(chmods, hasLength(2));
      expect(chmods[0].$2.first, '0644');
      expect(
        chmods[0].$2.skip(1).map(context.path.basename),
        unorderedEquals([
          'libsqlite3.so',
          'libcadence_probe.so',
          'LICENSE',
          'cadenced.service',
          'copyright',
        ]),
      );
      expect(chmods[1].$2.first, '0755');
      expect(
        chmods[1].$2.skip(1).map(context.path.basename),
        unorderedEquals([
          'cadenced',
          'cadencectl',
          'postinst',
          'prerm',
          'postrm',
        ]),
      );
      expect(processes.calls.last.$1, 'dpkg-deb');
      expect(processes.calls.last.$2, [
        '--build',
        '--root-owner-group',
        staging,
        context.path.join(
          context.at('build/dist'),
          'cadenced_1.0.0~git20260910.abc1234_arm64.deb',
        ),
      ]);
      for (final bad in [
        ['--version', 'v1.0.0'],
        ['--version', '1.0.0 beta'],
        ['--maintainer', 'nobody'],
      ]) {
        await expectLater(
          cli.run([
            'package',
            'deb',
            '--bundle',
            bundle,
            '--arch',
            'arm64',
            '--version',
            '1.0.0',
            '--maintainer',
            'A <a@b.c>',
            '--output',
            context.at('build/dist'),
            ...bad,
          ]),
          throwsA(isA<ToolFailure>()),
        );
      }
    });

    test(
      'fixture generation stages files, builds archives, and cleans up ($style)',
      () async {
        final output = context.at('fixtures');
        fs.file(context.path.join(output, 'README.md'))
          ..createSync(recursive: true)
          ..writeAsStringSync('keep');
        processes.onRun = (executable, args) {
          if (executable == 'ffmpeg')
            fs.file(args.last).writeAsStringSync('fake media');
        };
        await cli.run(['fixtures', '--output', output]);
        for (final name in expectedFixtures) {
          expect(
            fs
                .file(
                  context.path.join(
                    output,
                    context.path.joinAll(name.split('/')),
                  ),
                )
                .lengthSync(),
            greaterThan(0),
          );
        }
        final epub = ZipDecoder().decodeBytes(
          fs
              .file(context.path.join(output, 'doc', 'book.epub'))
              .readAsBytesSync(),
        );
        expect(epub.first.name, 'mimetype');
        expect(epub.first.compression, CompressionType.none);
        expect(utf8.decode(epub.first.content), 'application/epub+zip');
        expect(epub.find('OEBPS/content.opf'), isNotNull);
        expect(
          fs.file(context.path.join(output, 'README.md')).readAsStringSync(),
          'keep',
        );
        expect(
          fs
              .directory(context.root)
              .listSync()
              .where(
                (e) => context.path
                    .basename(e.path)
                    .startsWith('.cadence-fixtures-'),
              ),
          isEmpty,
        );
        processes.result = 7;
        await expectLater(
          cli.run(['fixtures', '--output', output]),
          throwsA(isA<ToolFailure>()),
        );
        expect(
          fs
              .file(context.path.join(output, 'audio', 'id3v23.mp3'))
              .readAsStringSync(),
          'fake media',
        );
        expect(
          fs
              .directory(context.root)
              .listSync()
              .where(
                (e) => context.path
                    .basename(e.path)
                    .startsWith('.cadence-fixtures-'),
              ),
          isEmpty,
        );
      },
    );
  }
}
