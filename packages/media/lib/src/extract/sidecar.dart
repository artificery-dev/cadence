import '../filesystem.dart';

import '../kinds.dart';
import 'format.dart';

/// A companion file and what it is to its neighbour.
class SidecarMatch {
  const SidecarMatch(this.path, this.kind);

  final String path;
  final SidecarKind kind;
}

/// Pairs media files with the sidecars that serve them. Keys are media
/// file paths; media nobody serves and sidecars nobody claims simply do
/// not appear.
///
/// Three rules, all confined to the sidecar's own directory:
///
/// * `.lrc` is lyrics and `.srt` is subtitles for the media file sharing
///   its basename, language infixes tolerated — `Episode.en.srt` serves
///   `Episode.mkv`. The longest matching stem wins, so `Episode.en.srt`
///   prefers `Episode.en.mkv` over `Episode.mkv`; ties (an album shipped
///   as both FLAC and MP3, say) serve every winner.
/// * Folder art — see [isFolderArtName] — serves *every* media file in
///   the directory.
Map<String, List<SidecarMatch>> associateSidecars({
  required List<String> mediaFiles,
  required List<String> otherFiles,
}) {
  final mediaByDir = <String, List<String>>{};
  for (final path in mediaFiles) {
    mediaByDir.putIfAbsent(mediaPath.dirname(path), () => []).add(path);
  }

  final matches = <String, List<SidecarMatch>>{};
  for (final other in otherFiles) {
    final kind = switch (extensionOf(other)) {
      'lrc' => SidecarKind.lyrics,
      'srt' => SidecarKind.subtitles,
      _ => isFolderArtName(other) ? SidecarKind.artwork : null,
    };
    if (kind == null) continue;
    final neighbours = mediaByDir[mediaPath.dirname(other)] ?? const <String>[];
    final claimed = kind == SidecarKind.artwork
        ? neighbours
        : _byBasename(other, neighbours);
    for (final media in claimed) {
      matches.putIfAbsent(media, () => []).add(SidecarMatch(other, kind));
    }
  }
  return matches;
}

/// True when [filename] names folder art: `cover`, `folder`, `front`,
/// `album`, `poster`, or `fanart` (any case) in jpg/jpeg/png/webp
/// clothing. The scanner also leans on this for the loose-image rule —
/// in non-image libraries, images that fail this test are noise.
bool isFolderArtName(String filename) =>
    _folderArtStems.contains(
      mediaPath.basenameWithoutExtension(filename).toLowerCase(),
    ) &&
    _folderArtExtensions.contains(extensionOf(filename));

const Set<String> _folderArtStems = {
  'cover', 'folder', 'front', 'album', 'poster', 'fanart', //
};

const Set<String> _folderArtExtensions = {'jpg', 'jpeg', 'png', 'webp'};

/// The media files a lyrics/subtitles sidecar serves: those whose stem is
/// the sidecar's stem, or a dot-bounded prefix of it (that is how language
/// infixes ride — `Episode.en` begins `Episode.`). Only the longest stems
/// survive, so a more specific neighbour beats a general one.
List<String> _byBasename(String sidecar, List<String> neighbours) {
  final stem = mediaPath.basenameWithoutExtension(sidecar);
  final best = <String>[];
  var bestLength = -1;
  for (final media in neighbours) {
    final mediaStem = mediaPath.basenameWithoutExtension(media);
    if (mediaStem != stem && !stem.startsWith('$mediaStem.')) continue;
    if (mediaStem.length > bestLength) {
      bestLength = mediaStem.length;
      best
        ..clear()
        ..add(media);
    } else if (mediaStem.length == bestLength) {
      best.add(media);
    }
  }
  return best;
}
