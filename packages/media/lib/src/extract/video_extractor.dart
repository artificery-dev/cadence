import '../filesystem.dart';
import 'dart:convert';

import 'dart:typed_data';

import 'package:iso_base_media/iso_base_media.dart';

// iso_base_media's whole API speaks in RandomAccessSource, and the package
// rides in with it — this is not a new dependency, just its voice.
import 'package:random_access_source/random_access_source.dart';

import '../database/database.dart';
import '../kinds.dart';
import '../metadata.dart';
import 'ebml.dart';
import 'extractor.dart';

/// The pure-Dart video tier: three container dialects, one shape out.
///
/// MP4 and its kin are walked box by box with `iso_base_media` — `mvhd`
/// for the clock, the video track's `stsd` for frame size and codec, the
/// audio track's for its codec, `ilst` for whatever iTunes-style tags the
/// muxer wrote. MKV and WebM go through the hand-rolled [EbmlReader];
/// AVI is a RIFF walk over `avih`, `strh`, and `strf`. Codec ids are
/// always recorded — friendly names in the typed fields, the container's
/// own spelling in `extra` — because the deferred keyframe-pHash plan
/// picks its battles by codec.
///
/// What the container leaves unsaid, the filename may still confess:
/// `SxxEyy` (or `1x02`) yields season and episode with the prefix as the
/// series, and `Title (Year)` yields the year and, when no tag spoke
/// first, the title. Corrupt input never throws — the parse keeps what it
/// managed and the filename fills in the rest.
class VideoExtractor implements MetadataExtractor {
  const VideoExtractor({this.fileSystem});
  final FileSystem? fileSystem;

  /// Extension → the container name we file it under. QuickTime's `.mov`
  /// and `.m4v` are the same box soup as `.mp4` and are shelved with it.
  static const _containers = {
    'mp4': 'mp4',
    'm4v': 'mp4',
    'mov': 'mp4',
    'mkv': 'mkv',
    'webm': 'webm',
    'avi': 'avi',
  };

  @override
  bool handles(MediaKind kind, String extension) =>
      kind == MediaKind.video && _containers.containsKey(extension);

  @override
  Future<ExtractionResult?> extract(String path, MediaKind kind) =>
      withMediaFileSystem(
        fileSystem ?? mediaFileSystem,
        () => _extractScoped(path, kind),
      );

  Future<ExtractionResult?> _extractScoped(String path, MediaKind kind) async {
    final extension = mediaPath
        .extension(path)
        .replaceFirst('.', '')
        .toLowerCase();
    final container = _containers[extension];
    if (container == null) return null;
    final draft = _Draft()..container = container;
    final artwork = <ExtractedArtwork>[];
    try {
      switch (container) {
        case 'mp4':
          await _readIsoBmff(path, draft, artwork);
        case 'mkv' || 'webm':
          _readMatroska(path, draft);
        case 'avi':
          _readAvi(path, draft);
      }
    } catch (_) {
      // Corrupt input: keep whatever the parse got to.
    }
    _inferFromName(path, draft);
    return ExtractionResult(metadata: draft.build(), artwork: artwork);
  }

  // ------------------------------------------------------------ MP4 / MOV

  Future<void> _readIsoBmff(
    String path,
    _Draft d,
    List<ExtractedArtwork> artwork,
  ) async {
    final src = await FileRASource.loadFile(mediaFileSystem.file(path));
    try {
      final root = ISOBox.createRootBox();
      ISOBox? moov;
      for (
        var box = await root.nextChild(src);
        box != null;
        box = await root.nextChild(src)
      ) {
        if (box.type == 'moov') {
          moov = box;
          break;
        }
      }
      if (moov == null) return;
      for (
        var box = await moov.nextChild(src);
        box != null;
        box = await moov.nextChild(src)
      ) {
        switch (box.type) {
          case 'mvhd':
            _readMvhd(await box.extractData(src), box.version, d);
          case 'trak':
            await _readTrak(src, box, d);
          case 'udta':
            await _readUdta(src, box, d, artwork);
        }
      }
    } finally {
      await src.close();
    }
  }

  void _readMvhd(Uint8List data, int version, _Draft d) {
    final bytes = ByteData.sublistView(data);
    final (timescale, duration) = version == 1
        ? (bytes.getUint32(16), bytes.getUint64(20))
        : (bytes.getUint32(8), bytes.getUint32(12));
    if (timescale > 0 && duration > 0) {
      d.duration ??= Duration(
        microseconds: duration * Duration.microsecondsPerSecond ~/ timescale,
      );
    }
  }

