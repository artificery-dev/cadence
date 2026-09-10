import 'package:args/command_runner.dart';
import 'src/app.dart';
import 'src/app_debian.dart';
import 'src/build.dart';
import 'src/bundle.dart';
import 'src/context.dart';
import 'src/debian.dart';
import 'src/systemd.dart';
import 'src/fixtures.dart';
import 'src/targets.dart';
export 'src/context.dart';
export 'src/targets.dart';

class CadenceTool extends CommandRunner<void> {
  CadenceTool(ToolContext context, {Future<void> Function(String?)? demo})
    : super('cadence', 'Cadence development commands.') {
    addCommand(_Build(context));
    addCommand(_App(context));
    addCommand(_Native(context));
    addCommand(_Check(context));
    addCommand(_Package(context));
    addCommand(_Fixtures(context));
    addCommand(_VolumeDemo(context));
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
    argParser
      ..addFlag('debug', negatable: false)
      ..addOption(
        'arch',
        allowed: LinuxTarget.names,
        help:
            'Cross-build a complete Linux bundle for a Debian architecture '
            'into build/cli/<arch>; omit to build for this host into build/cli.',
      );
  }
  @override
  String get name => 'build';
  @override
  String get description =>
      'Build native components and the cadenced CLI bundle.';
  @override
  Future<void> run() async {
    noRest();
    final arch = argResults!['arch'] as String?;
    await buildBundle(
      context,
      target: arch == null ? null : LinuxTarget.parse(arch),
      debug: argResults!['debug'] as bool,
    );
  }
}

class _App extends _Command {
  _App(super.context) {
    addSubcommand(_AppCheck(context));
    addSubcommand(_AppBuild(context));
  }
  @override
  String get name => 'app';
  @override
  String get description =>
      'Check and build the Flutter desktop app in app/ (needs the Flutter SDK).';
}

class _AppCheck extends _Command {
  _AppCheck(super.context) {
    argParser.addOption('flutter', defaultsTo: 'flutter');
  }
  @override
  String get name => 'check';
  @override
  String get description => 'Resolve, analyze and test the app.';
  @override
  Future<void> run() async {
    noRest();
    await checkApp(context, flutter: argResults!['flutter'] as String);
  }
}

class _AppBuild extends _Command {
  _AppBuild(super.context) {
    argParser
      ..addOption('flutter', defaultsTo: 'flutter')
      ..addFlag('debug', negatable: false)
      ..addOption(
        'daemon-bundle',
        help:
            'A bundle from `cadence build` to ship inside the app; built '
            'first when omitted.',
      );
  }
  @override
  String get name => 'build';
  @override
  String get description =>
      'Build the Linux desktop app with cadenced bundled beside it.';
  @override
  Future<void> run() async {
    noRest();
    await buildApp(
      context,
      flutter: argResults!['flutter'] as String,
      daemonBundle: argResults!['daemon-bundle'] as String?,
      debug: argResults!['debug'] as bool,
    );
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
      // The integration suites spawn the daemon many times; a compiled host
      // bundle keeps that free of JIT warm-up, which on loaded runners was
      // enough to trip readiness and job timeouts.
      final bundle = await buildBundle(context);
      await context.run(
        context.dartExecutable,
        ['test', 'test/integration'],
        directory: 'daemon',
        environment: {
          'CADENCE_VOLUME_EXECUTABLE': context.path.join(
            bundle,
            'bin',
            'cadenced',
          ),
        },
      );
    }
    await context.run('cargo', ['test', '--locked', '--workspace']);
  }
}

class _Package extends _Command {
  _Package(super.context) {
    addSubcommand(_Systemd(context));
    addSubcommand(_Bundle(context));
    addSubcommand(_Deb(context));
    addSubcommand(_AppDeb(context));
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
      ..addOption(
        'availability',
        allowed: ['filesystem', 'host'],
        defaultsTo: 'filesystem',
      )
      ..addOption(
        'volume',
        help:
            'Existing portable-library mountpoint; initialization is a separate explicit step.',
      )
      ..addFlag(
        'native',
        negatable: false,
        help:
            'Start the daemon with --native true (the probe must be installed).',
      )
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
      volume: argResults!['volume'] as String?,
      availability: argResults!['availability'] as String,
      native: argResults!['native'] as bool,
    );
  }
}

