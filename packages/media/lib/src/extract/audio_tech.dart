import '../filesystem.dart';

/// The container's own testimony.
///
/// audio_metadata_reader speaks tags fluently but walks past some of the
/// plainer facts — how many channels, how deep the samples, which dialect
/// of ID3 an elderly MP3 still speaks, the iTunes atoms it never learned.
/// The readers here go straight to the header bytes for exactly those
/// gaps and nothing more. Every one of them answers `null` sooner than
/// throw: a corrupt file is a file with nothing to say.

import 'dart:convert';

import 'dart:typed_data';

/// What a stream header states about itself, before any tag has a say.
class AudioStreamInfo {
  const AudioStreamInfo({
    this.sampleRateHz,
    this.channels,
    this.bitsPerSample,
    this.bitrateKbps,
    this.codec,
  });

  final int? sampleRateHz;
  final int? channels;
  final int? bitsPerSample;
  final int? bitrateKbps;
  final String? codec;
}

/// Reads the FLAC STREAMINFO block: sample rate, channel count, and bit
/// depth — the two latter being what the tag reader never surfaces.
AudioStreamInfo? readFlacStreamInfo(String path) {
  return _withFile(path, (file) {
    final magic = file.readSync(4);
    if (magic.length < 4 || String.fromCharCodes(magic) != 'fLaC') return null;
    while (true) {
      final head = file.readSync(4);
      if (head.length < 4) return null;
      final type = head[0] & 0x7f;
      final length = (head[1] << 16) | (head[2] << 8) | head[3];
      if (type == 0) {
        final body = file.readSync(length);
        if (body.length < 18) return null;
        final sampleRate = (body[10] << 12) | (body[11] << 4) | (body[12] >> 4);
        if (sampleRate == 0) return null;
        return AudioStreamInfo(
          sampleRateHz: sampleRate,
          channels: ((body[12] >> 1) & 0x07) + 1,
          bitsPerSample: (((body[12] & 0x01) << 4) | (body[13] >> 4)) + 1,
          codec: 'flac',
        );
      }
      if (head[0] & 0x80 != 0) return null;
      file.setPositionSync(file.positionSync() + length);
    }
  });
}