  Future<void> _readTrak(RandomAccessSource src, ISOBox trak, _Draft d) async {
    Uint8List? tkhd;
    var tkhdVersion = 0;
    String? handler;
    Uint8List? stsd;
    Uint8List? stsz;
    var mdhdTimescale = 0;
    var mdhdDuration = 0;
    String? language;
    for (
      var box = await trak.nextChild(src);
      box != null;
      box = await trak.nextChild(src)
    ) {
      if (box.type == 'tkhd') {
        tkhd = await box.extractData(src);
        tkhdVersion = box.version;
      }
      if (box.type != 'mdia') continue;
      for (
        var inner = await box.nextChild(src);
        inner != null;
        inner = await box.nextChild(src)
      ) {
        switch (inner.type) {
          case 'mdhd':
            final data = ByteData.sublistView(await inner.extractData(src));
            if (inner.version == 1) {
              mdhdTimescale = data.getUint32(16);
              mdhdDuration = data.getUint64(20);
              language = _mdhdLanguage(data.getUint16(28));
            } else {
              mdhdTimescale = data.getUint32(8);
              mdhdDuration = data.getUint32(12);
              language = _mdhdLanguage(data.getUint16(16));
            }
          case 'hdlr':
            final data = await inner.extractData(src);
            if (data.length >= 8) {
              handler = String.fromCharCodes(data, 4, 8);
            }
          case 'minf':
            final stbl = await inner.getChildByTypePath(src, ['stbl']);
            if (stbl == null) break;
            for (
              var leaf = await stbl.nextChild(src);
              leaf != null;
              leaf = await stbl.nextChild(src)
            ) {
              if (leaf.type == 'stsd') stsd = await leaf.extractData(src);
              if (leaf.type == 'stsz') stsz = await leaf.extractData(src);
            }
        }
      }
    }
    switch (handler) {
      case 'vide' when d.videoCodec == null:
        final entry = _firstSampleEntry(stsd);
        if (entry != null) {
          d.videoCodec = _isoVideoCodec(entry.fourcc);
          d.extra['videoCodecId'] = entry.fourcc;
          if (entry.body.length >= 28) {
            final body = ByteData.sublistView(entry.body);
            d.width ??= _nonZero(body.getUint16(24));
            d.height ??= _nonZero(body.getUint16(26));
          }
        }
        if (tkhd != null) {
          final body = ByteData.sublistView(tkhd);
          final at = tkhdVersion == 1 ? 84 : 72;
          if (tkhd.length >= at + 8) {
            d.width ??= _nonZero(body.getUint32(at) >> 16);
            d.height ??= _nonZero(body.getUint32(at + 4) >> 16);
          }
        }
        if (stsz != null && stsz.length >= 8 && mdhdTimescale > 0) {
          final samples = ByteData.sublistView(stsz).getUint32(4);
          final seconds = mdhdDuration / mdhdTimescale;
          if (samples > 0 && seconds > 0) {
            d.frameRate ??= samples / seconds;
          }
        }
      case 'soun' when d.audioCodec == null:
        final entry = _firstSampleEntry(stsd);
        if (entry != null) {
          d.audioCodec = _isoAudioCodec(entry.fourcc);
          d.extra['audioCodecId'] = entry.fourcc;
        }
      case 'sbtl' || 'subt' || 'text':
        if (language != null && language != 'und') {
          d.subtitleLanguages.add(language);
        }
    }
  }

  /// The first entry in an `stsd` payload: its format fourcc and body.
  ({String fourcc, Uint8List body})? _firstSampleEntry(Uint8List? stsd) {
    if (stsd == null || stsd.length < 16) return null;
    final size = ByteData.sublistView(stsd).getUint32(4);
    if (size < 8 || size > stsd.length - 4) return null;
    return (
      fourcc: String.fromCharCodes(stsd, 8, 12),
      body: Uint8List.sublistView(stsd, 12, 4 + size),
    );
  }

  /// The packed 15-bit ISO-639-2 code `mdhd` carries.
  String _mdhdLanguage(int packed) => String.fromCharCodes([
    ((packed >> 10) & 0x1f) + 0x60,
    ((packed >> 5) & 0x1f) + 0x60,
    (packed & 0x1f) + 0x60,
  ]);

