import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:args/command_runner.dart';
import 'package:cadence_tool/cli.dart';
import 'package:cadence_tool/src/fixtures.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

class FakeProcesses implements ProcessRunner {
  final calls = <(String, List<String>, String)>[];
  int result = 0;
  void Function(String, List<String>)? onRun;
  @override
  Future<int> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
  }) async {
    calls.add((executable, arguments, workingDirectory));
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
    test('build keeps Rust and Dart outputs separate ($style)', () async {
      await cli.run(['build']);
      expect(processes.calls.first.$1, 'cargo');
      expect(processes.calls.first.$2, [
        'build',
        '--locked',
        '--workspace',
        '--release',
      ]);
      expect(processes.calls.first.$3, context.root);
      expect(processes.calls.last.$2.last, context.at('build/cli'));
      expect(processes.calls.last.$3, context.at('daemon'));
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
              'ExecStart={{ executable }}\nStateDirectory={{ name }}\n{% if service_user != "" %}User={{ service_user }}\n{% endif %}',
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
        for (final extra in [
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
