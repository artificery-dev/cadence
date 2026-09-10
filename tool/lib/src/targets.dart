import 'context.dart';

/// A Linux build target, named the Debian way so packages, bundles and the
/// CI matrix all agree on one vocabulary.
enum LinuxTarget {
  amd64('x64', 'x86_64-unknown-linux-gnu', null),
  arm64('arm64', 'aarch64-unknown-linux-gnu', 'aarch64-linux-gnu-gcc'),
  armhf('arm', 'armv7-unknown-linux-gnueabihf', 'arm-linux-gnueabihf-gcc');

  const LinuxTarget(this.dartArch, this.rustTriple, this.crossLinker);

  /// The `--target-arch` value `dart build cli` understands.
  final String dartArch;

  /// The Rust target triple Cargo builds the probe for.
  final String rustTriple;

  /// The GNU cross linker Cargo needs on an x86-64 build host, or null when
  /// the host toolchain links the target natively.
  final String? crossLinker;

  static List<String> get names => [for (final t in values) t.name];

  static LinuxTarget parse(String name) => values.firstWhere(
    (t) => t.name == name,
    orElse: () => throw ToolFailure('Unknown architecture: $name', 64),
  );
}