  Future<void> _readUdta(
    RandomAccessSource src,
    ISOBox udta,
    _Draft d,
    List<ExtractedArtwork> artwork,
  ) async {
    final ilst = await udta.getChildByTypePath(src, ['meta', 'ilst']);
    if (ilst == null) return;
    for (
      var atom = await ilst.nextChild(src);
      atom != null;
      atom = await ilst.nextChild(src)
    ) {
      _readIlstAtom(atom.type, await atom.extractData(src), d, artwork);
    }
  }

  /// One `ilst` atom: its payload lives in a nested `data` box — four
  /// bytes of version+type, four of locale, then the value, typed by the
  /// low 24 bits of the first word (1 = UTF-8, 21/22 = big-endian int,
  /// 13/14 = JPEG/PNG). Freeform `----` atoms carry `mean`/`name` boxes
  /// naming the key.
  void _readIlstAtom(
    String type,
    Uint8List bytes,
    _Draft d,
    List<ExtractedArtwork> artwork,
  ) {
    var key = type;
    var offset = 0;
    int? valueType;
    Uint8List? payload;
    while (offset + 8 <= bytes.length) {
      final data = ByteData.sublistView(bytes);
      final size = data.getUint32(offset);
      if (size < 8 || offset + size > bytes.length) break;
      final boxType = String.fromCharCodes(bytes, offset + 4, offset + 8);
      final body = Uint8List.sublistView(bytes, offset + 8, offset + size);
      switch (boxType) {
        case 'data' when body.length >= 8:
          valueType = ByteData.sublistView(body).getUint32(0) & 0xffffff;
          payload = Uint8List.sublistView(body, 8);
        case 'mean' || 'name' when body.length > 4:
          key = '$key:${_utf8Lenient(Uint8List.sublistView(body, 4))}';
      }
      offset += size;
    }
    if (payload == null) return;
    final text = valueType == 1 ? _utf8Lenient(payload) : null;
    final number = switch (valueType) {
      21 ||
      22 ||
      0 when payload.length <= 8 && payload.isNotEmpty => _bigEndian(payload),
      _ => null,
    };
    switch (type) {
      case '©nam' when text != null:
        d.title ??= text;
      case '©day' when text != null:
        d.date ??= text;
      case '©gen' when text != null:
        d.genres.add(text);
      case '©cmt' when text != null:
        d.comment ??= text;
      case 'tvsh' when text != null:
        d.series ??= text;
      case 'tvsn' when number != null:
        d.season ??= number;
      case 'tves' when number != null:
        d.episode ??= number;
      case 'covr' when valueType == 13 || valueType == 14:
        artwork.add(
          ExtractedArtwork(
            bytes: payload,
            mime: valueType == 13 ? 'image/jpeg' : 'image/png',
            role: ArtworkRole.embedded,
          ),
        );
      default:
        final value = text ?? number;
        if (value != null) d.extra.putIfAbsent(key, () => value);
    }
  }

  // ------------------------------------------------------------ MKV / WebM

  void _readMatroska(String path, _Draft d) {
    final file = mediaFileSystem.file(path).openSync();
    try {
      final ebml = EbmlReader(file);
      if (!ebml.looksLikeEbml) return;
      for (final top in ebml.topLevel()) {
        if (top.id != MatroskaId.segment) continue;
        for (final child in ebml.children(top)) {
          switch (child.id) {
            case MatroskaId.info:
              _readInfo(ebml, child, d);
            case MatroskaId.tracks:
              _readTracks(ebml, child, d);
            case MatroskaId.tags:
              _readTags(ebml, child, d);
          }
        }
        break;
      }
    } finally {
      file.closeSync();
    }
  }

  void _readInfo(EbmlReader ebml, EbmlElement info, _Draft d) {
    var scale = 1000000; // Nanoseconds per timestamp unit, by default.
    double? duration;
    for (final child in ebml.children(info)) {
      switch (child.id) {
        case MatroskaId.timestampScale:
          final value = ebml.uintOf(child);
          if (value > 0) scale = value;
        case MatroskaId.duration:
          duration = ebml.floatOf(child);
        case MatroskaId.title:
          final title = ebml.stringOf(child);
          if (title.isNotEmpty) d.title ??= title;
      }
    }
    if (duration != null && duration > 0) {
      d.duration ??= Duration(microseconds: (duration * scale / 1000).round());
    }
  }

