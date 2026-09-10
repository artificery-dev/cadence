import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

import '../data/artwork_cache.dart';

/// Cover art: the real picture when the [ArtworkCache] above has one for
/// [fileId], and otherwise a stand-in derived deterministically from a
/// seed string — the same album always wears the same face while its
/// cover is on the way, or forever when it has none. Deliberately
/// theme-independent — artwork is artwork.
class ArtTile extends StatelessWidget {
  const ArtTile(
    this.seed, {
    this.kind = MediaKind.audio,
    this.size,
    this.aspectRatio = 1,
    this.fileId,
    super.key,
  });

  /// What the art stands for — an album title, an item title. Identity in,
  /// identity out.
  final String seed;

  /// Which kind's glyph the placeholder wears.
  final MediaKind kind;

  /// Fixed edge length; null fills the width it's given at [aspectRatio]
  /// proportions.
  final double? size;

  /// Width over height when the tile sizes itself — 1 for the square
  /// sleeve, a standing book's 2:3 for a spine. Ignored when [size] pins
  /// the tile square.
  final double aspectRatio;

  /// The file whose artwork to wear, when one stands behind the seed.
  final int? fileId;

  static const _swatches = [
    Swatch.violet,
    Swatch.cyan,
    Swatch.rose,
    Swatch.sky,
    Swatch.amber,
    Swatch.emerald,
    Swatch.indigo,
    Swatch.fuchsia,
    Swatch.teal,
    Swatch.orange,
  ];

  /// One glyph per kind, everywhere — the same as the collection rows
  /// speak — so a stand-in always says what the thing is; the hash only
  /// picks its colour.
  static const _glyphs = {
    MediaKind.audio: LucideIcons.music4,
    MediaKind.video: LucideIcons.film,
    MediaKind.image: LucideIcons.image,
    MediaKind.document: LucideIcons.bookOpen,
  };

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.maybeOf(context) ?? const Theme();

    final image = switch (fileId) {
      final id? => ArtworkScope.maybeOf(context)?.of(id),
      null => null,
    };
    if (image != null) {
      final tile = ClipRRect(
        borderRadius: theme.radii.small,
        child: Image(
          image: image,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (context, _, _) => _placeholder(theme),
        ),
      );
      if (size == null) {
        return AspectRatio(aspectRatio: aspectRatio, child: tile);
      }
      return SizedBox.square(dimension: size, child: tile);
    }

    final tile = _placeholder(theme);
    if (size == null) return AspectRatio(aspectRatio: aspectRatio, child: tile);
    return SizedBox.square(dimension: size, child: tile);
  }

  Widget _placeholder(Theme theme) {
    final hash =
        seed.codeUnits.fold<int>(17, (h, c) => h * 31 + c) & 0x7fffffff;
    final art = _swatches[hash % _swatches.length];
    final glyph = _glyphs[kind]!;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: theme.radii.small,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [art.s500, art.s900],
        ),
        border: Border.all(color: art.s300.withValues(alpha: 0.25)),
      ),
      // Scaled by fit rather than measured — a LayoutBuilder here would
      // bar the tile from IntrinsicHeight rows.
      child: Center(
        child: FractionallySizedBox(
          widthFactor: 0.44,
          heightFactor: 0.44,
          child: FittedBox(
            child: Icon(glyph, color: art.s200.withValues(alpha: 0.85)),
          ),
        ),
      ),
    );
  }
}
