import 'test_filesystem.dart';
import 'dart:convert';
import 'package:cadence_media/src/filesystem.dart';

import 'package:cadence_media/src/extract/document_extractor.dart';
import 'package:cadence_media/src/extract/extractor.dart';
import 'package:cadence_media/src/extract/simhash.dart';
import 'package:cadence_media/src/kinds.dart';
import 'package:cadence_media/src/metadata.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart'
    hide test, setUp, tearDown, setUpAll, tearDownAll, addTearDown;

import 'fixtures.dart';

/// The document tier's contract: PDFs surrender their Info dict and page
/// count, EPUBs their OPF metadata and a text simhash, text files their
/// filename — and the pinned SimHash algorithm reproduces its published
/// vectors bit for bit.
void main() => memoryTests(registerTests);
void registerTests() {
  const extractor = DocumentExtractor();

  group('handles', () {
    test('claims documents by extension, nothing else', () {
      expect(extractor.handles(MediaKind.document, 'pdf'), isTrue);
      expect(extractor.handles(MediaKind.document, 'epub'), isTrue);
      expect(extractor.handles(MediaKind.document, 'txt'), isTrue);
      expect(extractor.handles(MediaKind.document, 'cbz'), isTrue);
      expect(extractor.handles(MediaKind.document, 'docx'), isFalse);
      expect(extractor.handles(MediaKind.audio, 'mp3'), isFalse);
      expect(extractor.handles(MediaKind.image, 'pdf'), isFalse);
    });
  });

  group('info.pdf', () {
    test('reads the Info dictionary and counts the page', () async {
      final result = await extractor.extract(
        Fixtures.infoPdf,
        MediaKind.document,
      );
      final metadata = result!.metadata as DocumentMetadata;

      expect(metadata.title, 'Fixture Document');
      expect(metadata.author, 'Cadence Fixtures');
      expect(metadata.authors, ['Cadence Fixtures']);
      expect(metadata.pageCount, 1);
      expect(metadata.extra['Producer'], 'make_fixtures.sh');
      expect(metadata.extra['CreationDate'], '2020-05-17T10:30:00Z');
    });

    test('computes no simhash — that ground belongs to the probe', () async {
      final result = await extractor.extract(
        Fixtures.infoPdf,
        MediaKind.document,
      );
      expect(result!.hashes, isEmpty);
    });

    test('a malformed PDF degrades to null', () async {
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_doc_test',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final broken = mediaFileSystem.file(p.join(dir.path, 'broken.pdf'))
        ..writeAsStringSync('%PDF-1.4 except not really');

      expect(await extractor.extract(broken.path, MediaKind.document), isNull);
    });

    test('so the facade serves the filename as title', () async {
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_doc_test',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final broken = mediaFileSystem.file(
        p.join(dir.path, 'Scanned Receipts.pdf'),
      )..writeAsStringSync('nothing a parser could love');

      final result = await const MediaExtractor([
        DocumentExtractor(),
      ]).extract(broken.path, MediaKind.document);
      expect((result.metadata as DocumentMetadata).title, 'Scanned Receipts');
    });
  });

  group('book.epub', () {
    test('reads the OPF metadata', () async {
      final result = await extractor.extract(
        Fixtures.bookEpub,
        MediaKind.document,
      );
      final metadata = result!.metadata as DocumentMetadata;

      expect(metadata.title, 'The Fixture Book');
      expect(metadata.author, 'Cadence Fixtures');
      expect(metadata.authors, ['Cadence Fixtures']);
      expect(metadata.language, 'en');
      expect(metadata.publisher, 'Fixture Press');
      expect(metadata.isbn, '9780306406157');
      expect(
        metadata.description,
        'A very small book that exists to be read by machines.',
      );
      expect(metadata.extra['dc:date'], '2020-05-17');
    });

    test('hashes the chapter prose, tags stripped', () async {
      final result = await extractor.extract(
        Fixtures.bookEpub,
        MediaKind.document,
      );
      const prose =
          'Chapter One Chapter One The fixture book opens, as all fixture '
          'books must, with a paragraph that exists so a simhash has '
          'something to shingle. It is short, it is plain, and it repeats '
          'itself just enough to be recognisable when a test rewords it '
          'slightly. The fixture book closes, as all fixture books must, '
          'one paragraph later.';
      expect(result!.hashes[HashKind.textSimhash], simHash(prose));
    });
  });

  group('notes.txt', () {
    test(
      'takes its title from the filename and its hash from the words',
      () async {
        final result = await extractor.extract(
          Fixtures.notesTxt,
          MediaKind.document,
        );
        final metadata = result!.metadata as DocumentMetadata;

        expect(metadata.title, 'notes');
        expect(
          result.hashes[HashKind.textSimhash],
          simHash(mediaFileSystem.file(Fixtures.notesTxt).readAsStringSync()),
        );
      },
    );
  });

  group('issue.cbz', () {
    test('reads ComicInfo, counts pages, and lifts a cover', () async {
      final result = await extractor.extract(
        Fixtures.issueCbz,
        MediaKind.document,
      );
      final meta = result!.metadata as DocumentMetadata;
      expect(meta.title, 'The Test Card Menace');
      expect(meta.series, 'Fixture Comics');
      expect(meta.issueNumber, 12.5);
      expect(meta.author, 'Ray Cathode');
      expect(meta.publisher, 'Bitrate Press');
      expect(meta.language, 'en');
      expect(meta.description, 'Two blank pages of pure signal.');
      // Counted from the entries themselves, not the declaration.
      expect(meta.pageCount, 2);
      expect(meta.extra['Genre'], 'Test Pattern');
      // The first page becomes the cover thumbnail.
      expect(result.artwork, hasLength(1));
      expect(result.artwork.single.mime, 'image/jpeg');
      expect(result.artwork.single.bytes, isNotEmpty);
    });

    test('a broken zip degrades to null', () async {
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_cbz',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final bad = mediaFileSystem.file('${dir.path}/bad.cbz')
        ..writeAsBytesSync([0x50, 0x4b, 1, 2, 3]);
      expect(await extractor.extract(bad.path, MediaKind.document), isNull);
    });
  });

  group('simhash', () {
    const notes = '''
Notes on the fixture corpus.

Plain text is the humblest document format: no metadata, no structure, just
words. An extractor meeting this file should take its title from the
filename and its simhash from these very sentences, which exist so a test
can reword them slightly and measure how little the hash moves.
''';
    const notesReworded = '''
Notes on the fixture corpus.

Plain text is the humblest document format: no metadata, no structure, only
words. An extractor reading this file should take its title from the
filename and its simhash from these very sentences, which exist so a test
can reword them slightly and see how little the hash moves.
''';
    const unrelated =
        'Meanwhile, in an entirely different register, a weather system '
        'crossed the mountains overnight, dropping snow on the passes and '
        'closing two of the three roads into the valley before dawn.';

    test('punctuation and case wash out in normalization', () {
      expect(simHash('Hello,   World! Foo'), simHash('hello world foo'));
      expect(simHash('café — naïve'), simHash('caf na ve'));
    });

    test('nothing left after normalization pins to the FNV offset basis', () {
      expect(simHash(''), 'cbf29ce484222325');
      expect(simHash('—— ··· ¡¿!?'), simHash(''));
    });

    test('reworded prose stays close', () {
      final distance = hammingDistance(simHash(notes), simHash(notesReworded));
      expect(distance, lessThanOrEqualTo(12));
    });

    test('unrelated prose lands far apart', () {
      final distance = hammingDistance(simHash(notes), simHash(unrelated));
      expect(distance, greaterThanOrEqualTo(20));
    });

    test('hamming distance counts bits, not characters', () {
      expect(hammingDistance('cbf29ce484222325', 'cbf29ce484222325'), 0);
      expect(hammingDistance('0000000000000000', 'ffffffffffffffff'), 64);
      expect(hammingDistance('0000000000000001', '0000000000000003'), 1);
    });

    test('the published vectors reproduce — the cross-tier contract', () {
      final file = mediaFileSystem.file(
        p.join(Fixtures.root, 'simhash_vectors.json'),
      );
      final vectors = (jsonDecode(file.readAsStringSync()) as List)
          .cast<Map<String, Object?>>();

      expect(vectors, hasLength(6));
      for (final vector in vectors) {
        expect(
          simHash(vector['text']! as String),
          vector['hashHex'],
          reason: 'vector: ${vector['text']}',
        );
      }
    });
  });

  group('corrupt input', () {
    test('every format cut at 10% and 50% answers or abstains', () async {
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_doc',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      for (final path in [
        Fixtures.infoPdf,
        Fixtures.bookEpub,
        Fixtures.notesTxt,
      ]) {
        final bytes = mediaFileSystem.file(path).readAsBytesSync();
        final name = p.basename(path);
        for (final fraction in const [0.1, 0.5]) {
          final cut = (bytes.length * fraction).round().clamp(1, bytes.length);
          final stump = p.join(dir.path, '$fraction-$name');
          mediaFileSystem.file(stump).writeAsBytesSync(bytes.sublist(0, cut));
          await expectLater(
            extractor.extract(stump, MediaKind.document),
            completes,
            reason: '$name cut at $fraction must never throw',
          );
        }
      }
    });

    test('an EPUB that is a valid zip with no OPF abstains', () async {
      // A perfectly sound archive holding only the mimetype — no
      // container.xml, no package document. Nothing to say, said quietly.
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_doc',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'no_opf.epub');
      mediaFileSystem.file(path).writeAsBytesSync(const [
        0x50, 0x4b, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x39,
        0x7a, 0x1c, 0x5d, 0x6f, 0x61, 0xab, 0x2c, 0x14, 0x00, 0x00, 0x00,
        0x14, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x6d, 0x69, 0x6d,
        0x65, 0x74, 0x79, 0x70, 0x65, 0x61, 0x70, 0x70, 0x6c, 0x69, 0x63,
        0x61, 0x74, 0x69, 0x6f, 0x6e, 0x2f, 0x65, 0x70, 0x75, 0x62, 0x2b,
        0x7a, 0x69, 0x70, 0x50, 0x4b, 0x01, 0x02, 0x14, 0x03, 0x14, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x39, 0x7a, 0x1c, 0x5d, 0x6f, 0x61, 0xab,
        0x2c, 0x14, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x08, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x6d, 0x69, 0x6d, 0x65, 0x74, 0x79,
        0x70, 0x65, 0x50, 0x4b, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x00, 0x01, 0x00, 0x36, 0x00, 0x00, 0x00, 0x3a, 0x00, 0x00, 0x00,
        0x00, 0x00, //
      ]);
      expect(await extractor.extract(path, MediaKind.document), isNull);
    });

    test('a PDF with a sound xref but no Info keeps its page count', () async {
      // Info absent is not Info malformed: the parse succeeds, the typed
      // fields stay quiet, and the facade's filename fallback serves.
      final dir = mediaFileSystem.systemTempDirectory.createTempSync(
        'cadence_doc',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final objects = <String>[
        '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n',
        '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n',
        '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 72 72] >>\n'
            'endobj\n',
      ];
      final pdf = StringBuffer('%PDF-1.4\n');
      final offsets = <int>[];
      for (final object in objects) {
        offsets.add(pdf.length);
        pdf.write(object);
      }
      final xrefAt = pdf.length;
      pdf
        ..write('xref\n0 4\n0000000000 65535 f \n')
        ..writeAll([
          for (final offset in offsets)
            '${offset.toString().padLeft(10, '0')} 00000 n \n',
        ])
        ..write('trailer\n<< /Size 4 /Root 1 0 R >>\n')
        ..write('startxref\n$xrefAt\n%%EOF\n');
      final path = p.join(dir.path, 'no_info.pdf');
      mediaFileSystem.file(path).writeAsStringSync(pdf.toString());

      final result = await extractor.extract(path, MediaKind.document);
      final metadata = result!.metadata as DocumentMetadata;
      expect(metadata.title, isEmpty);
      expect(metadata.author, isNull);
      expect(metadata.pageCount, 1);
    });
  });
}
