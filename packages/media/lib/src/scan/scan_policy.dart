import '../database/database.dart' show ArtworkRole;

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

/// Artwork retention and thumbnail sizing for a scan. File identity always uses
/// full SHA-256, independently of these settings.
class ScanPolicy {
  const ScanPolicy({
    this.artwork = ArtworkPolicy.everything,
    this.thumbnailSide = 256,
  });

  /// Everything, exactly: full hashes, every picture.
  static const full = ScanPolicy();

  /// Full file hashes, with only thumbnails retained.
  static const lean = ScanPolicy(artwork: ArtworkPolicy.thumbnailsOnly);

  final ArtworkPolicy artwork;

  /// The longest side of a rendered thumbnail, in pixels.
  final int thumbnailSide;

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
      other.artwork == artwork &&
      other.thumbnailSide == thumbnailSide;

  @override
  int get hashCode => Object.hash(artwork, thumbnailSide);

  @override
  String toString() => 'ScanPolicy(full, ${artwork.name}, $thumbnailSide px)';
}
