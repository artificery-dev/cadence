import 'package:file/file.dart';
import 'context.dart';
import 'targets.dart';

/// The bundle directory `buildBundle` produces for [target] (null = host).
String bundleDirectory(ToolContext context, LinuxTarget? target) =>
    context.path.join(
      target == null
          ? context.at('build/cli')
          : context.at('build/cli/${target.name}'),
      'bundle',
    );

/// Builds the native probe and both Dart executables for [target] (the host
/// when null) and assembles one `dart build cli` bundle: `bin/cadenced`,
/// `bin/cadencectl`, `lib/libsqlite3.so`, `lib/libcadence_probe.so` and
/// `LICENSE`. Answers the bundle directory.
Future<String> buildBundle(
  ToolContext context, {
  LinuxTarget? target,
  bool debug = false,
}) async {
  await context.run('cargo', [
    'build',
    '--locked',
    '--workspace',
    if (!debug) '--release',
    if (target != null) ...['--target', target.rustTriple],
    if (target?.crossLinker case final linker?) ...[
      '--config',
      'target.${target!.rustTriple}.linker="$linker"',
    ],
  ]);
  // Dart replaces its output directory. Keep it separate from build/rust,
  // and keep cadencectl's own output inside cadenced's so neither build
  // deletes the other's bundle.
  final output = target == null
      ? context.at('build/cli')
      : context.at('build/cli/${target.name}');
  final path = context.path;
  for (final executable in ['cadenced', 'cadencectl']) {
    await context.run(context.dartExecutable, [
      'build',
      'cli',
      '--target',
      'bin/$executable.dart',
      if (target != null) ...[
        '--target-os',
        'linux',
        '--target-arch',
        target.dartArch,
      ],
      '--output',
      executable == 'cadenced' ? output : path.join(output, executable),
    ], directory: 'daemon');
  }
  final fs = context.fileSystem;
  final bundle = path.join(output, 'bundle');
  // Merge cadencectl's executable (and any snapshot library the SDK put
  // beside it) into the main bundle; shared assets already exist there.
  final control = fs.directory(path.join(output, 'cadencectl', 'bundle'));
  for (final entity in control.listSync(recursive: true)) {
    if (entity is! File) continue;
    final destination = fs.file(
      path.join(bundle, path.relative(entity.path, from: control.path)),
    );
    if (destination.existsSync()) continue;
    destination.parent.createSync(recursive: true);
    await entity.copy(destination.path);
  }
  final probe = context.at(
    'build/rust/${target == null ? '' : '${target.rustTriple}/'}${debug ? 'debug' : 'release'}/libcadence_probe.so',
  );
  fs.directory(path.join(bundle, 'lib')).createSync(recursive: true);
  await fs.file(probe).copy(path.join(bundle, 'lib', 'libcadence_probe.so'));
  await fs.file(context.at('LICENSE')).copy(path.join(bundle, 'LICENSE'));
  context.write('Bundle: $bundle');
  return bundle;
}
