import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'package:cadence_media/src/database/database.dart';
import 'package:cadence_media/src/kinds.dart';
import 'package:cadence_media/src/scan/hasher.dart' show sampledSha256OfFile;
import 'package:cadence_media/src/metadata.dart';
import 'package:cadence_media/src/extract/extractor.dart';
import 'package:cadence_media/src/filesystem.dart'
    show mediaFileSystem, LocalMediaFiles;
import 'package:file/local.dart';

typedef _AbiVersionC = Uint32 Function();
typedef _AbiVersionDart = int Function();
typedef _ProbeFileC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _HashFileC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeStringC = Void Function(Pointer<Utf8>);
typedef _FreeStringDart = void Function(Pointer<Utf8>);

/// The ABI generation this loader speaks; the library must answer the same.
const int _abiVersion = 3;

/// The native probe tier — Rust behind four C symbols, when its library
/// is around.
///
/// `cadence_abi_version` must answer 3, `cadence_probe_file` takes a path
/// and returns a JSON envelope (`{"ok": …}` or `{"err": …}`),
/// `cadence_hash_file` takes a path and answers the file's sampled
/// identity hash the same way, and `cadence_free_string` releases either
/// answer. The probe's
/// `ok` payload's `fields` already speak [MediaMetadata]'s JSON names, so
/// mapping is mostly a matter of listening: fields in, raw tags into
/// `extra`, artwork base64-decoded. Legacy fingerprint fields are ignored.
///
/// Everything about loading lives in this one file, so a future move to
/// Dart build hooks stays a one-file change.
class ProbeExtractor implements MetadataExtractor {
  ProbeExtractor._(this._libraryPath, this._probeFile, this._freeString);

  /// Where the library was opened from — what a hashing isolate reopens.
  final String _libraryPath;
  final _ProbeFileC _probeFile;
  final _FreeStringDart _freeString;

  static const _audio = {
    'mp3', 'flac', 'ogg', 'oga', 'opus', 'm4a', 'm4b', 'aac', 'wav', //
    'aiff', 'aif', 'ape', 'wv', 'wma', 'mka',
  };
  static const _video = {'mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi'};
  static const _image = {
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'tif', 'tiff', //
    'heic', 'heif', 'avif',
  };
  static const _document = {'pdf', 'epub'};

  /// Loads the probe library, or answers null when no copy can be found —
  /// the stack simply runs without the tier.
  ///
  /// The search, in order: `CADENCE_PROBE_PATH` (a file, or a directory
  /// holding the library), beside `Platform.resolvedExecutable`, in the
  /// `lib` directory next to the executable's `bin` (the `dart build cli`
  /// bundle layout the packages ship), the workspace's `build/rust/release`
  /// and `build/rust/debug` — anchored both at `Directory.current` and at
  /// the package root this source resolves to — and finally the bare soname
  /// for the system loader to place.
  ///
  /// [searchFirst] names directories (or files) to try before any of
  /// those — an embedding application that bundles the library somewhere
  /// of its own says where.
  static ProbeExtractor? tryLoad({List<String> searchFirst = const []}) {
    for (final candidate in [
      for (final path in searchFirst)
        FileSystemEntity.isDirectorySync(path) ? p.join(path, _soname) : path,
      ..._candidates(),
    ]) {
      final ProbeExtractor? loaded = _openAndBind(candidate);
      if (loaded != null) return loaded;
    }
    return null;
  }

  static String get _soname => Platform.isWindows
      ? 'cadence_probe.dll'
      : Platform.isMacOS
      ? 'libcadence_probe.dylib'
      : 'libcadence_probe.so';

  static Iterable<String> _candidates() sync* {
    final fromEnv = Platform.environment['CADENCE_PROBE_PATH'];
    if (fromEnv != null && fromEnv.isNotEmpty) {
      yield FileSystemEntity.isDirectorySync(fromEnv)
          ? p.join(fromEnv, _soname)
          : fromEnv;
    }
    final binDirectory = p.dirname(Platform.resolvedExecutable);
    yield p.join(binDirectory, _soname);
    yield p.join(p.dirname(binDirectory), 'lib', _soname);
    // The dev loop runs from the repo root; tests run from the package.
    // Walk a few levels up from both anchors looking for the crate.
    final anchors = [Directory.current.path, ?_packageRoot()];
    for (final anchor in anchors) {
      var base = anchor;
      for (var depth = 0; depth < 4; depth++) {
        for (final profile in const ['release', 'debug']) {
          final candidate = p.join(base, 'build', 'rust', profile, _soname);
          if (File(candidate).existsSync()) yield candidate;
        }
        final parent = p.dirname(base);
        if (parent == base) break;
        base = parent;
      }
    }
    yield _soname;
  }

  /// Where this package lives on disk, resolved from the source itself —
  /// null under AOT, where the resolver has nothing to say.
  static String? _packageRoot() {
    try {
      final lib = Isolate.resolvePackageUriSync(
        Uri.parse('package:cadence_media/'),
      );
      if (lib == null || !lib.isScheme('file')) return null;
      return p.dirname(lib.toFilePath());
    } catch (_) {
      return null;
    }
  }

