import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

import '../model/view_prefs.dart';
import 'item_tap.dart';
import 'row_surface.dart';

/// One column a [MediaTable] can show: identity, header, width, how a
/// row's value renders, and what it sorts by.
class MediaColumn<T> {
  const MediaColumn({
    required this.id,
    required this.label,
    required this.cell,
    this.sortKey,
    this.flex = 3,
    this.width,
    this.numeric = false,
    this.defaultVisible = true,
  });

  final String id;

  /// The header word, spoken lowercase here and shouted by the style.
  final String label;

  /// The cell, given the row's item. Ellipsise your own overflow.
  final Widget Function(BuildContext context, T item) cell;

  /// What this column orders by — null and the header won't offer.
  final Comparable<Object?>? Function(T item)? sortKey;

  /// [width] pins the column; otherwise [flex] shares the slack.
  final int flex;
  final double? width;

  /// Right-aligned, the way numbers sit.
  final bool numeric;

  /// Shown before anyone has chosen columns.
  final bool defaultVisible;
}

/// The table half of a shelf: a sortable header over zebra-striped rows.
///
/// Sorting: a header tap orders by that column, a second tap turns it
/// around, and the shelf's own order is `sortColumn == null`. Columns:
/// a right-click on the header offers the roster with checks; at least
/// one column always survives. Both choices land in [prefs] through
/// [onPrefs] — the caller persists them.
class MediaTable<T> extends StatefulWidget {
  const MediaTable({
    required this.columns,
    required this.items,
    required this.prefs,
    required this.onPrefs,
    this.onActivate,
    this.isCurrent,
    this.itemOf,
    this.primary = false,
    super.key,
  });

  /// Every column the table could show, in roster order.
  final List<MediaColumn<T>> columns;

  /// The shelf, in its own natural order.
  final List<T> items;

  final ViewPrefs prefs;
  final void Function(ViewPrefs prefs) onPrefs;

  /// A row was chosen — what "to the deck" means for this table.
  final void Function(T item)? onActivate;

  /// Which row wears the primary dress — the one on the deck.
  final bool Function(T item)? isCurrent;

  /// The [MediaItem] behind a row. With it, rows speak the full shelf
  /// grammar (inspect on click, open on double-click, enqueue while the
  /// queue shows); without it, a single tap activates as ever.
  final MediaItem Function(T item)? itemOf;

  /// Hands the list to the nearest PrimaryScrollController — what a
  /// NestedScrollView needs to fold its header as this scrolls.
  final bool primary;

  @override
  State<MediaTable<T>> createState() => _MediaTableState<T>();
}

class _MediaTableState<T> extends State<MediaTable<T>> {
  bool _columnsOpen = false;

  List<MediaColumn<T>> get _visible {
    final chosen = widget.prefs.columns;
    if (chosen == null) {
      return [
        for (final column in widget.columns)
          if (column.defaultVisible) column,
      ];
    }
    final byId = {for (final column in widget.columns) column.id: column};
    final picked = [for (final id in chosen) ?byId[id]];
    return picked.isEmpty ? [widget.columns.first] : picked;
  }

  List<T> get _sorted {
    final id = widget.prefs.sortColumn;
    if (id == null) return widget.items;
    final column = widget.columns
        .where((c) => c.id == id && c.sortKey != null)
        .firstOrNull;
    if (column == null) return widget.items;
    // Decorated with the shelf position, so equal keys keep their order
    // and nulls sink to the bottom whichever way the sort runs.
    final decorated = [for (final (i, item) in widget.items.indexed) (i, item)];
    final sign = widget.prefs.sortAscending ? 1 : -1;
    decorated.sort((a, b) {
      final ka = column.sortKey!(a.$2);
      final kb = column.sortKey!(b.$2);
      if (ka == null && kb == null) return a.$1 - b.$1;
      if (ka == null) return 1;
      if (kb == null) return -1;
      final byKey = ka.compareTo(kb) * sign;
      return byKey != 0 ? byKey : a.$1 - b.$1;
    });
    return [for (final (_, item) in decorated) item];
  }

  void _sortBy(MediaColumn<T> column) {
    if (column.sortKey == null) return;
    final prefs = widget.prefs;
    widget.onPrefs(
      prefs.sortColumn == column.id
          ? prefs.copyWith(sortAscending: !prefs.sortAscending)
          : prefs.copyWith(sortColumn: () => column.id, sortAscending: true),
    );
  }

