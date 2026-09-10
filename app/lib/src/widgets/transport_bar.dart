import 'package:cadence_media/cadence_media.dart';
import 'package:flutter/scheduler.dart';
import 'package:tomeui/tomeui.dart';

import '../model/player.dart';
import '../util/format.dart';
import 'art_tile.dart';
import 'shelf_actions.dart';

/// The deck across the bottom of every view. The band itself is an
/// ordinary surface under the body's frame; the seek line is not in it
/// at all — it floats in the app's overlay, tied to the band's top edge
/// by a [LayerLink], so its centreline rides the body's bottom hairline
/// with the knob's upper half genuinely over the page. Living in the
/// overlay, the whole knob takes the pointer, and the page — sidebars,
/// frame, and all — runs beneath it untouched.
///
/// The deck wears one face per media kind — transport for the listening
/// and watching kinds, page turns for the reading ones — and asks the
/// player which via [PlaybackController.deckKind]. When the answer
/// changes, the whole band slides off the bottom, swaps its controls,
/// and slides back in.
///
/// Under the seek line, wide reads left to right: what's on the deck ·
/// the controls between their rules · the kind's small talk at the
/// trailing end. Compact folds at those seams into two rows.
class TransportBar extends StatefulWidget implements SelfDressedBar {
  const TransportBar({required this.player, super.key});

  final PlaybackController player;

  /// Where the one-line layout folds. The theme's compact breakpoint is
  /// about content; this is about our buttons — the cluster's intrinsic
  /// width plus the trailing group plus the mini card's floor (the art
  /// never shrinks), with headroom so no flex share ever starves it.
  static const _fold = 660.0;

  /// How deep the floating slider reaches into the band: its lower half.
  /// The band keeps this much clear above its buttons.
  static const _overhang = _ScrubberStrip.height / 2;

  /// One leg of the swap — off, or back on. The full change is two.
  static const swapDuration = Duration(milliseconds: 180);

  @override
  State<TransportBar> createState() => _TransportBarState();
}