  void _readTracks(EbmlReader ebml, EbmlElement tracks, _Draft d) {
    for (final entry in ebml.children(tracks)) {
      if (entry.id != MatroskaId.trackEntry) continue;
      var type = 0;
      String? codecId;
      var defaultDuration = 0;
      String? language;
      int? width;
      int? height;
      for (final field in ebml.children(entry)) {
        switch (field.id) {
          case MatroskaId.trackType:
            type = ebml.uintOf(field);
          case MatroskaId.codecId:
            codecId = ebml.stringOf(field);
          case MatroskaId.defaultDuration:
            defaultDuration = ebml.uintOf(field);
          case MatroskaId.language:
            language = ebml.stringOf(field);
          case MatroskaId.video:
            for (final v in ebml.children(field)) {
              if (v.id == MatroskaId.pixelWidth) width = ebml.uintOf(v);
              if (v.id == MatroskaId.pixelHeight) height = ebml.uintOf(v);
            }
        }
      }
      switch (type) {
        case 1 when d.videoCodec == null:
          if (codecId != null && codecId.isNotEmpty) {
            d.videoCodec = _matroskaCodec(codecId);
            d.extra['videoCodecId'] = codecId;
          }
          d.width ??= _nonZero(width ?? 0);
          d.height ??= _nonZero(height ?? 0);
          if (defaultDuration > 0) {
            d.frameRate ??= 1e9 / defaultDuration;
          }
        case 2 when d.audioCodec == null:
          if (codecId != null && codecId.isNotEmpty) {
            d.audioCodec = _matroskaCodec(codecId);
            d.extra['audioCodecId'] = codecId;
          }
        case 0x11:
          // Matroska's default track language is English, not unknown.
          d.subtitleLanguages.add(language ?? 'eng');
      }
    }
  }

  void _readTags(EbmlReader ebml, EbmlElement tags, _Draft d) {
    for (final tag in ebml.children(tags)) {
      if (tag.id != MatroskaId.tag) continue;
      for (final simple in ebml.children(tag)) {
        if (simple.id != MatroskaId.simpleTag) continue;
        String? name;
        String? value;
        for (final field in ebml.children(simple)) {
          if (field.id == MatroskaId.tagName) name = ebml.stringOf(field);
          if (field.id == MatroskaId.tagString) value = ebml.stringOf(field);
        }
        if (name == null || value == null || value.isEmpty) continue;
        switch (name.toUpperCase()) {
          case 'TITLE':
            d.title ??= value;
          case 'DATE_RELEASED' || 'DATE':
            d.date ??= value;
          case 'GENRE':
            d.genres.add(value);
          case 'COMMENT':
            d.comment ??= value;
          default:
            d.extra.putIfAbsent(name, () => value);
        }
      }
    }
  }

  // ------------------------------------------------------------------ AVI

  /// RIFF is fourcc-and-length chunks all the way down; everything the
  /// scanner wants sits in the `hdrl` LIST before the movie data —
  /// `avih` for dimensions and frame count, one `strl` per stream with
  /// `strh` (rate over scale) and `strf` (codec) inside.
  void _readAvi(String path, _Draft d) {
    final file = mediaFileSystem.file(path).openSync();
    try {
      final head = file.readSync(12);
      if (head.length < 12 ||
          String.fromCharCodes(head, 0, 4) != 'RIFF' ||
          String.fromCharCodes(head, 8, 12) != 'AVI ') {
        return;
      }
      final length = file.lengthSync();
      var offset = 12;
      while (offset + 8 <= length) {
        final chunk = _riffChunk(file, offset);
        if (chunk == null) break;
        if (chunk.id == 'LIST' && chunk.listType == 'hdrl') {
          _readHdrl(file, offset + 12, offset + 8 + chunk.size, d);
          break;
        }
        offset = chunk.next;
      }
    } finally {
      file.closeSync();
    }
  }

  void _readHdrl(RandomAccessFile file, int start, int end, _Draft d) {
    var offset = start;
    while (offset + 8 <= end) {
      final chunk = _riffChunk(file, offset);
      if (chunk == null) break;
      if (chunk.id == 'avih') {
        final bytes = _readChunkData(file, offset + 8, chunk.size, 40);
        if (bytes != null) {
          final data = ByteData.sublistView(bytes);
          final micros = data.getUint32(0, Endian.little);
          final frames = data.getUint32(16, Endian.little);
          d.width ??= _nonZero(data.getUint32(32, Endian.little));
          d.height ??= _nonZero(data.getUint32(36, Endian.little));
          if (micros > 0 && frames > 0) {
            d.duration ??= Duration(microseconds: micros * frames);
          }
        }
      } else if (chunk.id == 'LIST' && chunk.listType == 'strl') {
        _readStrl(file, offset + 12, offset + 8 + chunk.size, d);
      }
      offset = chunk.next;
    }
  }

