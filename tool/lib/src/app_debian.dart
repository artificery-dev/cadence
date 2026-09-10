import 'package:crypto/crypto.dart';
import 'package:file/file.dart';
import 'context.dart';
import 'debian.dart' show glibcFloorOf;

/// The Debian package of the desktop app.
const appDebianPackage = 'cadence';

/// The application id every launcher, icon and desktop entry carries.
const applicationId = 'dev.artificery.cadence';

/// Where the package installs the Flutter bundle; `/usr/bin/cadence` is a
/// symbolic link into it.
const appDebianInstallRoot = 'usr/lib/cadence';

/// The icon sizes the hicolor set in `assets/cadence/linux` provides.
const hicolorSizes = [16, 22, 24, 32, 48, 64, 128, 256, 512];

/// Stages a Debian binary package for the app bundle `flutter build linux`
/// left (with or without a `daemon/` beside it) under `build/deb/amd64`
/// and builds `<output>/cadence_<version>_amd64.deb` with `dpkg-deb`.
///
/// The bundle goes to `/usr/lib/cadence` without the bundled daemon: the
/// package recommends `cadenced` instead, whose copy under
/// `/usr/lib/cadenced` the app prefers and runs in place. The desktop
/// entry, the hicolor icons and the AppStream metainfo come from the
/// asset library, renamed to the application id where the desktop looks
/// for them.
Future<String> packageAppDebian(
  ToolContext context, {
  required String bundle,
  required String version,
  required String maintainer,
  required String output,
  String arch = 'amd64',
}) async {
  if (!RegExp(r'^[0-9][A-Za-z0-9.+~-]*$').hasMatch(version)) {
    throw ToolFailure('Invalid Debian version: $version', 64);
  }
  if (!RegExp(r'^[^<>\n]+ <[^<>@\s]+@[^<>@\s]+>$').hasMatch(maintainer)) {
    throw ToolFailure('--maintainer must be "Name <email>"', 64);
  }
  final fs = context.fileSystem;
  final path = context.path;
  final source = fs.directory(bundle);
  if (!fs.file(path.join(source.path, appDebianPackage)).existsSync()) {
    throw ToolFailure('No app executable in bundle: $bundle', 64);
  }

  final name = '${appDebianPackage}_${version}_$arch';
  final staging = context.at('build/deb/$arch/$name');
  final root = fs.directory(staging);
  if (root.existsSync()) root.deleteSync(recursive: true);
  root.createSync(recursive: true);
  String at(String relative) =>
      path.join(staging, path.joinAll(relative.split('/')));

  final executables = <String>[];
  final plain = <String>[];
  final installed = <String>[];
  final elf = <String>[];
  Future<void> install(
    File from,
    String relative, {
    bool executable = false,
    bool binary = false,
  }) async {
    final file = fs.file(at(relative));
    file.parent.createSync(recursive: true);
    await from.copy(file.path);
    installed.add(relative);
    (executable ? executables : plain).add(file.path);
    if (binary) elf.add(file.path);
  }

  // The bundle, minus daemon/: the package leans on cadenced instead.
  for (final entity in source.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final relative = path.relative(entity.path, from: source.path);
    final parts = path.split(relative);
    if (parts.first == 'daemon') continue;
    final isExecutable = parts.length == 1 && parts.first == appDebianPackage;
    final isLibrary = parts.first == 'lib' && relative.endsWith('.so');
    await install(
      entity,
      '$appDebianInstallRoot/${parts.join('/')}',
      executable: isExecutable,
      binary: isExecutable || isLibrary,
    );
  }
  fs.link(at('usr/bin/$appDebianPackage'))
    ..parent.createSync(recursive: true)
    ..createSync('../lib/$appDebianPackage/$appDebianPackage');

  final assets = context.at('assets/cadence/linux');
  await install(
    fs.file(path.join(assets, '$applicationId.desktop')),
    'usr/share/applications/$applicationId.desktop',
  );
  await install(
    fs.file(path.join(assets, '$applicationId.metainfo.xml')),
    'usr/share/metainfo/$applicationId.metainfo.xml',
  );
  for (final size in hicolorSizes) {
    await install(
      fs.file(
        path.join(assets, 'hicolor', '${size}x$size', 'apps', 'cadence.png'),
      ),
      'usr/share/icons/hicolor/${size}x$size/apps/$applicationId.png',
    );
  }
  await install(
    fs.file(path.join(assets, 'hicolor', 'scalable', 'apps', 'cadence.svg')),
    'usr/share/icons/hicolor/scalable/apps/$applicationId.svg',
  );
  await install(
    fs.file(
      path.join(assets, 'hicolor', 'symbolic', 'apps', 'cadence-symbolic.svg'),
    ),
    'usr/share/icons/hicolor/symbolic/apps/$applicationId-symbolic.svg',
  );
  await install(
    fs.file(context.at('LICENSE')),
    'usr/share/doc/$appDebianPackage/copyright',
  );

  final glibc = await glibcFloorOf(context, elf);
  var bytes = 0;
  final sums = StringBuffer();
  for (final relative in installed) {
    final file = fs.file(at(relative));
    bytes += file.lengthSync();
    sums.writeln('${md5.convert(file.readAsBytesSync())}  $relative');
  }
  final control = fs.directory(at('DEBIAN'))..createSync();
  fs.file(path.join(control.path, 'control')).writeAsStringSync('''
Package: $appDebianPackage
Version: $version
Architecture: $arch
Maintainer: $maintainer
Installed-Size: ${(bytes + 1023) ~/ 1024}
Depends: libc6 (>= $glibc), libgcc-s1, libstdc++6, libgtk-3-0, libmpv2, libepoxy0
Recommends: cadenced
Section: video
Priority: optional
Description: Cadence media player
 A media player over a library of music, films, shows, books and pictures.
 The library is scanned and watched by cadenced, which runs inside Cadence
 by default; with the cadenced package installed, Cadence can hand the
 library to it as a background service that keeps working while the
 player is closed.
''');
  fs.file(path.join(control.path, 'md5sums')).writeAsStringSync('$sums');
  const postinst = '''
if [ "\$1" = configure ]; then
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
  fi
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications >/dev/null 2>&1 || true
  fi
fi
''';
  fs
      .file(path.join(control.path, 'postinst'))
      .writeAsStringSync('#!/bin/sh\nset -e\n$postinst');
  fs
      .file(path.join(control.path, 'postrm'))
      .writeAsStringSync(
        '#!/bin/sh\nset -e\n$postinst'.replaceFirst('configure', 'remove'),
      );
  executables.addAll([
    path.join(control.path, 'postinst'),
    path.join(control.path, 'postrm'),
  ]);
  await context.run('chmod', ['0644', ...plain]);
  await context.run('chmod', ['0755', ...executables]);

  final destination = fs.directory(output)..createSync(recursive: true);
  final package = path.join(destination.path, '$name.deb');
  await context.run('dpkg-deb', [
    '--build',
    '--root-owner-group',
    staging,
    package,
  ]);
  context.write('Packaged $package');
  return package;
}