  static ProbeExtractor? _openAndBind(String path) {
    final DynamicLibrary library;
    try {
      library = DynamicLibrary.open(path);
    } catch (_) {
      return null;
    }
    try {
      final abiVersion = library.lookupFunction<_AbiVersionC, _AbiVersionDart>(
        'cadence_abi_version',
      );
      if (abiVersion() != _abiVersion) return null;
      final probeFile = library.lookupFunction<_ProbeFileC, _ProbeFileC>(
        'cadence_probe_file',
      );
      // Looked up here only to prove the symbol is there; hashing binds
      // again on its own isolate.
      library.lookupFunction<_HashFileC, _HashFileC>('cadence_hash_file');
      final freeString = library.lookupFunction<_FreeStringC, _FreeStringDart>(
        'cadence_free_string',
      );
      return ProbeExtractor._(path, probeFile, freeString);
    } catch (_) {
      return null;
    }
  }

  /// The path native code may open for [path]: the same string on a plain
  /// local filesystem, the mapped one behind a [LocalMediaFiles] view,
  /// and never anything from a virtual filesystem.
  static String _nativePath(String path) {
    final fs = mediaFileSystem;
    // No promotion: LocalMediaFiles is not a FileSystem subtype.
    if (fs is LocalMediaFiles)
      return (fs as LocalMediaFiles).localMediaPath(path);
    if (fs is LocalFileSystem) return path;
    throw UnsupportedError(
      'Native probe requires a local filesystem; virtual paths are never passed to native code',
    );
  }

  /// The file's identity hash as lowercase hex, computed by the native
  /// library — the same sampled sha256 [sampledSha256OfFile] computes in
  /// pure Dart, over the first and last mebibyte and the length, only
  /// faster. The read runs on a fresh isolate so the event loop keeps
  /// serving while a movie goes by. Throws a [FileSystemException] when
  /// the file cannot be read, a [StateError] on any other native failure.
  ///
  /// Shaped to stand in for [sampledSha256OfFile] as the scanner's
  /// `hashFile`.
  Future<String> sampledSha256(String path) async {
    final nativePath = _nativePath(path);
    final libraryPath = _libraryPath;
    return Isolate.run(
      () => _hashSync(libraryPath, nativePath),
      debugName: 'cadence-hash',
    );
  }

  static String _hashSync(String libraryPath, String nativePath) {
    final library = DynamicLibrary.open(libraryPath);
    final hashFile = library.lookupFunction<_HashFileC, _HashFileC>(
      'cadence_hash_file',
    );
    final freeString = library.lookupFunction<_FreeStringC, _FreeStringDart>(
      'cadence_free_string',
    );
    final pathPointer = nativePath.toNativeUtf8();
    final Pointer<Utf8> answer;
    try {
      answer = hashFile(pathPointer);
    } finally {
      malloc.free(pathPointer);
    }
    if (answer == nullptr) throw StateError('Native hash returned nothing');
    final String payload;
    try {
      payload = answer.toDartString();
    } finally {
      freeString(answer);
    }
    final envelope = jsonDecode(payload);
    if (envelope is! Map) throw StateError('Native hash answered $payload');
    if (envelope['err'] case final Map error) {
      final code = error['code'], message = '${error['msg']}';
      if (code == 'io') throw FileSystemException(message, nativePath);
      throw StateError('Native hash failed ($code): $message');
    }
    if (envelope['ok'] case {
      'sampledSha256': final String hex,
    } when hex.length == 64) {
      return hex;
    }
    throw StateError('Native hash answered $payload');
  }

  @override
  bool handles(MediaKind kind, String extension) => switch (kind) {
    MediaKind.audio => _audio.contains(extension),
    MediaKind.video => _video.contains(extension),
    MediaKind.image => _image.contains(extension),
    MediaKind.document => _document.contains(extension),
  };

  @override
  Future<ExtractionResult?> extract(String path, MediaKind kind) async {
    final nativePath = _nativePath(path);
    final pathPointer = nativePath.toNativeUtf8();
    final Pointer<Utf8> answer;
    try {
      answer = _probeFile(pathPointer);
    } finally {
      malloc.free(pathPointer);
    }
    if (answer == nullptr) return null;
    final String payload;
    try {
      payload = answer.toDartString();
    } finally {
      _freeString(answer);
    }
    try {
      return _decode(payload, kind);
    } catch (_) {
      return null;
    }
  }

  ExtractionResult? _decode(String payload, MediaKind kind) {
    final envelope = jsonDecode(payload);
    if (envelope is! Map) return null;
    final ok = envelope['ok'];
    if (ok is! Map) return null;

    final fields = switch (ok['fields']) {
      final Map fields => fields.cast<String, Object?>(),
      _ => const <String, Object?>{},
    };
    final extra = switch (ok['extra']) {
      final Map extra => extra.cast<String, Object?>(),
      _ => const <String, Object?>{},
    };
    final metadata = MediaMetadata.fromJson(kind, {
      ...fields,
      if (extra.isNotEmpty) 'extra': extra,
    });

    final artwork = <ExtractedArtwork>[
      for (final entry in switch (ok['artwork']) {
        final List art => art,
        _ => const <Object?>[],
      })
        if (entry is Map && entry['bytesBase64'] is String)
          ExtractedArtwork(
            bytes: base64Decode(entry['bytesBase64'] as String),
            mime: entry['mime'] as String? ?? 'application/octet-stream',
            role: _role(entry['role']),
          ),
    ];

    return ExtractionResult(metadata: metadata, artwork: artwork);
  }

  ArtworkRole _role(Object? name) => switch (name) {
    'thumbnail' => ArtworkRole.thumbnail,
    'folder' => ArtworkRole.folder,
    _ => ArtworkRole.embedded,
  };
}