class _TransportBarState extends State<TransportBar>
    with SingleTickerProviderStateMixin {
  /// The tie between the band's top-left corner and the floating strip.
  final LayerLink _seam = LayerLink();
  final OverlayPortalController _scrubber = OverlayPortalController();

  /// 0 is on stage, 1 is off the bottom. Forward to leave, reverse to
  /// return with the new face on.
  late final AnimationController _swap = AnimationController(
    vsync: this,
    duration: TransportBar.swapDuration,
  );

  /// The face the band is wearing right now — it lags the player's
  /// [PlaybackController.deckKind] by the slide.
  late MediaKind _shownKind = widget.player.deckKind;

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_maybeSwap);
    // After the first frame: a portal can't be shown mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrubber.show();
    });
  }

  @override
  void dispose() {
    widget.player.removeListener(_maybeSwap);
    _swap.dispose();
    super.dispose();
  }

  void _maybeSwap() {
    if (!mounted) return;
    if (widget.player.deckKind == _shownKind) return;
    // Mid-slide, the landing check below picks the change up.
    if (_swap.isAnimating) return;
    _runSwap();
  }

  Future<void> _runSwap() async {
    await _swap.forward();
    if (!mounted) return;
    setState(() => _shownKind = widget.player.deckKind);
    await _swap.reverse();
    if (!mounted) return;
    // The deck changed hands again while we slid — go around once more.
    if (widget.player.deckKind != _shownKind) _runSwap();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final scaffoldStyle = theme.widgets.scaffold.resolve();
    final player = widget.player;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) => SlideTransition(
        // The strip in the overlay follows the band's transform through
        // the seam link, so the whole deck — knob and all — leaves and
        // returns as one piece.
        position: _swap.drive(
          Tween(
            begin: Offset.zero,
            end: const Offset(0, 1.2),
          ).chain(CurveTween(curve: Curves.easeInOut)),
        ),
        child: CompositedTransformTarget(
          link: _seam,
          child: OverlayPortal(
            controller: _scrubber,
            overlayChildBuilder: (context) => LayoutBuilder(
              // The band always spans the window, and so does the overlay:
              // its width is the strip's width.
              builder: (context, constraints) => Align(
                alignment: Alignment.topLeft,
                child: CompositedTransformFollower(
                  link: _seam,
                  showWhenUnlinked: false,
                  targetAnchor: Alignment.topLeft,
                  followerAnchor: Alignment.centerLeft,
                  child: SizedBox(
                    width: constraints.maxWidth,
                    height: _ScrubberStrip.height,
                    child: _ScrubberStrip(player: player),
                  ),
                ),
              ),
            ),
            child: Surface.custom(
              style: scaffoldStyle.bar,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: TransportBar._overhang),
                  Padding(
                    padding: scaffoldStyle.barPadding.add(
                      EdgeInsets.only(bottom: theme.space.x2),
                    ),
                    child: LayoutBuilder(
                      builder: (context, constraints) =>
                          constraints.maxWidth < TransportBar._fold
                          ? _CompactControls(player: player, kind: _shownKind)
                          : _WideControls(player: player, kind: _shownKind),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The seek line astride the band's seam: floated in the overlay by its
/// band, its centreline resting exactly on the body's bottom hairline,
/// the knob's upper half over the page — and every pixel of it taking
/// the pointer. One line for every kind: the clock's fraction while
/// something runs, the page's while something is read; the player sorts
/// out which a drag means.
class _ScrubberStrip extends StatefulWidget {
  const _ScrubberStrip({required this.player});

  /// The slider's full box.
  static const height = 24.0;

  final PlaybackController player;

  @override
  State<_ScrubberStrip> createState() => _ScrubberStripState();
}

class _ScrubberStripState extends State<_ScrubberStrip>
    with SingleTickerProviderStateMixin {
  /// While something runs the strip repaints every frame, reading the
  /// deck's extrapolated clock — the needle glides. Paused, the ticker
  /// rests and the strip is as still as any other widget.
  late final Ticker _frames = createTicker((_) => setState(() {}));

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_syncTicker);
    _syncTicker();
  }

  void _syncTicker() {
    final playing = widget.player.playing;
    if (playing && !_frames.isActive) _frames.start();
    if (!playing && _frames.isActive) _frames.stop();
  }

  @override
  void dispose() {
    widget.player.removeListener(_syncTicker);
    _frames.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final player = widget.player;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: theme.space.x3),
      child: Slider(
        value: player.progress,
        onChanged: player.seekTo,
        style: _style(theme),
      ),
    );
  }

  /// The theme's slider, tuned for the strip: slim, a groove that shows on
  /// the bar (the stock one is cut into the page, invisible here), and the
  /// knob in solid primary — the stock knob is the contrast colour, which
  /// reads white, not primary.
  static SliderStyle _style(Theme theme) {
    const pill = BorderRadius.all(Radius.circular(999));
    final base = theme.widgets.slider.resolve();
    return base.copyWith(
      height: _ScrubberStrip.height,
      thumbSize: 14,
      inactive: base.inactive.copyWith(
        fill: theme.palette.text.withValues(alpha: theme.opacities.divider),
      ),
      thumb: theme.widgets.surface
          .resolve(SemanticSwatch.primary, SurfaceVariant.solid)
          .copyWith(radius: pill),
    );
  }
}

class _WideControls extends StatelessWidget {
  const _WideControls({required this.player, required this.kind});

  final PlaybackController player;
  final MediaKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final scaffoldStyle = theme.widgets.scaffold.resolve();
    // The card wears the sidebar's width: gap, card, gap together span
    // exactly what the column above spans, so the two read as one edge.
    final wellWidth =
        scaffoldStyle.sidebarWidth - scaffoldStyle.barPadding.horizontal;
    // Three stations: the deck's card holds the start, the trailing
    // buttons hold the end, and the controls stand between their rules —
    // the rules ride with the cluster, so the slack opens only in the two
    // outer gaps. The card is the one loose piece; what it leaves widens
    // those gaps equally.
    return SizedBox(
      height: 48,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        spacing: theme.space.x2,
        children: [
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: wellWidth),
              child: _MiniCard.forDeck(player) ?? SizedBox(width: wellWidth),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            spacing: theme.space.x2,
            children: [
              const _Rule(),
              _ControlCluster(player: player, kind: kind),
              const _Rule(),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            spacing: theme.space.x2,
            children: _trailing(player, kind),
          ),
        ],
      ),
    );
  }
}

/// The groups folded at the seams the rules mark: the card and small talk
/// up top, the controls below. The scrubber already rides the edge.
class _CompactControls extends StatelessWidget {
  const _CompactControls({required this.player, required this.kind});

