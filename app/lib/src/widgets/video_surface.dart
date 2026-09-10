import 'package:tomeui/tomeui.dart';

import '../model/player.dart';

/// The deck's picture, wherever it shows — the Now Playing stage or the
/// pip window. The engine draws when it can; without eyes (tests, no
/// engine) a dark stand-in with the watching glyph holds the frame.
class DeckVideoSurface extends StatelessWidget {
  const DeckVideoSurface({required this.player, super.key});

  final PlaybackController player;

  @override
  Widget build(BuildContext context) {
    final surface = player.videoSurface(context);
    if (surface != null) return surface;
    return const ColoredBox(
      color: Color(0xFF000000),
      child: Center(
        child: Icon(LucideIcons.film, size: 48, color: Color(0x66FFFFFF)),
      ),
    );
  }
}

/// The film, folded into a corner: shown over every view but Now
/// Playing while a video holds the deck, so leaving the stage never
/// means losing the picture. A tap walks back to the stage.
class PipWindow extends StatelessWidget {
  const PipWindow({required this.player, required this.onTap, super.key});

  /// For tests to find the floating window without chasing paint.
  static const pipKey = Key('pip-window');

  final PlaybackController player;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return Tooltip(
      message: const Text('Back to Now Playing'),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: DecoratedBox(
            key: pipKey,
            decoration: BoxDecoration(
              borderRadius: theme.radii.medium,
              border: Border.all(
                color: theme.palette.text.withValues(
                  alpha: theme.opacities.divider,
                ),
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x55000000),
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: theme.radii.medium,
              child: SizedBox(
                width: 256,
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: DeckVideoSurface(player: player),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