/// Reads the WAV `fmt ` chunk: format code, channels, sample rate, byte
/// rate, and bit depth, straight from the RIFF header.
AudioStreamInfo? readWavFormat(String path) {
  return _withFile(path, (file) {
    final length = file.lengthSync();
    final riff = file.readSync(12);
    if (riff.length < 12 ||
        String.fromCharCodes(riff.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(riff.sublist(8, 12)) != 'WAVE') {
      return null;
    }
    var offset = 12;
    while (offset + 8 <= length) {
      file.setPositionSync(offset);
      final head = file.readSync(8);
      if (head.length < 8) return null;
      final id = String.fromCharCodes(head.sublist(0, 4));
      final size = _uint32le(head, 4);
      if (id == 'fmt ') {
        final body = file.readSync(size < 16 ? size : 16);
        if (body.length < 16) return null;
        final format = _uint16le(body, 0);
        final byteRate = _uint32le(body, 8);
        return AudioStreamInfo(
          sampleRateHz: _uint32le(body, 4),
          channels: _uint16le(body, 2),
          bitsPerSample: _uint16le(body, 14),
          bitrateKbps: byteRate > 0 ? (byteRate * 8 / 1000).round() : null,
          codec: switch (format) {
            1 || 3 || 0xfffe => 'pcm',
            _ => null,
          },
        );
      }
      offset += 8 + size + (size.isOdd ? 1 : 0);
    }
    return null;
  });
}

/// Finds the first MPEG audio frame past any leading ID3v2 tags and reads
/// its header — the channel mode being the fact the tag reader drops.
AudioStreamInfo? readMp3FrameHeader(String path) {
  return _withFile(path, (file) {
    final length = file.lengthSync();
    var offset = _pastId3v2(file, length);
    file.setPositionSync(offset);
    final window = file.readSync(
      length - offset < _mp3ScanWindow ? length - offset : _mp3ScanWindow,
    );
    for (var i = 0; i + 4 <= window.length; i++) {
      if (window[i] != 0xff || (window[i + 1] & 0xe0) != 0xe0) continue;
      final version = (window[i + 1] >> 3) & 0x03;
      final layer = (window[i + 1] >> 1) & 0x03;
      final bitrateIndex = window[i + 2] >> 4;
      final rateIndex = (window[i + 2] >> 2) & 0x03;
      if (version == 1 ||
          layer == 0 ||
          bitrateIndex == 0 ||
          bitrateIndex == 15 ||
          rateIndex == 3) {
        continue;
      }
      final base = switch (rateIndex) {
        0 => 44100,
        1 => 48000,
        _ => 32000,
      };
      return AudioStreamInfo(
        sampleRateHz: switch (version) {
          3 => base, // MPEG 1
          2 => base ~/ 2, // MPEG 2
          _ => base ~/ 4, // MPEG 2.5
        },
        channels: ((window[i + 3] >> 6) & 0x03) == 3 ? 1 : 2,
        codec: 'mp3',
      );
    }
    return null;
  });
}

const _mp3ScanWindow = 256 * 1024;

/// Walks the chain of leading ID3v2 tags and returns the offset where
/// audio can begin.
int _pastId3v2(RandomAccessFile file, int length) {
  var offset = 0;
  while (offset + 10 <= length) {
    file.setPositionSync(offset);
    final head = file.readSync(10);
    if (head.length < 10 ||
        head[0] != 0x49 ||
        head[1] != 0x44 ||
        head[2] != 0x33 ||
        (head[6] | head[7] | head[8] | head[9]) & 0x80 != 0) {
      break;
    }
    final size =
        (head[9] & 0x7f) |
        ((head[8] & 0x7f) << 7) |
        ((head[7] & 0x7f) << 14) |
        ((head[6] & 0x7f) << 21);
    final footer = head[3] == 4 && (head[5] & 0x10) != 0 ? 10 : 0;
    final next = offset + 10 + size + footer;
    if (next <= offset || next > length) break;
    offset = next;
  }
  return offset;
}

/// An ID3v2.2 tag, read by hand — the three-letter dialect
/// audio_metadata_reader gives up on.
class Id3v22Tag {
  const Id3v22Tag({
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.composer,
    this.genre,
    this.year,
    this.trackNumber,
    this.trackTotal,
  });

  final String? title; // TT2
  final String? artist; // TP1
  final String? album; // TAL
  final String? albumArtist; // TP2
  final String? composer; // TCM
  final String? genre; // TCO
  final int? year; // TYE
  final int? trackNumber; // TRK
  final int? trackTotal; // TRK, after the slash
}

/// Reads an ID3v2.2 header when one leads the file; `null` for anything
/// else, including the v2.3/v2.4 tags the package already handles.
///
/// Frames carry a 3-byte id and a 3-byte big-endian size; text bodies
/// open with an encoding byte — `$00` latin-1 or `$01` UTF-16 with BOM.
Id3v22Tag? readId3v22(String path) {
  return _withFile(path, (file) {
    final head = file.readSync(10);
    if (head.length < 10 ||
        head[0] != 0x49 ||
        head[1] != 0x44 ||
        head[2] != 0x33 ||
        head[3] != 2) {
      return null;
    }
    final size =
        (head[9] & 0x7f) |
        ((head[8] & 0x7f) << 7) |
        ((head[7] & 0x7f) << 14) |
        ((head[6] & 0x7f) << 21);
    final body = file.readSync(size);

    String? title, artist, album, albumArtist, composer, genre;
    int? year, trackNumber, trackTotal;

    var offset = 0;
    while (offset + 6 <= body.length) {
      if (body[offset] == 0) break;
      final id = String.fromCharCodes(body, offset, offset + 3);
      final frameSize =
          (body[offset + 3] << 16) | (body[offset + 4] << 8) | body[offset + 5];
      offset += 6;
      if (frameSize <= 0 || offset + frameSize > body.length) break;
      final text = _v22Text(body.sublist(offset, offset + frameSize));
      offset += frameSize;
      switch (id) {
        case 'TT2':
          title = text;
        case 'TP1':
          artist = text;
        case 'TAL':
          album = text;
        case 'TP2':
          albumArtist = text;
        case 'TCM':
          composer = text;
        case 'TCO':
          genre = text;
        case 'TYE':
          year = int.tryParse(text);
        case 'TRK':
          final parts = text.split('/');
          trackNumber = int.tryParse(parts.first);
          if (parts.length > 1) trackTotal = int.tryParse(parts[1]);
      }
    }
    return Id3v22Tag(
      title: title,
      artist: artist,
      album: album,
      albumArtist: albumArtist,
      composer: composer,
      genre: genre,
      year: year,
      trackNumber: trackNumber,
      trackTotal: trackTotal,
    );
  });
}

String _v22Text(Uint8List frame) {
  if (frame.isEmpty) return '';
  final bytes = frame.sublist(1);
  if (frame[0] == 1) return _utf16(bytes);
  final end = bytes.indexOf(0);
  return String.fromCharCodes(bytes, 0, end < 0 ? bytes.length : end);
}

String _utf16(Uint8List bytes) {
  var bigEndian = false;
  var start = 0;
  if (bytes.length >= 2) {
    if (bytes[0] == 0xfe && bytes[1] == 0xff) {
      bigEndian = true;
      start = 2;
    } else if (bytes[0] == 0xff && bytes[1] == 0xfe) {
      start = 2;
    }
  }
  final units = <int>[];
  for (var i = start; i + 1 < bytes.length; i += 2) {
    final unit = bigEndian
        ? (bytes[i] << 8) | bytes[i + 1]
        : bytes[i] | (bytes[i + 1] << 8);
    if (unit == 0) break;
    units.add(unit);
  }
  return String.fromCharCodes(units);
}

/// Reads the track number an ID3v1.1 tail carries in its final bytes —
/// the one field of the old 128-byte block the package leaves behind.
int? readId3v1Track(String path) {
  return _withFile(path, (file) {
    final length = file.lengthSync();
    if (length < 128) return null;
    file.setPositionSync(length - 128);
    final tag = file.readSync(128);
    if (tag.length < 128 || String.fromCharCodes(tag, 0, 3) != 'TAG') {
      return null;
    }
    return tag[125] == 0 && tag[126] != 0 ? tag[126] : null;
  });
}

/// The iTunes atoms audio_metadata_reader walks past: album artist,
/// the compilation flag, the sort names, freeform `----` tags, and the
/// codec fourcc from the sample description.
class Mp4Extras {
  Mp4Extras();

  String? albumArtist; // aART
  bool? compilation; // cpil
  String? sortTitle; // sonm
  String? sortArtist; // soar
  String? sortAlbum; // soal
  String? sortAlbumArtist; // soaa
  String? codec; // stsd fourcc, translated

  /// Freeform atoms, keyed `----:mean:name` exactly as Apple spells them.
  final Map<String, String> freeform = {};
}

/// Walks an MP4/M4A/M4B box tree for [Mp4Extras]; `null` when the file
/// is not box-shaped at all.
Mp4Extras? readMp4Extras(String path) {
  return _withFile(path, (file) {
    final length = file.lengthSync();
    file.setPositionSync(4);
    if (String.fromCharCodes(file.readSync(4)) != 'ftyp') return null;
    final extras = Mp4Extras();
    _walkBoxes(file, 0, length, extras, 0);
    return extras;
  });
}

const _mp4Containers = {'moov', 'udta', 'trak', 'mdia', 'minf', 'stbl'};

void _walkBoxes(
  RandomAccessFile file,
  int start,
  int end,
  Mp4Extras out,
  int depth,
) {
  if (depth > 8) return;
  var offset = start;
  while (offset + 8 <= end) {
    file.setPositionSync(offset);
    final head = file.readSync(8);
    if (head.length < 8) return;
    var size = _uint32be(head, 0);
    final type = String.fromCharCodes(head, 4, 8);
    var headerLength = 8;
    if (size == 1) {
      final wide = file.readSync(8);
      if (wide.length < 8) return;
      size = _uint64be(wide);
      headerLength = 16;
    } else if (size == 0) {
      size = end - offset;
    }
    if (size < headerLength || offset + size > end) return;
    final bodyStart = offset + headerLength;
    final bodyEnd = offset + size;

    if (_mp4Containers.contains(type)) {
      _walkBoxes(file, bodyStart, bodyEnd, out, depth + 1);
    } else if (type == 'meta') {
      // `meta` usually opens with 4 version/flags bytes, but some writers
      // start the children immediately; probe before committing.
      final probe = file.readSync(8);
      final looksLikeChild =
          probe.length == 8 &&
          _uint32be(probe, 0) >= 8 &&
          _uint32be(probe, 0) <= bodyEnd - bodyStart &&
          probe.sublist(4).every((byte) => byte >= 0x20 && byte <= 0x7e);
      _walkBoxes(
        file,
        looksLikeChild ? bodyStart : bodyStart + 4,
        bodyEnd,
        out,
        depth + 1,
      );
    } else if (type == 'ilst') {
      _walkIlst(file, bodyStart, bodyEnd, out);
    } else if (type == 'stsd') {
      _readSampleDescription(file, bodyStart, bodyEnd, out);
    }
    offset = bodyEnd;
  }
}

void _walkIlst(RandomAccessFile file, int start, int end, Mp4Extras out) {
  var offset = start;
  while (offset + 8 <= end) {
    file.setPositionSync(offset);
    final head = file.readSync(8);
    if (head.length < 8) return;
    final size = _uint32be(head, 0);
    if (size < 8 || offset + size > end) return;
    final type = String.fromCharCodes(head, 4, 8);
    final bodyStart = offset + 8;
    final bodyEnd = offset + size;
    switch (type) {
      case 'aART':
        out.albumArtist ??= _dataText(file, bodyStart, bodyEnd);
      case 'cpil':
        final value = _dataBytes(file, bodyStart, bodyEnd);
        if (value != null) {
          out.compilation ??= value.any((byte) => byte != 0);
        }
      case 'sonm':
        out.sortTitle ??= _dataText(file, bodyStart, bodyEnd);
      case 'soar':
        out.sortArtist ??= _dataText(file, bodyStart, bodyEnd);
      case 'soal':
        out.sortAlbum ??= _dataText(file, bodyStart, bodyEnd);
      case 'soaa':
        out.sortAlbumArtist ??= _dataText(file, bodyStart, bodyEnd);
      case '----':
        _readFreeform(file, bodyStart, bodyEnd, out);
    }
    offset = bodyEnd;
  }
}

/// A freeform item is three child boxes — `mean`, `name`, `data` — that
/// spell a key like `----:com.apple.iTunes:MusicBrainz Album Id`.
void _readFreeform(RandomAccessFile file, int start, int end, Mp4Extras out) {
  String? mean;
  String? name;
  String? value;
  var offset = start;
  while (offset + 8 <= end) {
    file.setPositionSync(offset);
    final head = file.readSync(8);
    if (head.length < 8) return;
    final size = _uint32be(head, 0);
    if (size < 8 || offset + size > end) return;
    final type = String.fromCharCodes(head, 4, 8);
    final body = file.readSync(size - 8);
    switch (type) {
      case 'mean' when body.length > 4:
        mean = _utf8ish(body.sublist(4));
      case 'name' when body.length > 4:
        name = _utf8ish(body.sublist(4));
      case 'data' when body.length > 8:
        value = _utf8ish(body.sublist(8));
    }
    offset += size;
  }
  if (name != null && value != null) {
    out.freeform['----:${mean ?? ''}:$name'] = value;
  }
}

String? _dataText(RandomAccessFile file, int start, int end) {
  final bytes = _dataBytes(file, start, end);
  if (bytes == null || bytes.isEmpty) return null;
  final text = _utf8ish(bytes);
  return text.isEmpty ? null : text;
}

Uint8List? _dataBytes(RandomAccessFile file, int start, int end) {
  var offset = start;
  while (offset + 8 <= end) {
    file.setPositionSync(offset);
    final head = file.readSync(8);
    if (head.length < 8) return null;
    final size = _uint32be(head, 0);
    if (size < 8 || offset + size > end) return null;
    if (String.fromCharCodes(head, 4, 8) == 'data') {
      // 4 bytes version/type, 4 bytes locale, then the payload.
      final body = file.readSync(size - 8);
      return body.length > 8 ? body.sublist(8) : Uint8List(0);
    }
    offset += size;
  }
  return null;
}

const _mp4Codecs = {
  'mp4a': 'aac',
  'alac': 'alac',
  'Opus': 'opus',
  'fLaC': 'flac',
  'mp3 ': 'mp3',
  '.mp3': 'mp3',
  'lpcm': 'pcm',
  'sowt': 'pcm',
  'twos': 'pcm',
  'raw ': 'pcm',
};

void _readSampleDescription(
  RandomAccessFile file,
  int start,
  int end,
  Mp4Extras out,
) {
  // 4 bytes version/flags, 4 bytes entry count, then the first entry.
  if (start + 16 > end) return;
  file.setPositionSync(start + 8);
  final head = file.readSync(8);
  if (head.length < 8) return;
  final fourcc = String.fromCharCodes(head, 4, 8);
  out.codec ??= _mp4Codecs[fourcc];
}

/// Says which codec an Ogg stream opens with — `opus`, `vorbis`, or
/// `flac` — by sniffing the first pages for their signature packets.
String? sniffOggCodec(String path) {
  return _withFile(path, (file) {
    final bytes = file.readSync(1024);
    if (bytes.length < 4 || String.fromCharCodes(bytes, 0, 4) != 'OggS') {
      return null;
    }
    if (_contains(bytes, 'OpusHead'.codeUnits)) return 'opus';
    if (_contains(bytes, [0x01, ...'vorbis'.codeUnits])) return 'vorbis';
    if (_contains(bytes, [0x7f, ...'FLAC'.codeUnits])) return 'flac';
    return null;
  });
}

/// Names an image by its magic bytes — for the pictures a tag carries
/// with no mime type, or a wrong one.
String sniffImageMime(List<int> bytes) {
  bool at(int offset, List<int> magic) {
    if (bytes.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  if (at(0, const [0xff, 0xd8, 0xff])) return 'image/jpeg';
  if (at(0, const [0x89, 0x50, 0x4e, 0x47])) return 'image/png';
  if (at(0, 'GIF8'.codeUnits)) return 'image/gif';
  if (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits)) return 'image/webp';
  if (at(0, 'BM'.codeUnits)) return 'image/bmp';
  return 'application/octet-stream';
}

bool _contains(Uint8List haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

String _utf8ish(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

T? _withFile<T>(String path, T? Function(RandomAccessFile file) read) {
  RandomAccessFile? file;
  try {
    file = mediaFileSystem.file(path).openSync();
    return read(file);
  } catch (_) {
    return null;
  } finally {
    try {
      file?.closeSync();
    } catch (_) {
      // A close that fails changes nothing about the answer.
    }
  }
}

int _uint16le(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _uint32le(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

int _uint32be(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

int _uint64be(Uint8List bytes) {
  var value = 0;
  for (final byte in bytes) {
    value = (value << 8) | byte;
  }
  return value;
}
