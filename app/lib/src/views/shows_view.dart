import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

import '../model/player.dart';
import '../model/view_prefs.dart';
import '../util/format.dart';
import '../widgets/art_tile.dart';
import '../widgets/item_tap.dart';
import '../widgets/shelf_grid.dart';
import '../widgets/media_table.dart';
import '../widgets/shelf_header.dart';
import '../widgets/row_surface.dart';

/// The episodic shelf, two facets deep: Series as a grid of covers, and
/// Episodes as a sortable table (the grouped list waits behind the grid
/// toggle). Video runs and audio-only broadcasts sit side by side; audio
/// plays on the mock deck today, video waits for a surface.
class ShowsView extends StatelessWidget {
  const ShowsView({
    required this.player,
    required this.items,
    required this.prefs,
    required this.onPrefs,
    required this.onOpenSeries,
    super.key,
  });

  final PlaybackController player;
  final List<MediaItem> items;

  /// Presentation choices (mode, columns, sort) and where they land.
  final ViewPrefs prefs;
  final void Function(ViewPrefs prefs) onPrefs;

  /// A cover was chosen: the run's page opens.
  final void Function(String series) onOpenSeries;

  Map<String, List<MediaItem>> get _series {
    final groups = <String, List<MediaItem>>{};
    for (final item in items) {
      groups.putIfAbsent(_seriesOf(item), () => []).add(item);
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final facet = prefs.facet ?? 'series';
    // Episodes read best flat; the grouped list waits behind the toggle.
    final mode = prefs.mode ?? ViewMode.table;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ShelfHeader(
            leading: [
              SegmentedControl<String>(
                value: facet,
                onChanged: (facet) => onPrefs(prefs.copyWith(facet: facet)),
                segments: const [
                  SegmentOption(value: 'series', label: Text('Series')),
                  SegmentOption(value: 'episodes', label: Text('Episodes')),
                ],
              ),
            ],
            trailing: [
              if (facet == 'episodes')
                ViewModeToggle(
                  mode: mode,
                  onChanged: (mode) => onPrefs(prefs.copyWith(mode: mode)),
                ),
            ],
          ),
          Expanded(
            child: facet == 'series'
                ? _seriesGrid(theme)
                : mode == ViewMode.table
                ? _table(context)
                : _grouped(theme),
          ),
        ],
      ),
    );
  }

  /// The series shelf: one cover per run, wearing the first episode's
  /// art. A series page comes later; today the tiles sit.
  Widget _seriesGrid(Theme theme) {
    final series = _series.entries.toList();
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
        theme.space.x6,
        0,
        theme.space.x6,
        theme.space.x6,
      ),
      gridDelegate: shelfGridDelegate(theme),
      itemCount: series.length,
      itemBuilder: (context, index) {
        final MapEntry(key: name, value: episodes) = series[index];
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onOpenSeries(name),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Hero(
                  tag: 'series-$name-art',
                  child: ArtTile(
                    name,
                    kind: MediaKind.video,
                    fileId: episodes.first.fileId,
                  ),
                ),
                Spacing(SpaceStep.x2),
                Hero(
                  tag: 'series-$name-title',
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.typography.bodySmall.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                CaptionText(
                  '${episodes.length} episodes',
                  emphasis: TextEmphasis.secondary,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The grouped list — a kicker per series, its episodes beneath.
  Widget _grouped(Theme theme) => ListView(
    padding: EdgeInsets.fromLTRB(
      theme.space.x4,
      0,
      theme.space.x4,
      theme.space.x4,
    ),
    children: [
      for (final MapEntry(key: name, value: episodes) in _series.entries) ...[
        Padding(
          padding: EdgeInsets.only(bottom: theme.space.x2, top: theme.space.x3),
          child: KickerText(name),
        ),
        for (final episode in episodes) ...[
          _EpisodeRow(item: episode, player: player),
          SizedBox(height: theme.space.x1),
        ],
      ],
    ],
  );

  /// The flattened table: every episode one row, its series a column.
  Widget _table(BuildContext context) => MediaTable<MediaItem>(
    columns: _columns,
    items: items,
    prefs: prefs,
    onPrefs: onPrefs,
    // The deck sorts out what activating means for the kind — audio
    // plays, video takes the watching face.
    onActivate: player.open,
    itemOf: (item) => item,
    isCurrent: (item) => switch (item.metadata) {
      AudioMetadata() => player.opened == null && player.current?.id == item.id,
      _ => player.opened?.id == item.id,
    },
  );

  static final _columns = <MediaColumn<MediaItem>>[
    MediaColumn(
      id: 'series',
      label: 'Series',
      flex: 4,
      sortKey: (i) => _seriesOf(i).toLowerCase(),
      cell: (context, i) => tableText(context, _seriesOf(i), strong: true),
    ),
    MediaColumn(
      id: 'episode',
      label: 'Episode',
      width: 72,
      numeric: true,
      sortKey: _episodeKey,
      cell: (context, i) => tableText(context, _episodeLabel(i), numeric: true),
    ),
    MediaColumn(
      id: 'title',
      label: 'Title',
      flex: 5,
      sortKey: (i) => _titleOf(i.metadata).toLowerCase(),
      cell: (context, i) => tableText(context, _titleOf(i.metadata)),
    ),
    MediaColumn(
      id: 'time',
      label: 'Time',
      width: 64,
      numeric: true,
      sortKey: (i) => _durationOf(i)?.inMilliseconds,
      cell: (context, i) => tableText(
        context,
        formatClock(_durationOf(i) ?? Duration.zero),
        numeric: true,
      ),
    ),
  ];

  /// Season and episode folded into one orderable number — a thousand
  /// episodes a season is plenty.
  static int _episodeKey(MediaItem item) => switch (item.metadata) {
    VideoMetadata(:final season, :final episode) =>
      (season ?? 0) * 1000 + (episode ?? 0),
    AudioMetadata(:final trackNumber) => trackNumber ?? 0,
    _ => 0,
  };

  /// The badge the grouped rows wear: `S1E2` for video, `E1` for audio.
  static String _episodeLabel(MediaItem item) => switch (item.metadata) {
    VideoMetadata(:final season?, :final episode?) => 'S${season}E$episode',
    AudioMetadata(:final trackNumber?) => 'E$trackNumber',
    _ => '',
  };

  static Duration? _durationOf(MediaItem item) => switch (item.metadata) {
    VideoMetadata(:final duration) => duration,
    AudioMetadata(:final duration) => duration,
    _ => null,
  };
}

/// The series an episode files under — the same answer the grouping gives.
String _seriesOf(MediaItem item) => switch (item.metadata) {
  VideoMetadata(:final series?) => series,
  VideoMetadata(:final title) => title,
  AudioMetadata(:final album?) => album,
  final m => _titleOf(m),
};

String _titleOf(MediaMetadata metadata) => switch (metadata) {
  AudioMetadata(:final title) => title,
  VideoMetadata(:final title) => title,
  ImageMetadata(:final title) => title ?? '',
  DocumentMetadata(:final title) => title,
};

class _EpisodeRow extends StatefulWidget {
  const _EpisodeRow({required this.item, required this.player});

  final MediaItem item;
  final PlaybackController player;

  @override
  State<_EpisodeRow> createState() => _EpisodeRowState();
}

class _EpisodeRowState extends State<_EpisodeRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final palette = theme.palette;
    final metadata = widget.item.metadata;
    final secondary = palette.text.withValues(alpha: theme.opacities.secondary);

    final (label, duration, playable) = switch (metadata) {
      VideoMetadata(:final season?, :final episode?, :final title) => (
        'S${season}E$episode · $title',
        metadata.duration,
        false,
      ),
      VideoMetadata(:final title) => (title, metadata.duration, false),
      AudioMetadata(:final trackNumber?, :final title) => (
        'E$trackNumber · $title',
        metadata.duration,
        true,
      ),
      final m => (_titleOf(m), null, false),
    };
    final current = playable
        ? widget.player.opened == null &&
              widget.player.current?.id == widget.item.id
        : widget.player.opened?.id == widget.item.id;

    final content = Padding(
      padding: EdgeInsets.symmetric(horizontal: theme.space.x3),
      child: SizedBox(
        height: 34,
        child: Row(
          spacing: theme.space.x2,
          children: [
            Icon(
              metadata.kind == MediaKind.video
                  ? LucideIcons.film
                  : LucideIcons.radio,
              size: 14,
              color: current ? palette.primary.s400 : secondary,
            ),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.bodySmall.copyWith(
                  fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (!playable)
              CaptionText('video', emphasis: TextEmphasis.tertiary),
            Text(
              formatClock(duration ?? Duration.zero),
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

    return ItemTap(
      item: widget.item,
      onOpen: () => widget.player.open(widget.item),
      onHover: (hover) => setState(() => _hover = hover),
      child: dressed,
    );
  }
}
