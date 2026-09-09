import '../filesystem.dart';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:dart_pdf_reader/dart_pdf_reader_io.dart';
import 'package:epub_plus/epub_plus.dart';

import 'package:xml/xml.dart';

import '../kinds.dart';
import '../metadata.dart';
import 'extractor.dart';
import 'image_extractor.dart';

/// Document metadata and artwork extraction. Content fingerprints are reserved
/// for a future implementation; chapter/PDF text is not read for hashing.
class DocumentExtractor implements MetadataExtractor {
  const DocumentExtractor({this.fileSystem});
  final FileSystem? fileSystem;

  static const _extensions = {'pdf', 'epub', 'txt', 'cbz'};

  @override
  bool handles(MediaKind kind, String extension) =>
      kind == MediaKind.document && _extensions.contains(extension);

  @override
  Future<ExtractionResult?> extract(String path, MediaKind kind) =>
      withMediaFileSystem(
        fileSystem ?? mediaFileSystem,
        () => _extractScoped(path, kind),
      );

  Future<ExtractionResult?> _extractScoped(String path, MediaKind kind) =>
      switch (mediaPath.extension(path).toLowerCase()) {
        '.pdf' => _pdf(path),
        '.epub' => _epub(path),
        '.txt' => _txt(path),
        '.cbz' => _cbz(path),
        _ => Future.value(),
      };

  Future<ExtractionResult?> _pdf(String path) async {
    RandomAccessFile? file;
    try {
      file = await mediaFileSystem.file(path).open();
      final doc = await PDFParser(
        BufferedRandomAccessStream(FileStream(file)),
      ).parse();
      final info = await doc.resolve<PDFDictionary>(
        doc.mainTrailer[PDFNames.info],
      );
      Future<String?> read(PDFName name) async =>
          (await doc.resolve<PDFStringLike>(info?[name]))?.asString();
      final title = await read(PDFNames.title);
      final author = await read(PDFNames.author);
      final subject = await read(PDFNames.subject);
      final extra = <String, Object?>{};
      if (info != null) {
        for (final MapEntry(:key, :value) in info.entries.entries) {
          if (key == PDFNames.title ||
              key == PDFNames.author ||
              key == PDFNames.subject) {
            continue;
          }
          final resolved = await doc.resolve<PDFObject>(value);
          if (resolved is! PDFStringLike) continue;
          final text = resolved.asString();
          final isDate =
              key == PDFNames.creationDate || key == PDFNames.modDate;
          extra[key.value] = isDate ? (_pdfDate(text) ?? text) : text;
        }
      }
      final pages = await (await doc.catalog).getPages();
      return ExtractionResult(
        metadata: DocumentMetadata(
          title: title ?? '',
          author: author,
          authors: [?author],
          description: subject,
          pageCount: pages.pageCount,
          extra: extra,
        ),
      );
    } catch (_) {
      return null;
    } finally {
      await file?.close();
    }
  }

