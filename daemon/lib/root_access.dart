import 'package:file/file.dart';

/// An observation is scoped to one configured root. mountPath/mountId identify
/// a removable mount independently of a (possibly absent) media subdirectory.
class RootObservation {
  const RootObservation(
    this.rootId,
    this.path,
    this.available, {
    this.mountPath,
    this.mountId,
    this.sourceId,
  });
  final int rootId;
  final String path;
  final bool available;
  final String? mountPath, mountId, sourceId;
}

abstract interface class RootLease {
  String get mountPath;
  bool get available;
  FileSystem get fileSystem;
  void close();
}

/// Called only after all prior filesystem work has drained. False observations
/// revoke access; true removable observations acquire verified, pinned leases.
abstract interface class RootAccessAdapter {
  void configureRoots(List<RootObservation> roots);
  bool rootAvailable(String path);
}
