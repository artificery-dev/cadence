import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file/file.dart';
import 'context.dart';
import 'targets.dart';

/// Files every shippable bundle must carry, relative to its root.
const requiredBundleFiles = [
  'bin/cadenced',
  'lib/libsqlite3.so',
  'lib/libcadence_probe.so',
];

/// Ensures [bundle] is a complete `dart build cli` bundle with the probe
/// library beside SQLite, and answers its files relative to the root in a
/// stable order.
/// Resolves a slash-separated bundle-relative name on the tool's filesystem.
String bundlePath(ToolContext context, String bundle, String relative) =>
    context.path.join(bundle, context.path.joinAll(relative.split('/')));

List<String> verifyBundle(ToolContext context, String bundle) {
  final fs = context.fileSystem;
  final directory = fs.directory(bundle);
  if (!directory.existsSync()) throw ToolFailure('No bundle at $bundle', 64);
  for (final relative in requiredBundleFiles) {
    if (!fs.file(bundlePath(context, bundle, relative)).existsSync())
      throw ToolFailure('Incomplete bundle: missing $relative', 64);
  }
  final files = <String>[];
  for (final entity in directory.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File) {
      files.add(
        context.path
            .relative(entity.path, from: bundle)
            .split(context.path.separator)
            .join('/'),
      );
    } else if (entity is! Directory) {
      throw ToolFailure('Bundle entries must be regular files: ${entity.path}');
    }
  }
  return files..sort();
}

Future<String> sha256Of(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

/// Writes `manifest.json` into [bundle] and archives the bundle as
/// `cadenced/<file>` entries of a gzip-compressed tarball at [output].
///
/// The manifest records the source commit, the Dart SDK that produced the
/// executable, the Dart architecture name and a SHA-256 for every other
/// file, which is what Tempo's rootfs staging verifies before installing.
Future<void> packageBundle(
  ToolContext context, {
  required String bundle,
  required LinuxTarget target,
  required String sourceCommit,
  required String dartVersion,
  required String output,
}) async {
  if (!RegExp(r'^[a-f0-9]{40}$').hasMatch(sourceCommit))
    throw ToolFailure('--source-commit must be a full lowercase SHA-1', 64);
  if (!RegExp(r'^\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?$').hasMatch(dartVersion))
    throw ToolFailure('--dart-version must look like 3.13.2', 64);
  final fs = context.fileSystem;
  final license = fs.file(context.path.join(bundle, 'LICENSE'));
  if (!license.existsSync()) {
    await fs.file(context.at('LICENSE')).copy(license.path);
  }
  final manifest = fs.file(context.path.join(bundle, 'manifest.json'));
  if (manifest.existsSync()) manifest.deleteSync();
  final files = verifyBundle(context, bundle);
  final hashes = <String, String>{
    for (final relative in files)
      relative: await sha256Of(fs.file(bundlePath(context, bundle, relative))),
  };
  manifest.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({'sourceCommit': sourceCommit, 'dart': dartVersion, 'target': target.dartArch, 'files': hashes})}\n',
  );
  final archive = Archive();
  for (final relative in [...files, 'manifest.json']) {
    final bytes = fs
        .file(bundlePath(context, bundle, relative))
        .readAsBytesSync();
    archive.add(
      ArchiveFile.bytes('cadenced/$relative', bytes)
        ..mode = relative.startsWith('bin/') ? 0x1ed : 0x1a4,
    );
  }
  final destination = fs.file(output);
  destination.parent.createSync(recursive: true);
  destination.writeAsBytesSync(
    GZipEncoder().encodeBytes(TarEncoder().encodeBytes(archive)),
  );
  context.write('Archived ${destination.path}');
}