class _Bundle extends _Command {
  _Bundle(super.context) {
    argParser
      ..addOption(
        'bundle',
        mandatory: true,
        help: 'A bundle directory produced by `cadence build`.',
      )
      ..addOption('arch', allowed: LinuxTarget.names, mandatory: true)
      ..addOption(
        'source-commit',
        mandatory: true,
        help: 'Full SHA-1 of the source revision recorded in the manifest.',
      )
      ..addOption(
        'dart-version',
        mandatory: true,
        help: 'Dart SDK version that produced the bundle, e.g. 3.13.2.',
      )
      ..addOption('output', mandatory: true, help: 'Tarball path (.tar.gz).');
  }
  @override
  String get name => 'bundle';
  @override
  String get description =>
      'Write the bundle manifest and archive the bundle as a tarball.';
  @override
  Future<void> run() async {
    noRest();
    await packageBundle(
      context,
      bundle: requiredOption('bundle'),
      target: LinuxTarget.parse(requiredOption('arch')),
      sourceCommit: requiredOption('source-commit'),
      dartVersion: requiredOption('dart-version'),
      output: requiredOption('output'),
    );
  }
}

class _Deb extends _Command {
  _Deb(super.context) {
    argParser
      ..addOption(
        'bundle',
        mandatory: true,
        help: 'A bundle directory produced by `cadence build`.',
      )
      ..addOption('arch', allowed: LinuxTarget.names, mandatory: true)
      ..addOption(
        'version',
        mandatory: true,
        help:
            'Debian package version, e.g. 1.0.0 or 1.0.0~git20260910.abc1234.',
      )
      ..addOption(
        'maintainer',
        mandatory: true,
        help: 'Package maintainer as "Name <email>".',
      )
      ..addOption('output', mandatory: true, help: 'Directory for the .deb.');
  }
  @override
  String get name => 'deb';
  @override
  String get description =>
      'Build a Debian binary package from a bundle with dpkg-deb.';
  @override
  Future<void> run() async {
    noRest();
    await packageDebian(
      context,
      bundle: requiredOption('bundle'),
      target: LinuxTarget.parse(requiredOption('arch')),
      version: requiredOption('version'),
      maintainer: requiredOption('maintainer'),
      output: requiredOption('output'),
    );
  }
}

class _AppDeb extends _Command {
  _AppDeb(super.context) {
    argParser
      ..addOption(
        'bundle',
        mandatory: true,
        help: 'The app bundle from `cadence app build` (flutter build linux).',
      )
      ..addOption('version', mandatory: true, help: 'Debian package version.')
      ..addOption(
        'maintainer',
        mandatory: true,
        help: 'Package maintainer as "Name <email>".',
      )
      ..addOption('output', mandatory: true, help: 'Directory for the .deb.');
  }
  @override
  String get name => 'app-deb';
  @override
  String get description =>
      'Build the desktop app Debian package (recommends cadenced) with dpkg-deb.';
  @override
  Future<void> run() async {
    noRest();
    await packageAppDebian(
      context,
      bundle: requiredOption('bundle'),
      version: requiredOption('version'),
      maintainer: requiredOption('maintainer'),
      output: requiredOption('output'),
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

class _VolumeDemo extends _Command {
  _VolumeDemo(super.context);
  @override
  String get name => 'volume-demo';
  @override
  String get description =>
      'Exercise a standalone portable library in an isolated Linux mount namespace.';
  @override
  Future<void> run() async {
    noRest();
    await context.run(context.dartExecutable, [
      'test',
      'test/integration/volume_linux_test.dart',
      '--reporter',
      'expanded',
    ], directory: 'daemon');
  }
}
