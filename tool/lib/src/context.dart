import 'package:file/file.dart';
import 'package:path/path.dart' as p;

/// Processes are a platform capability, separately injected from the filesystem.
abstract interface class ProcessRunner {
  Future<int> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
  });
}

class ToolFailure implements Exception {
  ToolFailure(this.message, [this.exitCode = 1]);
  final String message;
  final int exitCode;
  @override
  String toString() => message;
}

class ToolContext {
  ToolContext({
    required this.fileSystem,
    required this.root,
    required this.processes,
    required this.dartExecutable,
    required this.write,
  });
  final FileSystem fileSystem;
  final String root;
  final ProcessRunner processes;
  final String dartExecutable;
  final void Function(String) write;
  p.Context get path => fileSystem.path;
  String at(String relative) =>
      path.normalize(path.join(root, path.joinAll(relative.split('/'))));
  Future<void> run(
    String executable,
    List<String> arguments, {
    String directory = '',
  }) async {
    final code = await processes.run(
      executable,
      arguments,
      workingDirectory: at(directory),
    );
    if (code != 0) throw ToolFailure('$executable failed (exit $code)', code);
  }
}
