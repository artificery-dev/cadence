import 'package:test/test.dart' as t;
import 'dart:io' as io;
import 'package:file/memory.dart';
import 'package:cadence_media/src/filesystem.dart';

late FileSystem testFileSystem;
void memoryTests(void Function() register) {
  final fs = MemoryFileSystem.test();
  final candidates = ['test/fixtures', 'packages/media/test/fixtures'];
  final source = candidates
      .map(io.Directory.new)
      .firstWhere((d) => d.existsSync());
  fs.directory('/test/fixtures').createSync(recursive: true);
  for (final file in source.listSync(recursive: true).whereType<io.File>()) {
    final relative = file.path.substring(source.path.length + 1);
    fs.file('/test/fixtures/$relative')
      ..createSync(recursive: true)
      ..writeAsBytesSync(file.readAsBytesSync());
  }
  testFileSystem = fs;
  withMediaFileSystem(fs, register);
}

void test(
  String name,
  dynamic Function() body, {
  dynamic skip,
  dynamic tags,
  t.Timeout? timeout,
  int? retry,
  dynamic onPlatform,
  String? testOn,
}) => t.test(
  name,
  () => withMediaFileSystem(testFileSystem, body),
  skip: skip,
  tags: tags,
  timeout: timeout,
  retry: retry,
  onPlatform: onPlatform,
  testOn: testOn,
);
void setUp(dynamic Function() body) =>
    t.setUp(() => withMediaFileSystem(testFileSystem, body));
void tearDown(dynamic Function() body) =>
    t.tearDown(() => withMediaFileSystem(testFileSystem, body));
void setUpAll(dynamic Function() body) =>
    t.setUpAll(() => withMediaFileSystem(testFileSystem, body));
void tearDownAll(dynamic Function() body) =>
    t.tearDownAll(() => withMediaFileSystem(testFileSystem, body));
void addTearDown(dynamic Function() body) =>
    t.addTearDown(() => withMediaFileSystem(testFileSystem, body));