  void _toggleColumn(MediaColumn<T> column) {
    final visible = [for (final c in _visible) c.id];
    final next = visible.contains(column.id)
        ? [
            for (final id in visible)
              if (id != column.id) id,
          ]
        : [
            // Freshly shown columns take their roster seat, not the end.
            for (final c in widget.columns)
              if (visible.contains(c.id) || c.id == column.id) c.id,
          ];
    if (next.isEmpty) return;
    widget.onPrefs(widget.prefs.copyWith(columns: next));
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final visible = _visible;
    final sorted = _sorted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(theme, visible),
        const Divider(),
        Expanded(
          child: ListView.separated(
            primary: widget.primary ? true : null,
            padding: EdgeInsets.fromLTRB(
              theme.space.x3,
              theme.space.x2,
              theme.space.x3,
              theme.space.x3,
            ),
            itemCount: sorted.length,
            separatorBuilder: (context, _) => SizedBox(height: theme.space.x1),
            itemBuilder: (context, index) => _MediaRow<T>(
              item: sorted[index],
              index: index,
              columns: visible,
              current: widget.isCurrent?.call(sorted[index]) ?? false,
              onActivate: widget.onActivate,
              itemOf: widget.itemOf,
            ),
          ),
        ),
      ],
    );
  }

  Widget _header(Theme theme, List<MediaColumn<T>> visible) {
    final style = theme.typography.caption.copyWith(
      color: theme.palette.text.withValues(alpha: theme.opacities.tertiary),
      fontWeight: FontWeight.w600,
      letterSpacing: 0.8,
    );
    final header = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: theme.space.x3 + theme.space.x4,
        vertical: theme.space.x2,
      ),
      child: DefaultTextStyle.merge(
        style: style,
        child: Row(
          spacing: theme.space.x3,
          children: [
            for (final column in visible)
              _headerCell(theme, column, visible.last == column),
          ],
        ),
      ),
    );
    // The picker button stands in the trailing gutter — the inset the
    // rows already keep — so the headers stay flush with their columns.
    final picker = Menu(
      open: _columnsOpen,
      onDismiss: () => setState(() => _columnsOpen = false),
      align: PopoverAlign.end,
      entries: [
        for (final column in widget.columns)
          MenuItem(
            label: Text(column.label),
            leading: Icon(
              _visible.any((c) => c.id == column.id)
                  ? theme.icons.confirm
                  : null,
              size: 14,
            ),
            onPressed: () => _toggleColumn(column),
          ),
      ],
      anchor: Tooltip(
        message: const Text('Choose columns'),
        child: Button.custom(
          onPressed: () => setState(() => _columnsOpen = !_columnsOpen),
          style: theme.widgets.button
              .resolve(SemanticSwatch.neutral, SurfaceVariant.ghost)
              .copyWith(height: 24, padding: EdgeInsets.zero),
          child: const SizedBox.square(
            dimension: 24,
            child: Center(child: Icon(LucideIcons.columns3, size: 14)),
          ),
        ),
      ),
    );
    return Stack(
      alignment: AlignmentDirectional.centerEnd,
      children: [
        header,
        PositionedDirectional(end: 2, child: picker),
      ],
    );
  }

  Widget _headerCell(Theme theme, MediaColumn<T> column, bool last) {
    final active = widget.prefs.sortColumn == column.id;
    final word = Text(
      column.label.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final content = Row(
      mainAxisAlignment: column.numeric
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      children: [
        if (column.numeric && active) ...[
          _chevron(theme),
          const SizedBox(width: 2),
        ],
        Flexible(child: word),
        if (!column.numeric && active) ...[
          const SizedBox(width: 2),
          _chevron(theme),
        ],
      ],
    );
    final cell = column.sortKey == null
        ? content
        : MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _sortBy(column),
              child: content,
            ),
          );
    return column.width != null
        ? SizedBox(width: column.width, child: cell)
        : Expanded(flex: column.flex, child: cell);
  }

  Widget _chevron(Theme theme) => Icon(
    widget.prefs.sortAscending
        ? LucideIcons.chevronUp
        : LucideIcons.chevronDown,
    size: 12,
    color: theme.palette.primary.s400,
  );
}

/// One table row in the shared dress: the deck's track wears primary,
/// a hovered row lifts, odd rows carry the zebra stripe.
class _MediaRow<T> extends StatefulWidget {
  const _MediaRow({
    required this.item,
    required this.index,
    required this.columns,
    required this.current,
    required this.onActivate,
    required this.itemOf,
  });

  final T item;
  final int index;
  final List<MediaColumn<T>> columns;
  final bool current;
  final void Function(T item)? onActivate;
  final MediaItem Function(T item)? itemOf;