  void _readStrl(RandomAccessFile file, int start, int end, _Draft d) {
    String? fccType;
    String? handler;
    var scale = 0;
    var rate = 0;
    var frames = 0;
    Uint8List? strf;
    var offset = start;
    while (offset + 8 <= end) {
      final chunk = _riffChunk(file, offset);
      if (chunk == null) break;
      if (chunk.id == 'strh') {
        final bytes = _readChunkData(file, offset + 8, chunk.size, 36);
        if (bytes != null) {
          final data = ByteData.sublistView(bytes);
          fccType = String.fromCharCodes(bytes, 0, 4);
          handler = String.fromCharCodes(bytes, 4, 8);
          scale = data.getUint32(20, Endian.little);
          rate = data.getUint32(24, Endian.little);
          frames = data.getUint32(32, Endian.little);
        }
      } else if (chunk.id == 'strf') {
        strf = _readChunkData(file, offset + 8, chunk.size, 2);
      }
      offset = chunk.next;
    }
    switch (fccType) {
      case 'vids' when d.videoCodec == null:
        var fourcc = handler;
        if (strf != null && strf.length >= 20) {
          final compression = String.fromCharCodes(strf, 16, 20);
          if (_printableFourcc(compression)) fourcc = compression;
        }
        if (fourcc != null && _printableFourcc(fourcc)) {
          d.videoCodec = _riffVideoCodec(fourcc);
          d.extra['videoCodecId'] = fourcc;
        }
        if (rate > 0 && scale > 0) {
          d.frameRate ??= rate / scale;
          if (frames > 0) {
            d.duration ??= Duration(
              microseconds:
                  frames * scale * Duration.microsecondsPerSecond ~/ rate,
            );
          }
        }
        if (strf != null && strf.length >= 12) {
          final data = ByteData.sublistView(strf);
          d.width ??= _nonZero(data.getUint32(4, Endian.little));
          d.height ??= _nonZero(data.getInt32(8, Endian.little).abs());
        }
      case 'auds' when d.audioCodec == null && strf != null:
        final tag = ByteData.sublistView(strf).getUint16(0, Endian.little);
        d.audioCodec = _waveCodec(tag);
        d.extra['audioCodecId'] = '0x${tag.toRadixString(16).padLeft(4, '0')}';
    }
  }

  ({String id, int size, String? listType, int next})? _riffChunk(
    RandomAccessFile file,
    int offset,
  ) {
    file.setPositionSync(offset);
    final header = file.readSync(12);
    if (header.length < 8) return null;
    final id = String.fromCharCodes(header, 0, 4);
    final size = ByteData.sublistView(header).getUint32(4, Endian.little);
    final listType = (id == 'LIST' || id == 'RIFF') && header.length >= 12
        ? String.fromCharCodes(header, 8, 12)
        : null;
    return (
      id: id,
      size: size,
      listType: listType,
      next: offset + 8 + size + (size & 1),
    );
  }

  Uint8List? _readChunkData(
    RandomAccessFile file,
    int offset,
    int size,
    int atLeast,
  ) {
    if (size < atLeast) return null;
    file.setPositionSync(offset);
    final bytes = file.readSync(size);
    return bytes.length < atLeast ? null : bytes;
  }

  bool _printableFourcc(String fourcc) =>
      fourcc.length == 4 &&
      fourcc.codeUnits.every((c) => c >= 0x20 && c < 0x7f) &&
      fourcc.trim().isNotEmpty;

  // ------------------------------------------------------- the filename

  static final _seasonEpisode = RegExp(
    r'(?<![A-Za-z0-9])[Ss](\d{1,2})\s?[Ee](\d{1,3})',
  );
  static final _crossForm = RegExp(r'(?<!\d)(\d{1,2})x(\d{2,3})(?!\d)');
  static final _titleYear = RegExp(r'^(.+?)[\s._]*\((\d{4})\)$');
  static final _seasonDir = RegExp(
    r'^(s(eason)?[\s._-]*\d+|specials?)$',
    caseSensitive: false,
  );

