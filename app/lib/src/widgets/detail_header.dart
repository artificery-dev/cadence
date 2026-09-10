import 'dart:math' as math;

import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

import 'art_tile.dart';

/// One of a detail page's verbs, structured rather than widgetted, so a
/// header can lay it out as a labelled button, an icon button, or a menu
/// row — whatever the room allows.
class DetailAction {
  const DetailAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  /// The page's main verb — solid where the others go ghost.
  final bool primary;
}

/// The head of every detail page: a back button on the shelf-header line,
/// then the art beside the name, the fine print, and the page's verbs —
/// one shape whether the thing is an album, an artist, or a series.
class DetailHeader extends StatelessWidget {
  const DetailHeader({
    required this.onBack,
    required this.art,
    required this.artKind,
    required this.title,
    this.artFileId,
    this.kicker,
    this.subtitle,
    this.caption,
    this.actions = const [],
    this.heroPrefix,
    super.key,
  });

  final VoidCallback onBack;

  /// The seed the stand-in art draws from, and the file whose real cover
  /// to wear when the cache has it.
  final String art;
  final MediaKind artKind;
  final int? artFileId;

  /// The small word above the name — ALBUM, ARTIST, SERIES.
  final String? kicker;
  final String title;

  /// A line under the name that may act (the artist link on an album).
  final Widget? subtitle;

  /// The fine print: year, counts, playtime.
  final String? caption;

  /// The page's verbs — Play first, then the rest in priority order:
  /// when the room runs out, the tail folds into an overflow menu.
  final List<DetailAction> actions;

  /// When set, the art and the title fly: they wear Hero tags
  /// `<prefix>-art` and `<prefix>-title`, matching the grid tile that
  /// opened this page.
  final String? heroPrefix;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            theme.space.x4,
            theme.space.x3,
            theme.space.x4,
            0,
          ),
          child: _BackButton(onBack: onBack),
        ),
        _DetailBlock(header: this, artSize: 168),
        const Divider(),
      ],
    );
  }
}

/// The same head, worn by a sliver: pinned, and folding as the list
/// beneath scrolls — the art shrinks and fades while the whole identity
/// line fades in along the top: back, a small sleeve, the name, then
/// artist, year, and the counts behind their rules. When the window
/// cannot hold them all, the line lets go from the end — the name is
/// the last thing standing, and it ellipsises rather than leaves.
class CollapsingDetailHeader extends SliverPersistentHeaderDelegate {
  const CollapsingDetailHeader({required this.header, this.details = const []});

  /// The full head, borrowed for its fields; its own build never runs.
  final DetailHeader header;

  /// The folded line's fine print, in keeping order — artist, year,
  /// counts — each behind its own rule, dropped from the end when the
  /// room runs out.
  final List<String> details;

  static const _min = 56.0;
  static const _max = 268.0;

  @override
  double get minExtent => _min;

  @override
  double get maxExtent => _max;

