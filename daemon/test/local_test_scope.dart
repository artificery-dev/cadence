import 'package:file/local.dart';
import 'package:cadence_media/src/filesystem.dart';
import 'package:test/test.dart' as t;

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
  () => withMediaFileSystem(const LocalFileSystem(), body),
  skip: skip,
  tags: tags,
  timeout: timeout,
  retry: retry,
  onPlatform: onPlatform,
  testOn: testOn,
);
void setUp(dynamic Function() body) =>
    t.setUp(() => withMediaFileSystem(const LocalFileSystem(), body));
void tearDown(dynamic Function() body) =>
    t.tearDown(() => withMediaFileSystem(const LocalFileSystem(), body));
void setUpAll(dynamic Function() body) =>
    t.setUpAll(() => withMediaFileSystem(const LocalFileSystem(), body));
void tearDownAll(dynamic Function() body) =>
    t.tearDownAll(() => withMediaFileSystem(const LocalFileSystem(), body));
void addTearDown(dynamic Function() body) =>
    t.addTearDown(() => withMediaFileSystem(const LocalFileSystem(), body));