  static final _releaseNoise = RegExp(
    r'\b(2160p|1080p|720p|480p|WEB-?DL|WEB-?Rip|Blu-?Ray|BRRip|HDTV|'
    r'x26[45]|[Hh]\.?26[45]|HEVC|DDP?[257]|AC3|AAC2?|10bit|AMZN|RARBG|'
    r'YIFY|YTS)\b',
    caseSensitive: false,
  );

  /// Whether a tagged title is a scene-release name rather than a title —
  /// quality tokens, or an episode marker riding in a run of dotted words.
  bool _looksLikeReleaseName(String title) =>
      _releaseNoise.hasMatch(title) ||
      ((_seasonEpisode.hasMatch(title) || _crossForm.hasMatch(title)) &&
          RegExp(r'\w\.\w+\.\w').hasMatch(title));

  /// Fills what the tags left silent from the filename and its parents.
  ///
  /// A tagged title that is really a release name — dots for spaces,
  /// quality tokens, the episode marker restated — steps down first: it
  /// keeps its seat in `extra` as `taggedTitle`, and the filename speaks
  /// instead. The replacement lands here, not in the facade's fallback,
  /// so a later tier reading the same tag cannot put the noise back.
  void _inferFromName(String path, _Draft d) {
    final tagged = d.title;
    final displaced =
        tagged != null && tagged.isNotEmpty && _looksLikeReleaseName(tagged);
    if (displaced) {
      d.extra.putIfAbsent('taggedTitle', () => tagged);
      d.title = null;
    }
    _inferFromShapes(path, d);
    if (displaced && (d.title == null || d.title!.isEmpty)) {
      final cleaned = _cleanName(mediaPath.basenameWithoutExtension(path));
      if (cleaned.isNotEmpty) d.title = cleaned;
    }
  }

  void _inferFromShapes(String path, _Draft d) {
    final base = mediaPath.basenameWithoutExtension(path);
    final match =
        _seasonEpisode.firstMatch(base) ?? _crossForm.firstMatch(base);
    if (match != null) {
      d.season ??= int.parse(match[1]!);
      d.episode ??= int.parse(match[2]!);
      if (d.series == null) {
        var prefix = _cleanName(base.substring(0, match.start));
        final dated = _titleYear.firstMatch(prefix);
        if (dated != null) {
          prefix = _cleanName(dated[1]!);
          d.year ??= int.parse(dated[2]!);
        }
        d.series = prefix.isEmpty ? _seriesFromDirs(path, d) : prefix;
      }
      if (d.title == null || d.title!.isEmpty) {
        final rest = _cleanName(base.substring(match.end));
        if (rest.isNotEmpty) d.title = rest;
      }
      return;
    }
    final movie = _titleYear.firstMatch(base);
    if (movie != null) {
      d.year ??= int.parse(movie[2]!);
      if (d.title == null || d.title!.isEmpty) {
        d.title = _cleanName(movie[1]!);
      }
      return;
    }
    // A bare filename inside a `Title (Year)` directory still gets a year.
    final parent = _titleYear.firstMatch(
      mediaPath.basename(mediaPath.dirname(path)),
    );
    if (parent != null) d.year ??= int.parse(parent[2]!);
  }

  /// The nearest ancestor directory that is not a season folder — the
  /// show's own shelf. A trailing `(Year)` is shaved off (and kept).
  String? _seriesFromDirs(String path, _Draft d) {
    for (final segment in mediaPath.split(mediaPath.dirname(path)).reversed) {
      if (segment.isEmpty || segment == '.' || segment == mediaPath.separator) {
        continue;
      }
      if (_seasonDir.hasMatch(segment.trim())) continue;
      var name = segment;
      final dated = _titleYear.firstMatch(name);
      if (dated != null) {
        name = dated[1]!;
        d.year ??= int.parse(dated[2]!);
      }
      final cleaned = _cleanName(name);
      return cleaned.isEmpty ? null : cleaned;
    }
    return null;
  }

  /// Dots and underscores become spaces, separators fall off the ends.
  String _cleanName(String raw) => raw
      .replaceAll(RegExp(r'[._]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[\s\-]+|[\s\-]+$'), '');

  // ------------------------------------------------------------- codecs