  @override
  bool shouldRebuild(covariant CollapsingDetailHeader oldDelegate) =>
      oldDelegate.header != header || oldDelegate.details != details;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final theme = ThemeProvider.of(context);
    final t = (shrinkOffset / (_max - _min)).clamp(0.0, 1.0);
    return ColoredBox(
      color: theme.palette.background,
      child: ClipRect(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: _min - 1,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: theme.space.x4),
                child: Row(
                  children: [
                    _BackButton(onBack: header.onBack),
                    Spacing(SpaceStep.x2, axis: Axis.horizontal),
                    Opacity(
                      opacity: t,
                      child: ArtTile(
                        header.art,
                        kind: header.artKind,
                        size: 32,
                        fileId: header.artFileId,
                      ),
                    ),
                    Spacing(SpaceStep.x2, axis: Axis.horizontal),
                    Expanded(
                      child: Opacity(
                        opacity: t,
                        child: IgnorePointer(
                          ignoring: t < 0.5,
                          child: _CompactLine(
                            title: header.title,
                            details: details,
                            actions: header.actions,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Opacity(
                opacity: 1 - t,
                child: OverflowBox(
                  alignment: Alignment.topCenter,
                  minHeight: 0,
                  maxHeight: _max - _min,
                  child: SizedBox(
                    height: _max - _min,
                    child: _DetailBlock(header: header, artSize: 168 - 64 * t),
                  ),
                ),
              ),
            ),
            const Divider(),
          ],
        ),
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: const Text('Back'),
    child: Button(
      onPressed: onBack,
      variant: SurfaceVariant.ghost,
      swatch: SemanticSwatch.neutral,
      center: const Icon(LucideIcons.arrowLeft, size: 16),
    ),
  );
}

/// The art beside the name, the fine print, and the verbs — the middle
/// of the head, shared by the standing and the folding kinds.
class _DetailBlock extends StatelessWidget {
  const _DetailBlock({required this.header, required this.artSize});

  final DetailHeader header;
  final double artSize;

  /// Wraps [child] as a hero when the header flies; plain otherwise.
  Widget _hero(String suffix, Widget child) => switch (header.heroPrefix) {
    final prefix? => Hero(tag: '$prefix$suffix', child: child),
    null => child,
  };

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        theme.space.x6,
        theme.space.x3,
        theme.space.x6,
        theme.space.x4,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _hero(
            '-art',
            ArtTile(
              header.art,
              kind: header.artKind,
              size: artSize,
              fileId: header.artFileId,
            ),
          ),
          Spacing(SpaceStep.x5, axis: Axis.horizontal),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (header.kicker != null) KickerText(header.kicker!),
                _hero(
                  '-title',
                  Text(
                    header.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.typography.headline,
                  ),
                ),
                if (header.subtitle != null) ...[
                  Spacing(SpaceStep.x1),
                  header.subtitle!,
                ],
                if (header.caption != null) ...[
                  Spacing(SpaceStep.x1),
                  CaptionText(
                    header.caption!,
                    emphasis: TextEmphasis.secondary,
                  ),
                ],
                if (header.actions.isNotEmpty) ...[
                  Spacing(SpaceStep.x3),
                  _ActionsRow(actions: header.actions),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The folded head's one line: the name first, the fine print behind
/// vertical rules, and the verbs at the trailing edge as icon buttons —
/// Play holding the very corner, the overflow ellipsis at its left.
/// Room is measured, not guessed — and when it runs out, the lesser
/// verbs fold into the overflow menu first, then the fine print lets go
/// from the end. Play never folds, and the name never gives up a letter
/// while a word of fine print still stands.
class _CompactLine extends StatelessWidget {
  const _CompactLine({
    required this.title,
    required this.details,
    required this.actions,
  });

  final String title;
  final List<String> details;
  final List<DetailAction> actions;

  /// What one icon verb truly stands on the line: the ghost button's own
  /// box, measured — lowball this and the layout squeezes the title to
  /// pay for the shortfall before a single verb folds.
  static const _buttonCost = 48.0;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final titleStyle = theme.typography.title;
    final detailStyle = theme.typography.caption;
    final secondary = theme.palette.text.withValues(
      alpha: theme.opacities.secondary,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = theme.space.x3;

        // The first verb — Play — is nailed to the corner and never
        // measured against anything; only the rest can fold.
        final primary = actions.firstOrNull;
        final rest = actions.skip(1).toList();

        // The name claims its full room first; each detail then costs
        // its text plus a rule and the gaps around it.
        final name = _textWidth(title, titleStyle);
        final segmentCosts = [
          for (final piece in details)
            _textWidth(piece, detailStyle) + gap * 2 + 1,
        ];
        final infoAll = name + segmentCosts.fold(0.0, (a, b) => a + b);
        final corner = primary == null ? 0.0 : _buttonCost;
        final max = constraints.maxWidth;

        // The lesser verbs yield first: as many stay out as fit BESIDE
        // the full fine print; the rest fold behind the ellipsis. Only
        // once every one has folded does the fine print start letting
        // go — and only when the fine print is gone entirely may the
        // name lose a letter.
        var fitted = details.length;
        var shown = rest.length;
        if (infoAll + corner + shown * _buttonCost > max) {
          final room = max - infoAll - corner;
          shown = room >= _buttonCost
              ? math.max(0, ((room - _buttonCost) / _buttonCost).floor())
              : 0;
          if (shown >= rest.length) shown = rest.length - 1;
          var budget = max - corner - _buttonCost - shown * _buttonCost - name;
          fitted = 0;
          for (final cost in segmentCosts) {
            if (budget < cost) break;
            budget -= cost;
            fitted++;
          }
        }
        final visible = rest.take(shown).toList();
        final folded = rest.skip(shown).toList();

        Widget verb(DetailAction action) => Tooltip(
          message: Text(action.label),
          child: Button(
            onPressed: action.onPressed,
            variant: SurfaceVariant.ghost,
            swatch: action.primary
                ? SemanticSwatch.primary
                : SemanticSwatch.neutral,
            center: Icon(action.icon, size: 16),
          ),
        );

        // One Expanded group for the words, so the row's slack pools
        // inside it and never leaks past the verbs: a loose Flexible
        // beside a Spacer would keep its unused share as a dead gap at
        // the row's end, floating the buttons off the edge.
        return Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle,
                    ),
                  ),
                  for (final piece in details.take(fitted)) ...[
                    SizedBox(width: gap),
                    const SizedBox(
                      height: 16,
                      child: Divider(axis: Axis.vertical),
                    ),
                    SizedBox(width: gap),
                    Text(
                      piece,
                      maxLines: 1,
                      style: detailStyle.copyWith(color: secondary),
                    ),
                  ],
                ],
              ),
            ),
            // Reversed, so the higher a verb's standing, the nearer the
            // corner it sits — with the ellipsis just left of Play.
            for (final action in visible.reversed) verb(action),
            if (folded.isNotEmpty) _OverflowActions(actions: folded),
            if (primary != null) verb(primary),
          ],
        );
      },
    );
  }
}

