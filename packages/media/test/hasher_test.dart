import 'test_filesystem.dart';

import 'package:cadence_media/cadence_media.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:test/test.dart'
    hide test, setUp, tearDown, setUpAll, tearDownAll, addTearDown;

import 'fixtures.dart';

void main() => memoryTests(registerTests);
void registerTests() {
  group('sha256OfFile', () {
    test('agrees with a one-shot digest over fixture bytes', () async {
      for (final path in [
        Fixtures.tinyPng,
        Fixtures.id3v23Mp3,
        Fixtures.infoPdf,
      ]) {
        final expected = crypto.sha256
            .convert(mediaFileSystem.file(path).readAsBytesSync())
            .toString();
        expect(await sha256OfFile(path), expected, reason: path);
      }
    });

    test('streams correctly across chunk boundaries', () async {
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_hasher',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final bytes = List<int>.generate(
        sha256ChunkSize * 2 + 12345,
        (i) => (i * 31 + 7) & 0xff,
      );
      final file = mediaFileSystem.file(p.join(dir.path, 'big.bin'))
        ..writeAsBytesSync(bytes);
      expect(
        await sha256OfFile(file.path),
        crypto.sha256.convert(bytes).toString(),
      );
    });

    test('a tiny chunk size changes the answer not at all', () async {
      final path = Fixtures.notesTxt;
      expect(await sha256OfFile(path, chunkSize: 7), await sha256OfFile(path));
    });

    test('the empty file hashes to the well-known digest', () async {
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_hasher',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = mediaFileSystem.file(p.join(dir.path, 'empty'))
        ..writeAsBytesSync(const []);
      expect(
        await sha256OfFile(file.path),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });
  });
}