  String _isoVideoCodec(String fourcc) => switch (fourcc) {
    'avc1' || 'avc3' => 'h264',
    'hvc1' || 'hev1' => 'h265',
    'vp08' => 'vp8',
    'vp09' => 'vp9',
    'av01' => 'av1',
    'mp4v' => 'mpeg4',
    _ => fourcc.trim(),
  };

  String _isoAudioCodec(String fourcc) => switch (fourcc) {
    'mp4a' => 'aac',
    'ac-3' => 'ac3',
    'ec-3' => 'eac3',
    'Opus' => 'opus',
    'fLaC' => 'flac',
    'alac' => 'alac',
    'sowt' || 'twos' || 'lpcm' => 'pcm',
    '.mp3' => 'mp3',
    _ => fourcc.trim(),
  };

  String _matroskaCodec(String id) {
    const exact = {
      'V_MPEG4/ISO/AVC': 'h264',
      'V_MPEGH/ISO/HEVC': 'h265',
      'V_VP8': 'vp8',
      'V_VP9': 'vp9',
      'V_AV1': 'av1',
      'V_THEORA': 'theora',
      'A_OPUS': 'opus',
      'A_VORBIS': 'vorbis',
      'A_FLAC': 'flac',
      'A_MPEG/L3': 'mp3',
      'A_MPEG/L2': 'mp2',
      'A_EAC3': 'eac3',
      'A_TRUEHD': 'truehd',
    };
    final friendly = exact[id];
    if (friendly != null) return friendly;
    if (id.startsWith('A_AAC')) return 'aac';
    if (id.startsWith('A_AC3')) return 'ac3';
    if (id.startsWith('A_DTS')) return 'dts';
    if (id.startsWith('A_PCM')) return 'pcm';
    if (id.startsWith('V_MPEG4/ISO')) return 'mpeg4';
    if (id.startsWith('V_MPEG2')) return 'mpeg2';
    return id;
  }

  String _riffVideoCodec(String fourcc) => switch (fourcc.toUpperCase()) {
    'MJPG' => 'mjpeg',
    'H264' || 'X264' || 'AVC1' => 'h264',
    'H265' || 'HEVC' || 'HVC1' => 'h265',
    'XVID' || 'DIVX' || 'DX50' || 'FMP4' || 'MP4V' => 'mpeg4',
    'VP80' => 'vp8',
    'VP90' => 'vp9',
    'AV01' => 'av1',
    _ => fourcc.trim(),
  };

  String _waveCodec(int tag) => switch (tag) {
    0x0001 || 0x0003 => 'pcm',
    0x0050 => 'mp2',
    0x0055 => 'mp3',
    0x00ff => 'aac',
    0x2000 => 'ac3',
    0x2001 => 'dts',
    0x0160 => 'wmav1',
    0x0161 => 'wmav2',
    _ => 'wave-0x${tag.toRadixString(16).padLeft(4, '0')}',
  };

  int? _nonZero(int value) => value == 0 ? null : value;

  String _utf8Lenient(Uint8List bytes) =>
      utf8.decode(bytes, allowMalformed: true);

  int _bigEndian(Uint8List bytes) {
    var value = 0;
    for (final byte in bytes) {
      value = (value << 8) | byte;
    }
    return value;
  }
}

/// The one mutable moment: containers write in, the filename fills the
/// gaps, and [build] freezes it into a [VideoMetadata].
class _Draft {
  String? title;
  int? year;
  Duration? duration;
  String? series;
  int? season;
  int? episode;
  int? width;
  int? height;
  double? frameRate;
  String? videoCodec;
  String? audioCodec;
  String? container;
  String? date;
  final genres = <String>[];
  String? comment;
  final subtitleLanguages = <String>[];
  final extra = <String, Object?>{};

  VideoMetadata build() => VideoMetadata(
    title: title ?? '',
    year: year ?? _leadingYear(date),
    duration: duration,
    series: series,
    season: season,
    episode: episode,
    width: width,
    height: height,
    frameRate: frameRate,
    videoCodec: videoCodec,
    audioCodec: audioCodec,
    container: container,
    date: date,
    genres: List.unmodifiable(genres),
    comment: comment,
    subtitleLanguages: List.unmodifiable(subtitleLanguages),
    extra: Map.unmodifiable(extra),
  );

  int? _leadingYear(String? date) {
    final match = date == null ? null : RegExp(r'^\d{4}').firstMatch(date);
    return match == null ? null : int.parse(match[0]!);
  }
}
