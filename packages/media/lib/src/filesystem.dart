import 'dart:async';
import 'package:file/file.dart';
import 'package:path/path.dart' as paths;
export 'package:file/file.dart';

final _fileSystemKey = Object();

/// Binds a filesystem for a complete asynchronous service operation.
/// No ambient host filesystem fallback exists. Child futures inherit the scope.
T withMediaFileSystem<T>(FileSystem fileSystem, T Function() action) =>
    runZoned(action, zoneValues: {_fileSystemKey: fileSystem});
FileSystem get mediaFileSystem =>
    Zone.current[_fileSystemKey] as FileSystem? ??
    (throw StateError(
      'A media FileSystem must be injected with withMediaFileSystem',
    ));
paths.Context get mediaPath => mediaFileSystem.path;
