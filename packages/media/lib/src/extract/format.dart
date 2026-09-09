import '../filesystem.dart';
import 'package:mime/mime.dart' show MimeTypeResolver;

import '../kinds.dart';

/// What kind of media a path names.
///
/// The extension answers first. When [headerBytes] ride along, the file's
/// own bytes get the casting vote: an MP3 wearing `.txt` is still audio, a
/// BMP renamed `.mp3` is still an image. A few dozen bytes are plenty —
/// every signature we read, the EBML DocType included, lives well inside
/// the first 64.
///
/// Most signatures come from `package:mime`'s table, topped up with what it
/// lacks (BMP, AVI, a working Ogg entry, bare MPEG frame syncs). Two
/// families need more than a prefix: ISO-BMFF splits audio from video from
/// image by its `ftyp` brand, and EBML splits mkv from webm from mka by
/// its DocType — both are sniffed by hand.
MediaKind? classify(String path, {List<int>? headerBytes}) {
  final byExtension = _kindsByExtension[extensionOf(path)];
  if (headerBytes == null || headerBytes.isEmpty) return byExtension;
  return _sniff(headerBytes, byExtension) ?? byExtension;
}

/// The `format/…` tag name for a path: the extension, lowercased and
/// normalised (`jpeg` → `jpg`, `tif` → `tiff`, `aif` → `aiff`).
String formatTag(String path) => switch (extensionOf(path)) {
  'jpeg' => 'jpg',
  'tif' => 'tiff',
  'aif' => 'aiff',
  final ext => ext,
};

/// The extension, bare and lowercased — `mp3`, never `.MP3`.
String extensionOf(String path) {
  final ext = mediaPath.extension(path);
  return ext.isEmpty ? '' : ext.substring(1).toLowerCase();
}

/// What the bytes say the file is, or null when they say nothing we know.
MediaKind? _sniff(List<int> header, MediaKind? byExtension) {
  if (_startsWith(header, const [0x1a, 0x45, 0xdf, 0xa3])) {
    return _classifyEbml(header, byExtension);
  }
  if (_isFtyp(header)) return _classifyFtyp(header, byExtension);
  final mime = _resolver.lookup('', headerBytes: header);
  return mime == null ? null : _kindOfMime(mime);
}

MediaKind? _kindOfMime(String mime) {
  if (mime.startsWith('audio/')) return MediaKind.audio;
  if (mime.startsWith('video/')) return MediaKind.video;
  if (mime.startsWith('image/')) return MediaKind.image;
  if (mime == 'application/pdf') return MediaKind.document;
  return null;
}

/// EBML: the magic says Matroska-family, the DocType says which member.
/// `webm` is video by definition; `matroska` covers both mkv and mka, so
/// an audio extension keeps its word and everything else plays as video.
MediaKind _classifyEbml(List<int> header, MediaKind? byExtension) {
  final docType = _ebmlDocType(header);
  if (docType == 'webm') return MediaKind.video;
  if (docType == 'matroska') {
    return byExtension == MediaKind.audio ? MediaKind.audio : MediaKind.video;
  }
  return byExtension ?? MediaKind.video;
}

/// Finds the DocType string in an EBML header without a full parse: scan
/// for the element id `42 82`, take the one-byte size vint after it, and
/// keep the string only if it names a DocType we know — anything else was
/// a coincidence in a size field, so the scan walks on.
String? _ebmlDocType(List<int> header) {
  for (var i = 4; i + 3 < header.length; i++) {
    if (header[i] != 0x42 || header[i + 1] != 0x82) continue;
    final sizeByte = header[i + 2];
    if (sizeByte & 0x80 == 0) continue;
    final length = sizeByte & 0x7f;
    final end = i + 3 + length;
    if (end > header.length) continue;
    final docType = String.fromCharCodes(header.sublist(i + 3, end));
    if (docType == 'matroska' || docType == 'webm') return docType;
  }
  return null;
}

