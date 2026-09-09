import '../filesystem.dart';
import 'package:crypto/crypto.dart';

import '../database/database.dart';
import '../kinds.dart';
import '../metadata.dart';

/// What one file gave up: its kind-shaped metadata, the pictures inside
/// it, and the technical truth of its container.
class ExtractionResult {
  const ExtractionResult({
    required this.metadata,
    this.artwork = const [],
    this.hashes = const {},
  });

  final MediaMetadata metadata;
  final List<ExtractedArtwork> artwork;

  /// Reserved for future content fingerprints. Built-in tiers leave this empty;
  /// the scanner computes the full file identity separately.
  final Map<HashKind, String> hashes;
}

/// A picture pulled out of a file — or found beside it — not yet a row.
class ExtractedArtwork {
  const ExtractedArtwork({
    required this.bytes,
    required this.mime,
    required this.role,
  });

  final List<int> bytes;
  final String mime;
  final ArtworkRole role;
}

/// One tier of the stack. Tiers are consulted in order; later tiers
/// enrich what earlier ones left null.
abstract interface class MetadataExtractor {
  /// Kinds this extractor will attempt. [extension] arrives lowercased and
  /// bare — `mp3`, never `.MP3`.
  bool handles(MediaKind kind, String extension);

  /// Reads the file and answers, or `null` when it has nothing to say.
  Future<ExtractionResult?> extract(String path, MediaKind kind);
}

/// The stack, spoken to as one.
///
/// Every tier that claims the file is consulted in order. The first answer
/// seeds the result; each later one fills what is still null — typed values
/// from earlier tiers win, `extra` maps merge with earlier keys winning,
/// and artwork lands once per distinct image. A tier that throws is treated
/// as a tier with nothing to say. When every tier leaves the title empty,
/// the filename steps in, extension shorn.
class MediaExtractor {
  const MediaExtractor(this.tiers, {this.fileSystem});
  final FileSystem? fileSystem;

  /// Pure-Dart tiers first, the native probe last when it is around.
  final List<MetadataExtractor> tiers;

  Future<ExtractionResult> extract(String path, MediaKind kind) =>
      withMediaFileSystem(
        fileSystem ?? mediaFileSystem,
        () => _extractScoped(path, kind),
      );

  Future<ExtractionResult> _extractScoped(String path, MediaKind kind) async {
    final extension = _extensionOf(path);
    Map<String, Object?>? merged;
    final artwork = <ExtractedArtwork>[];
    final seen = <String>{};
    final hashes = <HashKind, String>{};
    for (final tier in tiers) {
      if (!tier.handles(kind, extension)) continue;
      final ExtractionResult? result;
      try {
        result = await tier.extract(path, kind);
      } on UnsupportedError {
        rethrow;
      } catch (_) {
        continue;
      }
      if (result == null) continue;
      final json = result.metadata.toJson();
      merged = merged == null ? Map.of(json) : _fill(merged, json);
      for (final art in result.artwork) {
        if (seen.add(sha256.convert(art.bytes).toString())) {
          artwork.add(art);
        }
      }
      for (final MapEntry(:key, :value) in result.hashes.entries) {
        hashes.putIfAbsent(key, () => value);
      }
    }
    merged ??= <String, Object?>{};
    if (_isEmpty(merged['title'])) {
      merged['title'] = mediaPath.basenameWithoutExtension(path);
    }
    return ExtractionResult(
      metadata: MediaMetadata.fromJson(kind, merged),
      artwork: artwork,
      hashes: hashes,
    );
  }

  /// The null-filling merge, over JSON so it never chases the model's
  /// field list: [earlier] keeps everything it has, [later] supplies the
  /// rest, and sub-maps (`extra`, and value types alike) merge recursively
  /// under the same rule.
  Map<String, Object?> _fill(
    Map<String, Object?> earlier,
    Map<String, Object?> later,
  ) {
    final out = Map<String, Object?>.of(earlier);
    for (final MapEntry(:key, :value) in later.entries) {
      final have = out[key];
      if (have is Map<String, Object?> && value is Map<String, Object?>) {
        out[key] = _fill(have, value);
      } else if (_isEmpty(have) && !_isEmpty(value)) {
        out[key] = value;
      }
    }
    return out;
  }

  /// Null, or present but saying nothing — either way, worth filling.
  bool _isEmpty(Object? value) =>
      value == null ||
      (value is String && value.isEmpty) ||
      (value is List && value.isEmpty) ||
      (value is Map && value.isEmpty);

  String _extensionOf(String path) {
    final ext = mediaPath.extension(path);
    return ext.isEmpty ? '' : ext.substring(1).toLowerCase();
  }
}
