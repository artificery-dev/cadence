import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

import '../model/player.dart';
import '../model/view_prefs.dart';
import '../widgets/art_tile.dart';
import '../widgets/item_tap.dart';
import '../widgets/shelf_grid.dart';
import '../widgets/media_table.dart';
import '../widgets/shelf_header.dart';

/// One issue and its document metadata, already unwrapped.
typedef _Issue = (MediaItem, DocumentMetadata);

/// The longbox, two facets deep: Series as a grid of covers, and Issues
/// as covers or a sortable table — the toggle chooses. A tap on an issue
/// hands it to the deck, which wears its reading face; the reader itself
/// is still to come.
class ComicsView extends StatelessWidget {
  const ComicsView({
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

  List<_Issue> get _issues => [
    for (final item in items)
      if (item.metadata case final DocumentMetadata metadata) (item, metadata),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final issues = _issues;
    if (issues.isEmpty) {
      return const Center(
        child: EmptyState(
          icon: LucideIcons.bookImage,
          title: TitleText('An empty longbox'),
          message: BodyText('Scan a folder of cbz files and fill it.'),
        ),
      );
    }
    final facet = prefs.facet ?? 'issues';
    final mode = prefs.mode ?? ViewMode.grid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ShelfHeader(
          leading: [
            SegmentedControl<String>(
              value: facet,
              onChanged: (facet) => onPrefs(prefs.copyWith(facet: facet)),
              segments: const [
                SegmentOption(value: 'series', label: Text('Series')),
                SegmentOption(value: 'issues', label: Text('Issues')),
              ],
            ),
          ],
          trailing: [
            if (facet == 'issues')
              ViewModeToggle(
                mode: mode,
                onChanged: (mode) => onPrefs(prefs.copyWith(mode: mode)),
              ),
          ],
        ),
        Expanded(
          child: facet == 'series'
              ? _seriesGrid(theme, issues)
              : mode == ViewMode.table
              ? MediaTable<_Issue>(
                  columns: _columns,
                  items: issues,
                  prefs: prefs,
                  onPrefs: onPrefs,
                  onActivate: (issue) => player.open(issue.$1),
                  isCurrent: (issue) => player.opened?.id == issue.$1.id,
                  itemOf: (issue) => issue.$1,
                )
              : _grid(theme, issues),
        ),
      ],
    );
  }

  /// The series shelf: one cover per run — the first issue's — with the
  /// run's count beneath. A series page comes later; the tiles sit.
  Widget _seriesGrid(Theme theme, List<_Issue> issues) {
    final groups = <String, List<_Issue>>{};
    for (final issue in issues) {
      groups.putIfAbsent(issue.$2.series ?? 'Unknown', () => []).add(issue);
    }
    final series = groups.entries.toList();
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
        theme.space.x6,
        0,
        theme.space.x6,
        theme.space.x6,
      ),
      gridDelegate: shelfGridDelegate(theme, tileAspect: bookAspect),
      itemCount: series.length,
      itemBuilder: (context, index) {
        final MapEntry(key: name, value: run) = series[index];
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
                    kind: MediaKind.document,
                    aspectRatio: bookAspect,
                    fileId: run.first.$1.fileId,
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
                  '${run.length} issues',
                  emphasis: TextEmphasis.secondary,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _grid(Theme theme, List<_Issue> issues) => GridView.builder(
    padding: EdgeInsets.fromLTRB(
      theme.space.x6,
      0,
      theme.space.x6,
      theme.space.x6,
    ),
    gridDelegate: shelfGridDelegate(theme, tileAspect: bookAspect),
    itemCount: issues.length,
    itemBuilder: (context, index) {
      final (item, metadata) = issues[index];
      final title = metadata.title;
      final line = [
        if (metadata.series != null) metadata.series!,
        if (metadata.issueNumber case final n?) _issueLabel(n),
      ].join(' ');
      return ItemTap(
        item: item,
        onOpen: () => player.open(item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ArtTile(
              title,
              kind: MediaKind.document,
              aspectRatio: bookAspect,
              fileId: item.fileId,
            ),
            Spacing(SpaceStep.x2),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.typography.bodySmall.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (line.isNotEmpty)
              CaptionText(line, emphasis: TextEmphasis.secondary),
          ],
        ),
      );
    },
  );

  /// `#1` for the whole numbers, `#12.5` for the annuals between.
  static String _issueLabel(double n) =>
      '#${n == n.roundToDouble() ? n.toInt() : n}';

  static final _columns = <MediaColumn<_Issue>>[
    MediaColumn(
      id: 'title',
      label: 'Title',
      flex: 5,
      sortKey: (i) => i.$2.title.toLowerCase(),
      cell: (context, i) => tableText(context, i.$2.title, strong: true),
    ),
    MediaColumn(
      id: 'series',
      label: 'Series',
      flex: 4,
      sortKey: (i) => i.$2.series?.toLowerCase(),
      cell: (context, i) => tableText(context, i.$2.series ?? ''),
    ),
    MediaColumn(
      id: 'issue',
      label: 'Issue',
      width: 56,
      numeric: true,
      sortKey: (i) => i.$2.issueNumber,
      cell: (context, i) => tableText(context, switch (i.$2.issueNumber) {
        final n? => _issueLabel(n),
        _ => '',
      }, numeric: true),
    ),
    MediaColumn(
      id: 'writer',
      label: 'Writer',
      flex: 3,
      sortKey: (i) => i.$2.author?.toLowerCase(),
      cell: (context, i) => tableText(context, i.$2.author ?? ''),
    ),
    MediaColumn(
      id: 'pages',
      label: 'Pages',
      width: 56,
      numeric: true,
      sortKey: (i) => i.$2.pageCount,
      cell: (context, i) =>
          tableText(context, i.$2.pageCount?.toString() ?? '', numeric: true),
    ),
  ];
}
