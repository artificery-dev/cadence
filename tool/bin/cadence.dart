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
  }) async {
    final process = await io.Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      mode: io.ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }
}

Future<void> main(List<String> arguments) async {
  const fs = LocalFileSystem();
  final context = ToolContext(
    fileSystem: fs,
    root: fs.path.normalize(
      fs.path.join(
        fs.path.dirname(io.Platform.script.toFilePath()),
        '..',
        '..',
      ),
    ),
    processes: LocalProcesses(),
    dartExecutable: io.Platform.resolvedExecutable,
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
