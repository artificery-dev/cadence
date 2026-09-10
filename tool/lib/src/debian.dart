import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'bundle.dart';
import 'context.dart';
import 'systemd.dart';
import 'targets.dart';

const debianPackage = 'cadenced';
const debianServiceAccount = 'cadence';

/// Where the package installs the bundle; `/usr/sbin/cadenced` and
/// `/usr/bin/cadencectl` are symbolic links into it.
const debianInstallRoot = 'usr/lib/cadenced';

/// The newest glibc symbol version any ELF file in [bundle] binds to, as
/// `2.NN`, so the package declares the `libc6` floor it truly needs instead
/// of guessing from the build host.
Future<String> glibcFloor(ToolContext context, String bundle) async {
  final fs = context.fileSystem;
  var floor = 0;
  final pattern = RegExp(r'GLIBC_2\.(\d+)');
  for (final relative in verifyBundle(context, bundle)) {
    final bytes = fs
        .file(bundlePath(context, bundle, relative))
        .readAsBytesSync();
    if (bytes.length < 4 ||
        bytes[0] != 0x7f ||
        bytes[1] != 0x45 ||
        bytes[2] != 0x4c ||
        bytes[3] != 0x46)
      continue;
    for (final match in pattern.allMatches(latin1.decode(bytes))) {
      final minor = int.parse(match.group(1)!);
      if (minor > floor) floor = minor;
    }
  }
  if (floor == 0) throw ToolFailure('No glibc symbol versions found in bundle');
  return '2.$floor';
}

String _shell(String body) => '#!/bin/sh\nset -e\n$body';

const _postinst =
    '''
if [ "\$1" = configure ]; then
  if ! getent group $debianServiceAccount >/dev/null; then
    addgroup --system --quiet $debianServiceAccount
  fi
  if ! getent passwd $debianServiceAccount >/dev/null; then
    adduser --system --quiet --ingroup $debianServiceAccount \\
      --home /var/lib/$debianPackage --no-create-home \\
      --shell /usr/sbin/nologin --gecos "Cadence media library daemon" \\
      $debianServiceAccount
  fi
  if [ -d /run/systemd/system ]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
fi
''';

const _prerm =
    '''
if [ "\$1" = remove ] && [ -d /run/systemd/system ]; then
  if command -v deb-systemd-invoke >/dev/null 2>&1; then
    deb-systemd-invoke stop $debianPackage.service >/dev/null 2>&1 || true
  else
    systemctl stop $debianPackage.service >/dev/null 2>&1 || true
  fi
fi
''';

const _postrm =
    '''
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload >/dev/null 2>&1 || true
fi
if [ "\$1" = purge ]; then
  rm -rf /var/lib/$debianPackage /var/cache/$debianPackage
  if command -v deb-systemd-helper >/dev/null 2>&1; then
    deb-systemd-helper purge $debianPackage.service >/dev/null 2>&1 || true
  fi
fi
''';

/// Stages a Debian binary package for [bundle] under `build/deb/<arch>` and
/// builds `<output>/cadenced_<version>_<arch>.deb` with `dpkg-deb`.
///
/// The package installs the bundle to `/usr/lib/cadenced`, links the two
/// executables into the path, ships a disabled system unit that runs the
/// daemon as the `cadence` account with native extraction on, creates that
/// account on install and removes the daemon's state on purge.
Future<String> packageDebian(
  ToolContext context, {
  required String bundle,
  required LinuxTarget target,
  required String version,
  required String maintainer,
  required String output,
}) async {
  if (!RegExp(r'^[0-9][A-Za-z0-9.+~-]*$').hasMatch(version))
    throw ToolFailure('Invalid Debian version: $version', 64);
  if (!RegExp(r'^[^<>\n]+ <[^<>@\s]+@[^<>@\s]+>$').hasMatch(maintainer))
    throw ToolFailure('--maintainer must be "Name <email>"', 64);
  final fs = context.fileSystem;
  final path = context.path;
  final files = verifyBundle(context, bundle);
  final glibc = await glibcFloor(context, bundle);

  final name = '${debianPackage}_${version}_${target.name}';
  final staging = context.at('build/deb/${target.name}/$name');
  final root = fs.directory(staging);
  if (root.existsSync()) root.deleteSync(recursive: true);
  root.createSync(recursive: true);
  String at(String relative) =>
      path.join(staging, path.joinAll(relative.split('/')));

  // Copies keep their source modes, which a private checkout (umask 077) or
  // a Cargo output would carry into the package, so every staged file is
  // normalised: executables 0755, everything else 0644.
  final executables = <String>[];
  final plain = <String>[];
  final installed = <String>[];
  for (final relative in files) {
    final destination = '$debianInstallRoot/$relative';
    final file = fs.file(at(destination));
    file.parent.createSync(recursive: true);
    await fs.file(bundlePath(context, bundle, relative)).copy(file.path);
    installed.add(destination);
    (relative.startsWith('bin/') ? executables : plain).add(file.path);
  }
  fs.link(at('usr/sbin/cadenced'))
    ..parent.createSync(recursive: true)
    ..createSync('../lib/cadenced/bin/cadenced');
  if (files.contains('bin/cadencectl')) {
    fs.link(at('usr/bin/cadencectl'))
      ..parent.createSync(recursive: true)
      ..createSync('../lib/cadenced/bin/cadencectl');
  }

  const unit = 'usr/lib/systemd/system/$debianPackage.service';
  await renderSystemd(
    context,
    scope: 'system',
    executable: '/$debianInstallRoot/bin/cadenced',
    output: at(unit),
    name: debianPackage,
    user: debianServiceAccount,
    group: debianServiceAccount,
    native: true,
  );
  installed.add(unit);
  plain.add(at(unit));

  const copyright = 'usr/share/doc/$debianPackage/copyright';
  fs.file(at(copyright)).parent.createSync(recursive: true);
  await fs.file(context.at('LICENSE')).copy(at(copyright));
  installed.add(copyright);
  plain.add(at(copyright));

  var bytes = 0;
  final sums = StringBuffer();
  for (final relative in installed) {
    final file = fs.file(at(relative));
    bytes += file.lengthSync();
    sums.writeln('${md5.convert(file.readAsBytesSync())}  $relative');
  }

  final control = fs.directory(at('DEBIAN'))..createSync();
  fs.file(path.join(control.path, 'control')).writeAsStringSync('''
Package: $debianPackage
Version: $version
Architecture: ${target.name}
Maintainer: $maintainer
Installed-Size: ${(bytes + 1023) ~/ 1024}
Depends: libc6 (>= $glibc), libgcc-s1, adduser
Section: misc
Priority: optional
Description: Cadence media library daemon
 One host process owns a SQLite media library and serves scans, queries,
 tags, collections and artwork to local applications over a Unix socket.
 This package installs the daemon, the cadencectl client, the bundled
 SQLite and native metadata probe, and a systemd unit (left disabled) that
 runs the daemon as the cadence service account.
''');
  fs.file(path.join(control.path, 'md5sums')).writeAsStringSync('$sums');
  final scripts = {'postinst': _postinst, 'prerm': _prerm, 'postrm': _postrm};
  for (final entry in scripts.entries) {
    fs
        .file(path.join(control.path, entry.key))
        .writeAsStringSync(_shell(entry.value));
    executables.add(path.join(control.path, entry.key));
  }
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
