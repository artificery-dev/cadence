import 'package:file/file.dart';
import 'build.dart';
import 'context.dart';

/// The Flutter desktop app lives in `app/`, outside the pub workspace: it
/// needs the Flutter SDK, which the pure-Dart workspace does not use.
/// These commands drive it with `flutter` and marry its Linux bundle to a
/// `cadence build` bundle, so the packaged app can install `cadenced`.
const appDirectory = 'app';

/// `flutter pub get`, `flutter analyze` and `flutter test` in `app/`.
Future<void> checkApp(ToolContext context, {String flutter = 'flutter'}) async {
  await context.run(flutter, ['pub', 'get'], directory: appDirectory);
  await context.run(flutter, ['analyze'], directory: appDirectory);
  await context.run(flutter, ['test'], directory: appDirectory);
}

/// Builds the Linux desktop app in release and copies the daemon bundle —
/// built first unless [daemonBundle] names one — to `daemon/` beside the
/// app's executable, where the app looks for it. Answers the app bundle.
Future<String> buildApp(
  ToolContext context, {
  String flutter = 'flutter',
  String? daemonBundle,
  bool debug = false,
}) async {
  final daemon = daemonBundle ?? await buildBundle(context, debug: debug);
  await context.run(flutter, ['pub', 'get'], directory: appDirectory);
  await context.run(flutter, [
    'build',
    'linux',
    debug ? '--debug' : '--release',
  ], directory: appDirectory);
  final fs = context.fileSystem;
  final path = context.path;
  final output = fs.directory(
    context.at('app/build/linux/x64/${debug ? 'debug' : 'release'}/bundle'),
  );
  if (!output.existsSync()) {
    throw ToolFailure('flutter build left no bundle at ${output.path}');
  }
  final destination = fs.directory(path.join(output.path, 'daemon'));
  if (destination.existsSync()) destination.deleteSync(recursive: true);
  for (final part in ['bin', 'lib']) {
    final from = fs.directory(path.join(daemon, part));
    if (!from.existsSync()) {
      throw ToolFailure('Daemon bundle is missing $part/: $daemon');
    }
    for (final entity in from.listSync()) {
      if (entity is! File) continue;
      final copy = fs.file(
        path.join(destination.path, part, path.basename(entity.path)),
      );
      copy.parent.createSync(recursive: true);
      await entity.copy(copy.path);
    }
  }
  context.write('App bundle: ${output.path} (daemon in daemon/)');
  return output.path;
}
