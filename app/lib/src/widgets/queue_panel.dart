import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

import '../model/player.dart';
import '../util/format.dart';
import 'row_surface.dart';

/// The deck's run, in the trailing sidebar — whatever is playing, not
/// just music: the audio queue while it reigns (tap to jump, grip to
/// rearrange), or the opened film or book standing alone. Shuffle and
/// repeat live up here — they are the queue's moods, not any one
/// kind's controls.
class QueuePanel extends StatelessWidget {
  const QueuePanel({required this.player, super.key});

  final PlaybackController player;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final run = player.run;
        // Only the audio queue rearranges; a run of one just stands.
        final reordering = player.opened == null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                theme.space.x4,
                theme.space.x2,
                theme.space.x2,
                theme.space.x1,
              ),
              child: Row(
                children: [
                  const KickerText('Queue'),
                  SizedBox(width: theme.space.x2),
                  Expanded(
                    child: Text(
                      '${run.length} ${run.length == 1 ? 'item' : 'items'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.typography.caption.copyWith(
                        color: theme.palette.text.withValues(
                          alpha: theme.opacities.secondary,
                        ),
                      ),
                    ),
                  ),
                  _QueueToggle(
                    icon: LucideIcons.shuffle,
                    label: 'Shuffle',
                    on: player.shuffle,
                    onPressed: player.toggleShuffle,
                  ),
                  _QueueToggle(
                    icon: player.repeat == LoopMode.one
                        ? LucideIcons.repeat1
                        : LucideIcons.repeat,
                    label: switch (player.repeat) {
                      LoopMode.off => 'Repeat',
                      LoopMode.all => 'Repeating all',
                      LoopMode.one => 'Repeating this track',
                    },
                    on: player.repeat != LoopMode.off,
                    onPressed: player.cycleRepeat,
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: ReorderableList(
                padding: EdgeInsets.symmetric(
                  horizontal: theme.space.x2,
                  vertical: theme.space.x1,
                ),
                itemCount: run.length,
                onReorderItem: reordering ? player.reorder : (_, _) {},
                // The flying row gets a solid coat, or it would drag its
                // words bare over the rows beneath.
                proxyDecorator: (child, index, animation) => RowSurface(
                  swatch: SemanticSwatch.neutral,
                  variant: SurfaceVariant.soft,
                  child: child,
                ),
                itemBuilder: (context, index) => _QueueRow(
                  key: ValueKey(run[index].id),
                  item: run[index],
                  index: index,
                  player: player,
                  grip: reordering,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Shuffle and repeat: ghost at rest, softly lit when engaged.
class _QueueToggle extends StatelessWidget {
  const _QueueToggle({
    required this.icon,
    required this.label,
    required this.on,
    required this.onPressed,
  });

  final IconData icon;

  /// What the tooltip says — the verb, or the mood it left on.
  final String label;
  final bool on;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: Text(label),
    child: Button(
      onPressed: onPressed,
      variant: on ? SurfaceVariant.soft : SurfaceVariant.ghost,
      swatch: on ? SemanticSwatch.primary : SemanticSwatch.neutral,
      center: Icon(icon, size: 14),
    ),
  );
}

class _QueueRow extends StatefulWidget {
  const _QueueRow({
    required this.item,
    required this.index,
    required this.player,
    required this.grip,
    super.key,
  });

  final MediaItem item;
  final int index;
  final PlaybackController player;

  /// Whether the run rearranges — the audio queue does, a run of one
  /// doesn't, and the grip goes with it.
  final bool grip;

  @override
  State<_QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends State<_QueueRow> {
  bool _hover = false;

  static const _glyphs = {
    MediaKind.audio: LucideIcons.music4,
    MediaKind.video: LucideIcons.film,
    MediaKind.document: LucideIcons.bookOpen,
    MediaKind.image: LucideIcons.image,
  };

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final palette = theme.palette;
    final metadata = widget.item.metadata;
    final current = widget.player.opened != null
        ? widget.player.opened!.id == widget.item.id
        : widget.player.current?.id == widget.item.id;
    final secondary = palette.text.withValues(alpha: theme.opacities.secondary);

    final (title, byline, trailing) = switch (metadata) {
      AudioMetadata(:final title, :final artist, :final duration) => (
        title,
        artist ?? '',
        formatClock(duration ?? Duration.zero),
      ),
      VideoMetadata(:final title, :final series, :final duration) => (
        title,
        series ?? '',
        formatClock(duration ?? Duration.zero),
      ),
      DocumentMetadata(:final title, :final author, :final pageCount) => (
        title,
        author ?? '',
        pageCount == null ? '' : '$pageCount pp',
      ),
      ImageMetadata(:final title, :final width, :final height) => (
        title ?? '',
        '',
        width != null && height != null ? '$width×$height' : '',
      ),
    };

    final content = Padding(
      padding: EdgeInsets.symmetric(horizontal: theme.space.x2),
      child: SizedBox(
        height: 38,
        child: Row(
          spacing: theme.space.x2,
          children: [
            if (widget.grip)
              // The grip: drag it straight away, no hold needed.
              ReorderableDragStartListener(
                index: widget.index,
                child: MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: SizedBox(
                    width: 20,
                    child: Icon(
                      LucideIcons.gripVertical,
                      size: 14,
                      color: palette.text.withValues(
                        alpha: theme.opacities.tertiary,
                      ),
                    ),
                  ),
                ),
              ),
            Icon(
              current && metadata is AudioMetadata
                  ? LucideIcons.audioLines
                  : _glyphs[metadata.kind],
              size: 14,
              color: current ? palette.primary.s400 : secondary,
            ),
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
                      fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (byline.isNotEmpty)
                    Text(
                      byline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.typography.caption.copyWith(
                        color: secondary,
                      ),
                    ),
                ],
              ),
            ),
            Text(
              trailing,
              style: theme.typography.code.copyWith(
                fontSize: theme.typography.caption.fontSize,
                color: secondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );

    final Widget dressed;
    if (current) {
      dressed = RowSurface(
        swatch: SemanticSwatch.primary,
        variant: SurfaceVariant.soft,
        child: content,
      );
    } else if (_hover) {
      dressed = RowSurface(
        swatch: SemanticSwatch.neutral,
        variant: SurfaceVariant.subtle,
        child: content,
      );
    } else {
      dressed = content;
    }

    // The whole row drags too, after a hold — quick presses stay taps.
    final Widget body = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // The deck sorts out what a tap means for the kind.
        onTap: () => widget.player.open(widget.item),
        child: dressed,
      ),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: theme.space.x1),
      child: widget.grip
          ? ReorderableDelayedDragStartListener(
              index: widget.index,
              child: body,
            )
          : body,
    );
  }
}