  Future<ExtractionResult?> _epub(String path) async {
    try {
      final book = await EpubReader.openBook(
        mediaFileSystem.file(path).readAsBytes(),
      );
      final metadata = book.schema?.package?.metadata;
      final authors = [
        for (final name in book.authors)
          if (name.isNotEmpty) name,
      ];
      final extra = <String, Object?>{};
      final date = metadata?.dates.firstOrNull?.date;
      if (date != null && date.isNotEmpty) extra['dc:date'] = date;
      final subjects = metadata?.subjects ?? const [];
      if (subjects.isNotEmpty) extra['dc:subject'] = subjects;
      return ExtractionResult(
        metadata: DocumentMetadata(
          title: book.title ?? '',
          author: authors.firstOrNull,
          authors: authors,
          language: _first(metadata?.languages),
          publisher: _first(metadata?.publishers),
          isbn: _isbnOf([
            for (final identifier in metadata?.identifiers ?? const [])
              ?identifier.identifier,
          ]),
          description: metadata?.description,
          extra: extra,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// A comic archive: a zip of pages, with a `ComicInfo.xml` when the
  /// curator cared. Pages are counted by image entries; the first page in
  /// name order becomes the cover thumbnail. cbr (rar) stays outside this
  /// tier — no permissive pure-Dart unrar exists.
  Future<ExtractionResult?> _cbz(String path) async {
    final Archive zip;
    try {
      zip = ZipDecoder().decodeBytes(
        await mediaFileSystem.file(path).readAsBytes(),
      );
    } catch (_) {
      return null;
    }

    const pageExtensions = {'.jpg', '.jpeg', '.png', '.webp', '.gif'};
    final pages =
        zip.files
            .where(
              (f) =>
                  f.isFile &&
                  pageExtensions.contains(
                    mediaPath.extension(f.name).toLowerCase(),
                  ),
            )
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));

    String? title;
    String? series;
    double? issueNumber;
    String? writer;
    String? publisher;
    String? language;
    String? description;
    int? declaredPages;
    final extra = <String, Object?>{};
    final info = zip.files
        .where((f) => f.isFile && f.name.toLowerCase() == 'comicinfo.xml')
        .firstOrNull;
    // No pages and no ComicInfo: nothing was learned — abstain, and the
    // facade's filename fallback serves. (A truncated zip reads as this.)
    if (pages.isEmpty && info == null) return null;
    if (info != null) {
      try {
        final doc = XmlDocument.parse(utf8.decode(info.content));
        for (final node in doc.rootElement.childElements) {
          final text = node.innerText.trim();
          if (text.isEmpty) continue;
          switch (node.name.local) {
            case 'Title':
              title = text;
            case 'Series':
              series = text;
            case 'Number':
              issueNumber = double.tryParse(text);
            case 'Writer':
              writer = text;
            case 'Publisher':
              publisher = text;
            case 'LanguageISO':
              language = text;
            case 'Summary':
              description = text;
            case 'PageCount':
              declaredPages = int.tryParse(text);
            default:
              extra[node.name.local] = text;
          }
        }
      } catch (_) {
        // A garbled ComicInfo is no reason to drop the pages.
      }
    }

    ExtractedArtwork? cover;
    if (pages.isNotEmpty) {
      try {
        cover = renderThumbnail(pages.first.content);
      } catch (_) {
        cover = null;
      }
    }

    return ExtractionResult(
      metadata: DocumentMetadata(
        title: title ?? '',
        author: writer,
        authors: [?writer],
        language: language,
        publisher: publisher,
        description: description,
        pageCount: pages.isEmpty ? declaredPages : pages.length,
        series: series,
        issueNumber: issueNumber,
        extra: extra,
      ),
      artwork: [?cover],
    );
  }

  Future<ExtractionResult?> _txt(String path) async => ExtractionResult(
    metadata: DocumentMetadata(title: mediaPath.basenameWithoutExtension(path)),
  );

  String? _first(List<String>? values) =>
      values?.where((value) => value.isNotEmpty).firstOrNull;

  /// An identifier smells like an ISBN when, stripped of its `urn:isbn:`
  /// dress and its hyphens, ten or thirteen digits remain — a trailing X
  /// welcome in the old ten-digit style.
  String? _isbnOf(Iterable<String> identifiers) {
    for (final raw in identifiers) {
      final cleaned = raw
          .trim()
          .toLowerCase()
          .replaceFirst(RegExp(r'^urn:isbn:'), '')
          .replaceFirst(RegExp(r'^isbn[:\s]*'), '')
          .replaceAll(RegExp(r'[-\s]'), '');
      if (RegExp(r'^\d{13}$').hasMatch(cleaned) ||
          RegExp(r'^\d{9}[\dx]$').hasMatch(cleaned)) {
        return cleaned.toUpperCase();
      }
    }
    return null;
  }

  /// PDF dates arrive as `D:YYYYMMDDHHmmSS` with an optional `Z` or
  /// `±HH'mm'` tail. This rewrites them as ISO-8601, keeping only the
  /// parts that were written; anything less than a year is not a date.
  String? _pdfDate(String raw) {
    final match = RegExp(
      r"^D:(\d{4})(\d{2})?(\d{2})?(\d{2})?(\d{2})?(\d{2})?"
      r"(?:(Z)|([+\-])(\d{2})(?:'(\d{2})'?)?)?$",
    ).firstMatch(raw.trim());
    if (match == null) return null;
    final out = StringBuffer(match[1]!);
    if (match[2] != null) out.write('-${match[2]}');
    if (match[3] != null) out.write('-${match[3]}');
    if (match[4] != null) {
      out.write('T${match[4]}:${match[5] ?? '00'}');
      if (match[6] != null) out.write(':${match[6]}');
      if (match[7] != null) {
        out.write('Z');
      } else if (match[8] != null) {
        out.write('${match[8]}${match[9]}:${match[10] ?? '00'}');
      }
    }
    return out.toString();
  }
}
