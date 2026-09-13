import 'test_filesystem.dart';

import 'dart:typed_data';

import 'package:cadence_media/cadence_media.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:test/test.dart'
    hide test, setUp, tearDown, setUpAll, tearDownAll, addTearDown;

import 'fixtures.dart';

/// The identity hash computed the plain way: one digest over the bytes
/// the sampled hash is defined over, then the length.
String reference(List<int> bytes, {int span = sampledSpan}) {
  final size = ByteData(8)..setUint64(0, bytes.length, Endian.little);
  final covered = bytes.length <= 2 * span
      ? bytes
      : [...bytes.sublist(0, span), ...bytes.sublist(bytes.length - span)];
  return crypto.sha256.convert([
    ...covered,
    ...size.buffer.asUint8List(),
  ]).toString();
}

void main() => memoryTests(registerTests);
void registerTests() {
  group('sampledSha256OfFile', () {
    late String dir;
    setUp(() {
      dir = mediaFileSystem.systemTempDirectory
          .createTempSync('cadence_hasher')
          .path;
    });
    tearDown(() => mediaFileSystem.directory(dir).deleteSync(recursive: true));

    String write(String name, List<int> bytes) {
      final file = mediaFileSystem.file(p.join(dir, name))
        ..writeAsBytesSync(bytes);
      return file.path;
    }

    test('a small file is hashed whole, with its length', () async {
      for (final path in [
        Fixtures.tinyPng,
        Fixtures.id3v23Mp3,
        Fixtures.infoPdf,
      ]) {
        final bytes = mediaFileSystem.file(path).readAsBytesSync();
        expect(bytes.length, lessThanOrEqualTo(2 * sampledSpan), reason: path);
        expect(await sampledSha256OfFile(path), reference(bytes), reason: path);
      }
    });

    test('the length tells two files of the same head apart', () async {
      final abc = write('abc', 'abc'.codeUnits);
      final padded = write('abc0', [...'abc'.codeUnits, 0]);
      expect(
        await sampledSha256OfFile(abc),
        isNot(await sampledSha256OfFile(padded)),
      );
    });

    test('a large file is hashed by its ends and its length', () async {
      final bytes = List<int>.generate(
        3 * sampledSpan + 12345,
        (i) => (i * 31 + 7) & 0xff,
      );
      final path = write('big.bin', bytes);
      expect(await sampledSha256OfFile(path), reference(bytes));
    });

    test(
      'a change between the spans is invisible; at an end it is not',
      () async {
        final bytes = List<int>.generate(
          3 * sampledSpan,
          (i) => (i * 7) & 0xff,
        );
        final path = write('big.bin', bytes);
        final before = await sampledSha256OfFile(path);

        bytes[bytes.length ~/ 2] ^= 0xff;
        write('big.bin', bytes);
        expect(await sampledSha256OfFile(path), before);

        bytes[bytes.length - 1] ^= 0xff;
        write('big.bin', bytes);
        expect(await sampledSha256OfFile(path), isNot(before));
      },
    );

    test('the span is a parameter, and the reads fall where it says', () async {
      final bytes = List<int>.generate(100, (i) => i);
      final path = write('hundred.bin', bytes);
      expect(
        await sampledSha256OfFile(path, span: 10),
        reference(bytes, span: 10),
      );
      expect(
        await sampledSha256OfFile(path, span: 10),
        isNot(await sampledSha256OfFile(path)),
      );
    });

    test('the empty file hashes to the digest of its length alone', () async {
      final path = write('empty', const []);
      expect(await sampledSha256OfFile(path), reference(const []));
    });
  });
}
