import 'package:liquify/liquify.dart';
import 'package:path/path.dart' as p;
import 'context.dart';

String systemdExecutable(String value) {
  // The target is Linux even when the packager runs on another host.
  if (!p.posix.isAbsolute(value) ||
      value.codeUnits.any((c) => c < 32 || c == 127)) {
    throw ToolFailure(
      'executable must be an absolute Linux path without control characters',
      64,
    );
  }
  return '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('%', '%%').replaceAll(r'$', r'$$')}"';
}

Future<void> renderSystemd(
  ToolContext context, {
  required String scope,
  required String executable,
  required String output,
  String name = 'cadence',
  String? user,
  String? group,
  String? volume,
}) async {
  if (!['system', 'user'].contains(scope) ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name)) {
    throw ToolFailure('Invalid service scope or directory name', 64);
  }
  if (scope == 'system') {
    for (final account in [user, group]) {
      if (account == null ||
          !RegExp(r'^[A-Za-z_][A-Za-z0-9_-]*$').hasMatch(account)) {
        throw ToolFailure(
          'System units require valid --service-user and --service-group',
          64,
        );
      }
    }
  } else if (user != null || group != null) {
    throw ToolFailure(
      'User units run as the user manager owner; omit service accounts',
      64,
    );
  }
  final source = await context.fileSystem
      .file(
        context.at('daemon/packaging/systemd/cadenced.$scope.service.liquid'),
      )
      .readAsString();
  final rendered = Template.parse(
    source,
    data: {
      'executable': systemdExecutable(executable),
      'name': name,
      'volume': volume == null ? '' : systemdExecutable(volume),
      'service_user': user ?? '',
      'service_group': group ?? '',
    },
  ).render();
  final destination = context.fileSystem.file(output);
  await destination.parent.create(recursive: true);
  await destination.writeAsString(rendered);
  context.write('Rendered ${destination.path}');
}