  final PlaybackController player;
  final MediaKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          spacing: theme.space.x2,
          children: [
            Expanded(
              child: _MiniCard.forDeck(player) ?? const SizedBox.shrink(),
            ),
            ..._trailing(player, kind),
          ],
        ),
        Spacing(SpaceStep.x2),
        // Scale down before clipping: on a truly tiny window the whole
        // cluster shrinks together rather than losing its ends.
        Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: _ControlCluster(player: player, kind: kind),
          ),
        ),
      ],
    );
  }
}

/// The kind's small talk at the trailing end — the listening kinds keep
/// the volume; the rest wait for their features.
List<Widget> _trailing(PlaybackController player, MediaKind kind) =>
    switch (kind) {
      MediaKind.audio => [
        const _SomedayButton(icon: LucideIcons.micVocal, label: 'Lyrics'),
        _VolumeButton(player: player),
      ],
      MediaKind.video => [
        const _SomedayButton(icon: LucideIcons.captions, label: 'Subtitles'),
        _FullscreenButton(player: player),
        _VolumeButton(player: player),
      ],
      MediaKind.document => [
        const _SomedayButton(icon: LucideIcons.bookmark, label: 'Bookmarks'),
      ],
      MediaKind.image => [
        const _SomedayButton(icon: LucideIcons.info, label: 'Details'),
      ],
    };

/// The centre station: one control set per kind of media, swapped whole
/// when the deck changes hands.
class _ControlCluster extends StatelessWidget {
  const _ControlCluster({required this.player, required this.kind});

  final PlaybackController player;
  final MediaKind kind;

  @override
  Widget build(BuildContext context) => switch (kind) {
    MediaKind.audio => _AudioTransport(player: player),
    MediaKind.video => _VideoTransport(player: player),
    MediaKind.document => _PageControls(player: player),
    MediaKind.image => const _ImageControls(),
  };
}

/// A group seam on the wide row — and the fold line the compact layout
/// breaks at.
class _Rule extends StatelessWidget {
  const _Rule();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(height: 24, child: Divider(axis: Axis.vertical));
}

/// The listening face: skip back · back 10s · play · forward 10s · skip
/// forward. When the current track carries chapters — an audiobook —
/// the outer buttons hop chapters instead of tracks. Shuffle and repeat
/// live on the queue's header now.
class _AudioTransport extends StatelessWidget {
  const _AudioTransport({required this.player});

  final PlaybackController player;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final chaptered = player.stops.isNotEmpty;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: theme.space.x1,
      children: [
        _TransportButton(
          icon: LucideIcons.skipBack,
          label: chaptered ? 'Previous chapter' : 'Previous',
          onPressed: chaptered ? player.previousStop : player.previous,
        ),
        _TransportButton(
          icon: LucideIcons.rotateCcw,
          label: 'Back 10 seconds',
          onPressed: () => player.skipBy(const Duration(seconds: -10)),
        ),
        _PlayButton(player: player),
        _TransportButton(
          icon: LucideIcons.rotateCw,
          label: 'Ahead 10 seconds',
          onPressed: () => player.skipBy(const Duration(seconds: 10)),
        ),
        _TransportButton(
          icon: LucideIcons.skipForward,
          label: chaptered ? 'Next chapter' : 'Next',
          onPressed: chaptered ? player.nextStop : player.next,
        ),
      ],
    );
  }
}

/// The watching face: the clock hops and the play button — and when the
/// film carries scene stops, the outer seats the music face keeps come
/// back as scene hops.
class _VideoTransport extends StatelessWidget {
  const _VideoTransport({required this.player});

  final PlaybackController player;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final scenes = player.stops.isNotEmpty;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: theme.space.x1,
      children: [
        if (scenes)
          _TransportButton(
            icon: LucideIcons.skipBack,
            label: 'Previous scene',
            onPressed: player.previousStop,
          ),
        _TransportButton(
          icon: LucideIcons.rotateCcw,
          label: 'Back 10 seconds',
          onPressed: () => player.skipBy(const Duration(seconds: -10)),
        ),
        _PlayButton(player: player),
        _TransportButton(
          icon: LucideIcons.rotateCw,
          label: 'Ahead 10 seconds',
          onPressed: () => player.skipBy(const Duration(seconds: 10)),
        ),
        if (scenes)
          _TransportButton(
            icon: LucideIcons.skipForward,
            label: 'Next scene',
            onPressed: player.nextStop,
          ),
      ],
    );
  }
}

