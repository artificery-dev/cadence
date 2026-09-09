import '../filesystem.dart';
import 'dart:convert';

import 'dart:typed_data';

/// A minimal EBML reader — just enough Matroska to read the labels.
///
/// EBML is XML's binary cousin: a file is a tree of elements, each one an
/// *id*, a *size*, and a payload that is either raw data or more elements.
/// Both id and size are variable-length integers whose first byte declares
/// its own width — count the leading zero bits, add one, that's the byte
/// count. Ids keep their marker bit and are compared whole (`0x18538067`
/// is Segment); sizes drop it. A size with every value bit set means
/// *unknown* — the element runs on until evidence of its end, which for
/// our purposes is the end of its parent. Two ids are pure plumbing and
/// appear anywhere: Void (`0xEC`, reserved space) and CRC-32 (`0xBF`);
/// [children] swallows both so callers never see them.
///
/// The reader seeks rather than slurps: walking a two-gigabyte film to
/// find its Tags element behind the clusters costs a handful of reads.
/// Nothing here throws on garbage — a header that fails to parse simply
/// ends the walk, and payload readers answer zero or empty for sizes that
/// make no sense.
class EbmlReader {
  EbmlReader(this._file) : _length = _file.lengthSync();

  final RandomAccessFile _file;
  final int _length;

  /// Whether the file opens with the EBML magic, `0x1A45DFA3`.
  bool get looksLikeEbml => elementAt(0, _length)?.id == EbmlId.header;

  /// The file's own elements: the EBML header, then (in Matroska) the
  /// Segment.
  Iterable<EbmlElement> topLevel() => children(EbmlElement(0, 0, _length));

  /// The elements inside [parent], in file order, Void and CRC-32 elided.
  ///
  /// An unknown-size child is yielded and then ends the walk — without a
  /// size there is no next sibling to find.
  Iterable<EbmlElement> children(EbmlElement parent) sync* {
    final end = parent.dataSize == null
        ? _length
        : (parent.dataOffset + parent.dataSize!).clamp(0, _length);
    var offset = parent.dataOffset;
    while (offset < end) {
      final child = elementAt(offset, end);
      if (child == null) return;
      if (child.id != EbmlId.void_ && child.id != EbmlId.crc32) yield child;
      final size = child.dataSize;
      if (size == null) return;
      offset = child.dataOffset + size;
    }
  }

  /// Parses one element header at [offset], reading no further than [end].
  /// Null when the bytes there are not an element.
  EbmlElement? elementAt(int offset, int end) {
    if (offset < 0 || offset + 2 > end) return null;
    final header = _readAt(offset, 12.clamp(0, end - offset));
    final id = _varint(header, 0, maxBytes: 4, keepMarker: true);
    if (id == null) return null;
    final size = _varint(header, id.length, maxBytes: 8, keepMarker: false);
    if (size == null) return null;
    final dataOffset = offset + id.length + size.length;
    if (size.unknown) return EbmlElement(id.value, dataOffset, null);
    final dataSize = size.value.clamp(0, end - dataOffset);
    return EbmlElement(id.value, dataOffset, dataSize);
  }

  /// The payload as a big-endian unsigned integer; 0 for absurd sizes.
  int uintOf(EbmlElement element) {
    final bytes = bytesOf(element);
    if (bytes.isEmpty || bytes.length > 8) return 0;
    var value = 0;
    for (final byte in bytes) {
      value = (value << 8) | byte;
    }
    return value;
  }

  /// The payload as an IEEE float — 4 or 8 bytes; 0 otherwise.
  double floatOf(EbmlElement element) {
    final bytes = bytesOf(element);
    return switch (bytes.length) {
      4 => ByteData.sublistView(bytes).getFloat32(0),
      8 => ByteData.sublistView(bytes).getFloat64(0),
      _ => 0,
    };
  }

  /// The payload as UTF-8 text, trailing NUL padding shorn.
  String stringOf(EbmlElement element) {
    var bytes = bytesOf(element);
    var length = bytes.length;
    while (length > 0 && bytes[length - 1] == 0) {
      length--;
    }
    return utf8.decode(bytes.sublist(0, length), allowMalformed: true);
  }

  /// The raw payload. Unknown-size elements answer empty — their bytes are
  /// elements, not data.
  Uint8List bytesOf(EbmlElement element) {
    final size = element.dataSize;
    if (size == null || size <= 0) return Uint8List(0);
    return _readAt(element.dataOffset, size);
  }

  Uint8List _readAt(int offset, int count) {
    _file.setPositionSync(offset);
    return _file.readSync(count);
  }

  ({int value, int length, bool unknown})? _varint(
    Uint8List bytes,
    int offset, {
    required int maxBytes,
    required bool keepMarker,
  }) {
    if (offset >= bytes.length) return null;
    final first = bytes[offset];
    if (first == 0) return null;
    var length = 1;
    var marker = 0x80;
    while (first & marker == 0) {
      marker >>= 1;
      length++;
    }
    if (length > maxBytes || offset + length > bytes.length) return null;
    var value = keepMarker ? first : first & (marker - 1);
    for (var i = 1; i < length; i++) {
      value = (value << 8) | bytes[offset + i];
    }
    final allOnes = keepMarker ? false : value == (1 << (7 * length)) - 1;
    return (value: value, length: length, unknown: allOnes);
  }
}

/// One parsed element header: where its payload lives and how far it runs.
class EbmlElement {
  const EbmlElement(this.id, this.dataOffset, this.dataSize);

  /// The element id, marker bit and all — compare against [EbmlId] and
  /// [MatroskaId].
  final int id;

  final int dataOffset;

  /// Payload length in bytes; null when the element declared the unknown
  /// size and runs to the end of its parent.
  final int? dataSize;

  @override
  String toString() =>
      'EbmlElement(0x${id.toRadixString(16)}, @$dataOffset, $dataSize)';
}

/// The ids every EBML document shares.
abstract final class EbmlId {
  static const header = 0x1A45DFA3;
  static const void_ = 0xEC;
  static const crc32 = 0xBF;
}

/// The corner of Matroska the video extractor walks: Segment > Info for
/// the clock and the title, Tracks for what the streams are, Tags for
/// everything the muxer wanted to say.
abstract final class MatroskaId {
  static const segment = 0x18538067;

  static const info = 0x1549A966;
  static const timestampScale = 0x2AD7B1;
  static const duration = 0x4489;
  static const title = 0x7BA9;

  static const tracks = 0x1654AE6B;
  static const trackEntry = 0xAE;
  static const trackType = 0x83;
  static const codecId = 0x86;
  static const defaultDuration = 0x23E383;
  static const language = 0x22B59C;
  static const video = 0xE0;
  static const pixelWidth = 0xB0;
  static const pixelHeight = 0xBA;
  static const audio = 0xE1;

  static const tags = 0x1254C367;
  static const tag = 0x7373;
  static const simpleTag = 0x67C8;
  static const tagName = 0x45A3;
  static const tagString = 0x4487;
}
