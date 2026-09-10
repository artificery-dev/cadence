import 'dart:io' as io;
import 'package:args/command_runner.dart';
import 'package:file/local.dart';
import 'package:cadence_tool/cli.dart';
import 'package:cadence_tool/src/demo.dart';

class LocalProcesses implements ProcessRunner {
  @override
  Future<int> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    Map<String, String>? environment,
  }) async {
    final process = await io.Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      mode: io.ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }
}

/// The workspace root: `CADENCE_ROOT` when set, the checkout this source
/// lives in when run from source, and otherwise the current directory — the
/// toolchain image ships this tool AOT-compiled and runs it from the
/// checkout.
String workspaceRoot(LocalFileSystem fs) {
  final override = io.Platform.environment['CADENCE_ROOT'];
  if (override != null && override.isNotEmpty)
    return fs.path.absolute(override);
  final script = io.Platform.script;
  if (script.isScheme('file') && script.path.endsWith('.dart')) {
    return fs.path.normalize(
      fs.path.join(fs.path.dirname(script.toFilePath()), '..', '..'),
    );
  }
  return fs.currentDirectory.path;
}

/// The Dart SDK to drive: `CADENCE_DART` when set, this process when it is
/// the VM (`dart run`), and otherwise `dart` from PATH for the AOT build.
String dartExecutable() {
  final override = io.Platform.environment['CADENCE_DART'];
  if (override != null && override.isNotEmpty) return override;
  final self = io.Platform.resolvedExecutable;
  final name = self.split(io.Platform.pathSeparator).last;
  return name == 'dart' || name == 'dart.exe' ? self : 'dart';
}

Future<void> main(List<String> arguments) async {
  const fs = LocalFileSystem();
  final context = ToolContext(
    fileSystem: fs,
    root: workspaceRoot(fs),
    processes: LocalProcesses(),
    dartExecutable: dartExecutable(),
    write: io.stdout.writeln,
  );
  try {
    await CadenceTool(
      context,
      demo: (executable) => runDemo(
        context,
        executable == null ? null : fs.path.absolute(executable),
      ),
    ).run(arguments);
  } on UsageException catch (error) {
    io.stderr.writeln(error);
    io.exitCode = 64;
  } on ToolFailure catch (error) {
    io.stderr.writeln(error);
    io.exitCode = error.exitCode;
  } catch (error) {
    io.stderr.writeln(error);
    io.exitCode = 1;
  }
}