/// The full head's verbs as labelled buttons, folding from the tail into
/// the overflow menu when the column runs out of room.
class _ActionsRow extends StatelessWidget {
  const _ActionsRow({required this.actions});

  final List<DetailAction> actions;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = theme.space.x2;
        // Icon, its gap, the button's own padding, then the word.
        double cost(DetailAction action) =>
            _textWidth(action.label, theme.typography.body) + 56 + gap;

        var shown = actions.length;
        var used = 0.0;
        for (final (index, action) in actions.indexed) {
          used += cost(action);
          if (used > constraints.maxWidth - 40) {
            shown = index;
            break;
          }
        }
        final visible = actions.take(shown).toList();
        final folded = actions.skip(shown).toList();

        return Row(
          spacing: gap,
          children: [
            for (final action in visible)
              Button(
                onPressed: action.onPressed,
                variant: action.primary
                    ? SurfaceVariant.solid
                    : SurfaceVariant.ghost,
                swatch: action.primary
                    ? SemanticSwatch.primary
                    : SemanticSwatch.neutral,
                center: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(action.icon, size: 14),
                    const SizedBox(width: 6),
                    Text(action.label),
                  ],
                ),
              ),
            if (folded.isNotEmpty) _OverflowActions(actions: folded),
          ],
        );
      },
    );
  }
}

/// The ellipsis at the end of a crowded row: the verbs that didn't fit,
/// kept whole behind a menu.
class _OverflowActions extends StatefulWidget {
  const _OverflowActions({required this.actions});

  final List<DetailAction> actions;

  @override
  State<_OverflowActions> createState() => _OverflowActionsState();
}

class _OverflowActionsState extends State<_OverflowActions> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => Menu(
    open: _open,
    onDismiss: () => setState(() => _open = false),
    align: PopoverAlign.end,
    entries: [
      for (final action in widget.actions)
        MenuItem(
          label: Text(action.label),
          leading: Icon(action.icon, size: 14),
          onPressed: () {
            setState(() => _open = false);
            action.onPressed();
          },
        ),
    ],
    anchor: Tooltip(
      message: const Text('More'),
      child: Button(
        onPressed: () => setState(() => _open = !_open),
        variant: SurfaceVariant.ghost,
        swatch: SemanticSwatch.neutral,
        center: const Icon(LucideIcons.ellipsis, size: 16),
      ),
    ),
  );
}

double _textWidth(String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  return painter.width;
}