bool _isFtyp(List<int> header) =>
    header.length >= 12 &&
    header[4] == 0x66 &&
    header[5] == 0x74 &&
    header[6] == 0x79 &&
    header[7] == 0x70;

/// ISO-BMFF: the `ftyp` major brand decides. `M4A`/`M4B`/`M4P` are audio,
/// the HEIF family is stills, and the generic brands (isom, mp42, qt…)
/// could hold either — there an audio extension is believed, since m4a
/// files are legitimately written under generic brands, and everything
/// else plays as video.
MediaKind _classifyFtyp(List<int> header, MediaKind? byExtension) {
  final brand = String.fromCharCodes(header.sublist(8, 12)).trimRight();
  if (const {'M4A', 'M4B', 'M4P'}.contains(brand)) return MediaKind.audio;
  if (const {
    'heic',
    'heix',
    'heim',
    'heis',
    'hevc',
    'hevm',
    'hevs',
    'mif1',
    'msf1',
    'avif',
    'avis',
  }.contains(brand)) {
    return MediaKind.image;
  }
  return byExtension == MediaKind.audio ? MediaKind.audio : MediaKind.video;
}

bool _startsWith(List<int> header, List<int> prefix) {
  if (header.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (header[i] != prefix[i]) return false;
  }
  return true;
}

/// `package:mime`'s table plus what it lacks: BMP (`BM` with the reserved
/// zeros checked, since two bytes alone prove little), AVI's RIFF form,
/// a correct Ogg capture (`OggS` — the stock entry misspells it), and the
/// bare MPEG frame syncs for MP3s without an ID3 header (which the stock
/// table already covers).
final MimeTypeResolver _resolver = MimeTypeResolver()
  ..addMagicNumber(
    const [0x42, 0x4d, 0, 0, 0, 0, 0, 0, 0, 0],
    'image/bmp',
    mask: const [0xff, 0xff, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff],
  )
  ..addMagicNumber(
    const [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x41, 0x56, 0x49, 0x20],
    'video/x-msvideo',
    mask: const [
      0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, //
    ],
  )
  ..addMagicNumber(const [0x4f, 0x67, 0x67, 0x53], 'audio/ogg')
  ..addMagicNumber(const [0xff, 0xfa], 'audio/mpeg')
  ..addMagicNumber(const [0xff, 0xf3], 'audio/mpeg')
  ..addMagicNumber(const [0xff, 0xf2], 'audio/mpeg');

const Map<String, MediaKind> _kindsByExtension = {
  'mp3': MediaKind.audio,
  'flac': MediaKind.audio,
  'ogg': MediaKind.audio,
  'oga': MediaKind.audio,
  'opus': MediaKind.audio,
  'm4a': MediaKind.audio,
  'm4b': MediaKind.audio,
  'aac': MediaKind.audio,
  'wav': MediaKind.audio,
  'aiff': MediaKind.audio,
  'aif': MediaKind.audio,
  'ape': MediaKind.audio,
  'wv': MediaKind.audio,
  'wma': MediaKind.audio,
  'mka': MediaKind.audio,
  'mp4': MediaKind.video,
  'm4v': MediaKind.video,
  'mov': MediaKind.video,
  'mkv': MediaKind.video,
  'webm': MediaKind.video,
  'avi': MediaKind.video,
  'jpg': MediaKind.image,
  'jpeg': MediaKind.image,
  'png': MediaKind.image,
  'gif': MediaKind.image,
  'webp': MediaKind.image,
  'bmp': MediaKind.image,
  'tif': MediaKind.image,
  'tiff': MediaKind.image,
  'heic': MediaKind.image,
  'heif': MediaKind.image,
  'avif': MediaKind.image,
  'pdf': MediaKind.document,
  'epub': MediaKind.document,
  'cbz': MediaKind.document,
  'cbr': MediaKind.document,
  'txt': MediaKind.document,
};