/// The reading face: covers at the ends, single leaves inside, and the
/// reader itself still to come.
class _PageControls extends StatelessWidget {
  const _PageControls({required this.player});

  final PlaybackController player;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: theme.space.x1,
      children: [
        _TransportButton(
          icon: LucideIcons.chevronsLeft,
          label: 'First page',
          onPressed: () => player.turnPage(-player.pageCount),
        ),
        _TransportButton(
          icon: LucideIcons.chevronLeft,
          label: 'Previous page',
          onPressed: () => player.turnPage(-1),
        ),
        const _SomedayButton(icon: LucideIcons.bookOpen, label: 'Reader'),
        _TransportButton(
          icon: LucideIcons.chevronRight,
          label: 'Next page',
          onPressed: () => player.turnPage(1),
        ),
        _TransportButton(
          icon: LucideIcons.chevronsRight,
          label: 'Last page',
          onPressed: () => player.turnPage(player.pageCount),
        ),
      ],
    );
  }
}

/// The looking face: a picture needs no transport — the verbs it will
/// have (a slideshow) aren't built yet, and the deck says so.
class _ImageControls extends StatelessWidget {
  const _ImageControls();

  @override
  Widget build(BuildContext context) =>
      const _SomedayButton(icon: LucideIcons.play, label: 'Slideshow');
}

/// Play/pause, shared by every face with a clock.
class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.player});

  final PlaybackController player;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: Text(player.playing ? 'Pause' : 'Play'),
    child: Button(
      onPressed: player.toggle,
      center: Icon(
        player.playing ? LucideIcons.pause : LucideIcons.play,
        size: 18,
      ),
    ),
  );
}

/// A feature's seat, held before the feature: disabled, but it still
/// explains itself.
class _SomedayButton extends StatelessWidget {
  const _SomedayButton({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: Text('$label, someday'),
    child: Button(
      onPressed: null,
      variant: SurfaceVariant.ghost,
      swatch: SemanticSwatch.neutral,
      center: Icon(icon, size: 16),
    ),
  );
}

/// The picture, given (or handed back) the whole window.
class _FullscreenButton extends StatelessWidget {
  const _FullscreenButton({required this.player});

  final PlaybackController player;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: Text(player.fullscreen ? 'Exit fullscreen' : 'Fullscreen'),
    child: Button(
      onPressed: player.toggleFullscreen,
      variant: player.fullscreen ? SurfaceVariant.soft : SurfaceVariant.ghost,
      swatch: player.fullscreen
          ? SemanticSwatch.primary
          : SemanticSwatch.neutral,
      center: Icon(
        player.fullscreen ? LucideIcons.minimize : LucideIcons.maximize,
        size: 16,
      ),
    ),
  );
}

/// Volume as a flyout: the bar keeps a button; above it stands a fader
/// with the mute at its foot.
class _VolumeButton extends StatefulWidget {
  const _VolumeButton({required this.player});

  final PlaybackController player;

  @override
  State<_VolumeButton> createState() => _VolumeButtonState();
}

