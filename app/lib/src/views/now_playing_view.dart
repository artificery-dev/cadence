import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

import '../model/player.dart';
import '../model/settings.dart';
import '../util/format.dart';
import '../widgets/art_tile.dart';
import '../widgets/lcd.dart';
import '../widgets/video_surface.dart';

/// The main event: sleeve beside the deck's glass. No transport here — the
/// bar along the bottom of the window already owns it. The body is the
/// visualization: click the glass to walk the modes.
///
/// Four fits: wide, the sleeve squares itself to the deck — its top on
/// the kicker's line, its bottom on the glass's. Narrow, the words move in
/// beside a smaller sleeve so the glass keeps the full width. Narrower
/// still, the sleeve takes the whole header — square, full width — with
/// the words left-aligned beneath it. Short, the glass bows out rather
/// than hang off the bottom.
class NowPlayingView extends StatelessWidget {
  const NowPlayingView({
    required this.player,
    required this.settings,
    super.key,
  });

  final PlaybackController player;
  final SettingsModel settings;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([player, settings]),
      builder: (context, _) {
        // A film on the deck takes the stage whole; the sleeve-and-glass
        // face waits underneath for the audio queue's return.
        if (player.opened?.metadata is VideoMetadata) {
          return _FilmStage(player: player);
        }
        final track = player.current;
        if (track == null) {
          return const Center(
            child: EmptyState(
              icon: LucideIcons.music,
              title: TitleText('Nothing playing'),
              message: BodyText('Pick something from the library.'),
            ),
          );
        }
        final theme = ThemeProvider.of(context);
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 880;
            // Below this, sleeve-beside-words has no room for the words.
            final stacked = constraints.maxWidth < 480;
            final showLcd = constraints.maxHeight >= (wide ? 480 : 560);

            final Widget content;
            if (wide && showLcd) {
              // The sleeve takes the deck's exact height, so the bottoms
              // meet on the glass's own line.
              content = IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ArtTile(
                      track.metadata.album ?? track.metadata.title,
                      fileId: track.fileId,
                    ),
                    Spacing(SpaceStep.x8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _Headline(track: track),
                          Spacing(SpaceStep.x5),
                          _LcdBlock(
                            player: player,
                            settings: settings,
                            track: track,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            } else if (stacked) {
              // The sleeve heads the stack, square always — but it pays
              // for the glass: its size is whatever the height budget
              // leaves after the words and the LCD, clamped to the width
              // and centred in it. Rough costs: the headline block, the
              // glass, the gaps, the scroll padding.
              final width = constraints.maxWidth - theme.space.x8 * 2;
              final budget =
                  constraints.maxHeight -
                  theme.space.x8 * 2 -
                  130 -
                  (showLcd ? 250 + theme.space.x5 * 2 : theme.space.x5);
              final artSize = budget.clamp(140.0, width);
              content = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: ArtTile(
                      track.metadata.album ?? track.metadata.title,
                      size: artSize,
                      fileId: track.fileId,
                    ),
                  ),
                  Spacing(SpaceStep.x5),
                  _Headline(track: track),
                  if (showLcd) ...[
                    Spacing(SpaceStep.x5),
                    _LcdBlock(player: player, settings: settings, track: track),
                  ],
                ],
              );
            } else {
              content = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      ArtTile(
                        track.metadata.album ?? track.metadata.title,
                        size: 180,
                        fileId: track.fileId,
                      ),
                      Spacing(SpaceStep.x5),
                      Expanded(child: _Headline(track: track)),
                    ],
                  ),
                  if (showLcd) ...[
                    Spacing(SpaceStep.x6),
                    _LcdBlock(player: player, settings: settings, track: track),
                  ],
                ],
              );
            }

            return Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(theme.space.x8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1000),
                  child: content,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.track});

  final AudioItem track;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const KickerText('Now playing'),
        Spacing(SpaceStep.x2),
        HeadlineText(track.metadata.title),
        TitleText(
          track.metadata.artist ?? '',
          emphasis: TextEmphasis.secondary,
        ),
        Spacing(SpaceStep.x1),
        CaptionText(
          [
            if (track.metadata.album != null) track.metadata.album!,
            if (track.metadata.year != null) '${track.metadata.year}',
          ].join(' · '),
        ),
      ],
    );
  }
}

class _LcdBlock extends StatelessWidget {
  const _LcdBlock({
    required this.player,
    required this.settings,
    required this.track,
  });

  final PlaybackController player;
  final SettingsModel settings;
  final AudioItem track;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final dim = theme.palette.accent.s400.withValues(alpha: 0.55);

    return LcdPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              LcdClock(formatClock(player.position)),
              // The flags yield to the clock: on narrow glass they scale
              // down rather than shove the row over its edge.
              Expanded(
                child: Align(
                  alignment: Alignment.bottomRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${track.metadata.bitrateKbps ?? '—'} KBPS · 44 KHZ',
                          style: TextStyle(fontSize: 11, color: dim),
                        ),
                        Text(
                          'STEREO',
                          style: TextStyle(
                            fontSize: 11,
                            color: dim,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          Spacing(SpaceStep.x3),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: settings.cycleVisualizer,
              child: Visualizer(
                mode: settings.visualizer,
                active: player.playing,
                seed: track.id,
                height: 132,
              ),
            ),
          ),
          Spacing(SpaceStep.x2),
          Row(
            children: [
              Expanded(
                child: Text(
                  'TRACK ${(player.currentIndex + 1).toString().padLeft(2, '0')} / ${player.queue.length}',
                  style: TextStyle(fontSize: 11, color: dim),
                ),
              ),
              Text(
                settings.visualizer.label.toUpperCase(),
                style: TextStyle(fontSize: 11, color: dim, letterSpacing: 2),
              ),
              Expanded(
                child: Text(
                  '-${formatClock(player.currentDuration - player.position)}',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 11, color: dim),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A film's stage: the picture wall to wall — the surface letterboxes
/// itself on black at the film's own proportions, no card, no chrome.
/// The transport bar below owns the controls and the mini card speaks
/// the names.
class _FilmStage extends StatelessWidget {
  const _FilmStage({required this.player});

  final PlaybackController player;

  @override
  Widget build(BuildContext context) => GestureDetector(
    // The cinema gesture: a double tap hands the picture the window.
    onDoubleTap: player.toggleFullscreen,
    child: SizedBox.expand(child: DeckVideoSurface(player: player)),
  );
}
