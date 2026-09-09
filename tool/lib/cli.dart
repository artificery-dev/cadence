import 'package:args/command_runner.dart';
import 'src/context.dart';
import 'src/systemd.dart';
import 'src/fixtures.dart';
export 'src/context.dart';

class CadenceTool extends CommandRunner<void> {
  CadenceTool(ToolContext context, {Future<void> Function(String?)? demo})
    : super('cadence', 'Cadence development commands.') {
    addCommand(_Build(context));
    addCommand(_Native(context));
    addCommand(_Check(context));
    addCommand(_Package(context));
    addCommand(_Fixtures(context));
    if (demo != null) addCommand(_Demo(demo));
  }
}

abstract class _Command extends Command<void> {
  _Command(this.context);
  final ToolContext context;
  String requiredOption(String name) {
    final value = argResults![name] as String?;
    if (value == null || value.isEmpty) usageException('--$name is required');
    return value;
  }

  void noRest() {
    if (argResults!.rest.isNotEmpty)
      usageException('Unexpected positional arguments');
  }
}

class _Build extends _Command {
  _Build(super.context) {
    argParser.addFlag('debug', negatable: false);
  }
  @override
  String get name => 'build';
  @override
  String get description =>
      'Build native components and the cadenced CLI bundle.';
  @override
  Future<void> run() async {
    noRest();
    await context.run('cargo', [
      'build',
      '--locked',
      '--workspace',
      if (!argResults!['debug']) '--release',
    ]);
    // Dart replaces its output directory. Keep it separate from build/rust.
    await context.run(context.dartExecutable, [
      'build',
      'cli',
      '--target',
      'bin/cadenced.dart',
      '--output',
      context.at('build/cli'),
    ], directory: 'daemon');
  }
}

class _Native extends _Command {
  _Native(super.context) {
    addSubcommand(_NativeBuild(context));
  }
  @override
  String get name => 'native';
  @override
  String get description => 'Build native extraction components.';
}

class _NativeBuild extends _Command {
  _NativeBuild(super.context) {
    argParser.addFlag('debug', negatable: false);
  }
  @override
  String get name => 'build';
  @override
  String get description =>
      'Build cadence-probe into build/rust; pass extra Cargo arguments after --.';
  @override
  Future<void> run() => context.run('cargo', [
    'build',
    '--locked',
    '-p',
    'cadence-probe',
    if (!argResults!['debug']) '--release',
    ...argResults!.rest,
  ]);
}

class _Check extends _Command {
  _Check(super.context) {
    argParser.addFlag(
      'integration',
      defaultsTo: true,
      help: 'Run Linux socket, watcher and native integration tests.',
    );
  }
  @override
  String get name => 'check';
  @override
  String get description =>
      'Resolve dependencies, analyze, and run Dart and Rust tests.';
  @override
  Future<void> run() async {
    noRest();
    await context.run(context.dartExecutable, ['pub', 'get']);
    await context.run(context.dartExecutable, ['analyze']);
    for (final directory in ['tool', 'packages/media']) {
      await context.run(context.dartExecutable, ['test'], directory: directory);
    }
    await context.run(context.dartExecutable, [
      'test',
      'test/core',
    ], directory: 'daemon');
    if (argResults!['integration']) {
      await context.run(context.dartExecutable, [
        'test',
        'test/integration',
      ], directory: 'daemon');
    }
    await context.run('cargo', ['test', '--locked', '--workspace']);
  }
}

class _Package extends _Command {
  _Package(super.context) {
    addSubcommand(_Systemd(context));
  }
  @override
  String get name => 'package';
  @override
  String get description =>
      'Render packaging files without installing services.';
}

class _Systemd extends _Command {
  _Systemd(super.context) {
    argParser
      ..addOption('scope', allowed: ['system', 'user'], mandatory: true)
      ..addOption(
        'executable',
        mandatory: true,
        help: 'Installed Linux cadenced executable path.',
      )
      ..addOption('name', defaultsTo: 'cadence')
      ..addOption('service-user')
      ..addOption('service-group')
      ..addOption('output', mandatory: true);
  }
  @override
  String get name => 'systemd';
  @override
  String get description =>
      'Render a system or user systemd unit using Liquid templates.';
  @override
  Future<void> run() async {
    noRest();
    await renderSystemd(
      context,
      scope: requiredOption('scope'),
      executable: requiredOption('executable'),
      output: requiredOption('output'),
      name: argResults!['name'] as String,
      user: argResults!['service-user'] as String?,
      group: argResults!['service-group'] as String?,
    );
  }
}

class _Fixtures extends _Command {
  _Fixtures(super.context) {
    argParser
      ..addOption('ffmpeg', defaultsTo: 'ffmpeg')
      ..addOption('exiftool', defaultsTo: 'exiftool')
      ..addOption(
        'output',
        help: 'Fixture directory; defaults to packages/media/test/fixtures.',
      );
  }
  @override
  String get name => 'fixtures';
  @override
  String get description =>
      'Rebuild media fixtures (requires ffmpeg and exiftool).';
  @override
  Future<void> run() async {
    noRest();
    await generateFixtures(
      context,
      output:
          argResults!['output'] as String? ??
          context.at('packages/media/test/fixtures'),
      ffmpeg: argResults!['ffmpeg'] as String,
      exiftool: argResults!['exiftool'] as String,
    );
  }
}

class _Demo extends Command<void> {
  _Demo(this.demo) {
    argParser.addOption(
      'executable',
      help: 'Use a compiled cadenced instead of Dart source.',
    );
  }
  final Future<void> Function(String?) demo;
  @override
  String get name => 'demo';
  @override
  String get description =>
      'Start a daemon, scan a fixture, reconnect, query, and shut down.';
  @override
  Future<void> run() {
    if (argResults!.rest.isNotEmpty)
      usageException('Unexpected positional arguments');
    return demo(argResults!['executable'] as String?);
  }
}