  @override
  State<_MediaRow<T>> createState() => _MediaRowState<T>();
}

class _MediaRowState<T> extends State<_MediaRow<T>> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final content = Padding(
      padding: EdgeInsets.symmetric(horizontal: theme.space.x4),
      child: SizedBox(
        // Every row stands art-tall, sleeves shown or not, so the
        // tables keep one rhythm across the app.
        height: 40,
        child: DefaultTextStyle.merge(
          style: theme.typography.bodySmall,
          child: Row(
            spacing: theme.space.x3,
            children: [
              for (final column in widget.columns)
                column.width != null
                    ? SizedBox(
                        width: column.width,
                        child: _aligned(column, context),
                      )
                    : Expanded(
                        flex: column.flex,
                        child: _aligned(column, context),
                      ),
            ],
          ),
        ),
      ),
    );

    final Widget dressed;
    if (widget.current) {
      dressed = RowSurface(
        swatch: SemanticSwatch.primary,
        variant: SurfaceVariant.soft,
        child: content,
      );
    } else if (_hover && widget.onActivate != null) {
      dressed = RowSurface(
        swatch: SemanticSwatch.neutral,
        variant: SurfaceVariant.soft,
        child: content,
      );
    } else if (widget.index.isOdd) {
      dressed = RowSurface(
        swatch: SemanticSwatch.neutral,
        variant: SurfaceVariant.subtle,
        child: content,
      );
    } else {
      dressed = content;
    }

    if (widget.onActivate == null) return dressed;
    // With an item behind the row, taps speak the shelf grammar —
    // inspect, open, enqueue; without one, a tap just activates.
    if (widget.itemOf case final itemOf?) {
      return ItemTap(
        item: itemOf(widget.item),
        onOpen: () => widget.onActivate!(widget.item),
        onHover: (hover) => setState(() => _hover = hover),
        child: dressed,
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onActivate!(widget.item),
        child: dressed,
      ),
    );
  }

  Widget _aligned(MediaColumn<T> column, BuildContext context) => column.numeric
      ? Align(
          alignment: Alignment.centerRight,
          child: column.cell(context, widget.item),
        )
      : column.cell(context, widget.item);
}

/// A cell's quiet text — the secondary voice most table cells speak in.
/// A cell too narrow for its words ellipsises, and hovering it speaks
/// the whole text in a tooltip; text that fits stays silent.
Widget tableText(
  BuildContext context,
  String text, {
  bool numeric = false,
  bool strong = false,
}) {
  final theme = ThemeProvider.of(context);
  final secondary = theme.palette.text.withValues(
    alpha: theme.opacities.secondary,
  );
  return _CellText(
    text: text,
    numeric: numeric,
    style: numeric
        ? theme.typography.code.copyWith(
            fontSize: theme.typography.caption.fontSize,
            color: secondary,
            fontFeatures: const [FontFeature.tabularFigures()],
          )
        : strong
        ? const TextStyle(fontWeight: FontWeight.w500)
        : TextStyle(color: secondary),
  );
}

class _CellText extends StatelessWidget {
  const _CellText({
    required this.text,
    required this.numeric,
    required this.style,
  });

  final String text;
  final bool numeric;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final word = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: numeric ? TextAlign.right : TextAlign.left,
      style: style,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth) return word;
        // Measured as it will truly paint: the cell style over the
        // table's ambient one, at the reader's text scale.
        final painter = TextPainter(
          text: TextSpan(
            text: text,
            style: DefaultTextStyle.of(context).style.merge(style),
          ),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final clipped =
            painter.didExceedMaxLines || painter.width > constraints.maxWidth;
        painter.dispose();
        if (!clipped) return word;
        return Tooltip(message: Text(text), child: word);
      },
    );
  }
}

/// The grid/table switch a shelf header wears when it can do both.
class ViewModeToggle extends StatelessWidget {
  const ViewModeToggle({
    required this.mode,
    required this.onChanged,
    super.key,
  });

  final ViewMode mode;
  final void Function(ViewMode mode) onChanged;

  @override
  Widget build(BuildContext context) => SegmentedControl<ViewMode>(
    value: mode,
    onChanged: onChanged,
    segments: const [
      SegmentOption(
        value: ViewMode.grid,
        label: Icon(LucideIcons.layoutGrid, size: 14),
      ),
      SegmentOption(
        value: ViewMode.table,
        label: Icon(LucideIcons.rows3, size: 14),
      ),
    ],
  );
}