class _VolumeButtonState extends State<_VolumeButton> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    return Popover(
      open: _open,
      side: PopoverSide.top,
      onDismiss: () => setState(() => _open = false),
      anchor: Tooltip(
        message: const Text('Volume'),
        child: Button(
          onPressed: () => setState(() => _open = !_open),
          variant: _open ? SurfaceVariant.soft : SurfaceVariant.ghost,
          swatch: _open ? SemanticSwatch.primary : SemanticSwatch.neutral,
          center: Icon(
            player.muted || player.volume == 0
                ? LucideIcons.volumeX
                : player.volume < 0.5
                ? LucideIcons.volume1
                : LucideIcons.volume2,
            size: 16,
          ),
        ),
      ),
      content: (context, anchor) => Inset.all(
        SpaceStep.x2,
        child: ListenableBuilder(
          listenable: player,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 120,
                child: Slider(
                  axis: Axis.vertical,
                  value: player.audibleVolume,
                  onChanged: (value) => player.volume = value,
                ),
              ),
              Spacing(SpaceStep.x2),
              Tooltip(
                message: Text(player.muted ? 'Unmute' : 'Mute'),
                child: Button(
                  onPressed: player.toggleMute,
                  variant: player.muted
                      ? SurfaceVariant.soft
                      : SurfaceVariant.ghost,
                  swatch: player.muted
                      ? SemanticSwatch.primary
                      : SemanticSwatch.neutral,
                  center: const Icon(LucideIcons.volumeOff, size: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the deck holds, in its own framed well — art first, then the
/// words, the kind's own measure holding the right edge. The door to
/// the queue by name: a tap opens the panel with the Queue tab in
/// front, and only when the queue is already the tab showing does the
/// same tap put the panel away. Kind-blind by construction: it's built
/// from whatever the player says is on the deck.
class _MiniCard extends StatelessWidget {
  const _MiniCard({
    required this.artSeed,
    required this.artKind,
    required this.fileId,
    required this.title,
    required this.byline,
    required this.trailing,
  });

  /// The deck's card as the player tells it: the opened item whatever
  /// its kind, the current track while the queue reigns, or nothing.
  static Widget? forDeck(PlaybackController player) {
    if (player.opened case final item?) {
      final (byline, trailing) = switch (item.metadata) {
        VideoMetadata(:final series, :final year) => (
          series ?? (year == null ? '' : '$year'),
          _remaining(player),
        ),
        DocumentMetadata(:final author, :final series) => (
          author ?? series ?? '',
          player.pageCount == 0
              ? ''
              : 'p. ${player.page + 1} / ${player.pageCount}',
        ),
        ImageMetadata(:final width, :final height) => (
          width != null && height != null ? '$width×$height' : '',
          '',
        ),
        AudioMetadata(:final artist) => (artist ?? '', _remaining(player)),
      };
      final title = switch (item.metadata) {
        AudioMetadata(:final title) => title,
        VideoMetadata(:final title) => title,
        DocumentMetadata(:final title) => title,
        ImageMetadata(:final title) => title ?? '',
      };
      return _MiniCard(
        artSeed: title,
        artKind: item.metadata.kind,
        fileId: item.fileId,
        title: title,
        byline: byline,
        trailing: trailing,
      );
    }
    final track = player.current;
    if (track == null) return null;
    return _MiniCard(
      artSeed: track.metadata.album ?? track.metadata.title,
      artKind: MediaKind.audio,
      fileId: track.fileId,
      title: track.metadata.title,
      byline: track.metadata.artist ?? '',
      trailing: _remaining(player),
    );
  }

  static String _remaining(PlaybackController player) {
    final remaining = player.currentDuration - player.position;
    return '-${formatClock(remaining.isNegative ? Duration.zero : remaining)}';
  }

  final String artSeed;
  final MediaKind artKind;
  final int? fileId;
  final String title;
  final String byline;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final palette = theme.palette;
    // Absent in the fullscreen layout, where there is no sidebar to ask
    // for — the card just shows there.
    final scaffold = ScaffoldStateProvider.maybeOf(context);
    final actions = ShelfActions.maybeOf(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (scaffold == null) return;
          final queueShowing =
              scaffold.trailing.open && (actions?.queueTab ?? true);
          if (queueShowing) {
            scaffold.close(ScaffoldSide.trailing);
          } else {
            actions?.revealQueue();
            scaffold.open(ScaffoldSide.trailing);
          }
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: palette.background,
            borderRadius: theme.radii.small,
            border: Border.all(
              color: palette.text.withValues(alpha: theme.opacities.divider),
            ),
          ),
          child: Padding(
            // The row stands 48 and the art 36; with the hairline on
            // both sides, five all round is what "even" measures to.
            padding: const EdgeInsets.all(5),
            child: Row(
              spacing: theme.space.x2,
              children: [
                ArtTile(artSeed, kind: artKind, size: 36, fileId: fileId),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.typography.bodySmall.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        byline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.typography.caption.copyWith(
                          color: palette.text.withValues(
                            alpha: theme.opacities.secondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (trailing.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(right: theme.space.x1),
                    child: Text(
                      trailing,
                      style: theme.typography.code.copyWith(
                        fontSize: theme.typography.caption.fontSize,
                        color: palette.text.withValues(
                          alpha: theme.opacities.secondary,
                        ),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TransportButton extends StatelessWidget {
  const _TransportButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;

  /// What the tooltip says about the glyph.
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: Text(label),
    child: Button(
      onPressed: onPressed,
      variant: SurfaceVariant.ghost,
      swatch: SemanticSwatch.neutral,
      center: Icon(icon, size: 16),
    ),
  );
}
