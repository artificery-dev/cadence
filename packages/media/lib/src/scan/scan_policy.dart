import '../database/database.dart' show ArtworkRole;
import '../kinds.dart';

/// Which hash stands for a file's bytes. The scanner writes one of these
/// for every file it reads and consults the same kind when a vanished
/// path turns up elsewhere — so the choice is per scanner, not per file,
/// and a library keeps to one.
enum IdentityHash {
  /// sha256 over every byte: exact, and a full read of every new file.
  /// Right for a desktop with a fast disk; on a small player with a
  /// 500 GB card it is hours of reading for the first scan.
  full(HashKind.sha256),

  /// sha256 over the file's head, its tail, and its size — a fixed
  /// budget per file, whatever its length. A file the size of the
  /// budget or smaller hashes whole. Two files that agree here are the
  /// same file for every purpose the scanner has (recognising a move);
  /// a deliberate near-duplicate can fool it, which is the trade.
  sampled(HashKind.sampledSha256);

  const IdentityHash(this.kind);

  /// The row kind the hash lands under.
  final HashKind kind;
}

/// Which pictures a scan keeps in the database.
enum ArtworkPolicy {
  /// The embedded cover, the folder art, and a thumbnail of one of them:
  /// everything the file offered, at full size.
  everything,

  /// Only the thumbnail. Full-size covers are read to make it and then
  /// let go — a library of thousands of tracks with a 500 KB cover each
  /// would otherwise carry gigabytes of pictures on a device with a
  /// small root filesystem.
  thumbnailsOnly,

  /// No pictures at all; the player reads art from the file when it
  /// wants one.
  none,

  /// No pictures during the scan — files and tags land as fast as they
  /// can — and thumbnails afterwards, from the `ArtworkQueue`: every
  /// file in turn at low priority, and whatever the player asks for
  /// first. The shape for a small machine with a big card.
  deferred,
}

/// How much a scan spends per file: which hash names the bytes, which
/// pictures survive, and how big a thumbnail is. [full] is the desktop's
/// answer and the default; [lean] is a player's.
///
/// Plain values only — the policy rides to every worker isolate with the
/// batch it applies to.
class ScanPolicy {
  const ScanPolicy({
    this.identity = IdentityHash.full,
    this.artwork = ArtworkPolicy.everything,
    this.thumbnailSide = 256,
    this.hashSpan = 1024 * 1024,
  });

  /// Everything, exactly: full hashes, every picture.
  static const full = ScanPolicy();

  /// A small machine's budget: sampled hashes, thumbnails only.
  static const lean = ScanPolicy(
    identity: IdentityHash.sampled,
    artwork: ArtworkPolicy.thumbnailsOnly,
  );

  final IdentityHash identity;
  final ArtworkPolicy artwork;

  /// The longest side of a rendered thumbnail, in pixels.
  final int thumbnailSide;

  /// For [IdentityHash.sampled]: how many bytes of each end of a file
  /// are read. Tags live at the ends (ID3v2 up front, ID3v1 and APE at
  /// the tail, FLAC and MP4 metadata up front), so a retag still moves
  /// the hash; a smaller span is a cheaper scan on a slow card.
  final int hashSpan;

  /// Whether a picture in [role] is written to the database.
  bool keeps(ArtworkRole role) => switch (artwork) {
    ArtworkPolicy.everything => true,
    ArtworkPolicy.thumbnailsOnly => role == ArtworkRole.thumbnail,
    ArtworkPolicy.none || ArtworkPolicy.deferred => false,
  };

  /// Whether the scan renders thumbnails itself.
  bool get rendersThumbnails =>
      artwork == ArtworkPolicy.everything ||
      artwork == ArtworkPolicy.thumbnailsOnly;

  /// Whether thumbnails are left to the artwork queue.
  bool get defersArtwork => artwork == ArtworkPolicy.deferred;

  @override
  bool operator ==(Object other) =>
      other is ScanPolicy &&
      other.identity == identity &&
      other.artwork == artwork &&
      other.thumbnailSide == thumbnailSide &&
      other.hashSpan == hashSpan;

  @override
  int get hashCode => Object.hash(identity, artwork, thumbnailSide, hashSpan);

  @override
  String toString() =>
      'ScanPolicy(${identity.name}, ${artwork.name}, $thumbnailSide px)';
}
