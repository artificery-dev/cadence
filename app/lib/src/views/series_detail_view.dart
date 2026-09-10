import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

import '../model/player.dart';
import '../model/view_prefs.dart';
import '../util/format.dart';
import '../widgets/art_tile.dart';
import '../widgets/item_tap.dart';
import '../widgets/shelf_grid.dart';
import '../widgets/detail_header.dart';
import '../widgets/media_table.dart';

/// One run, opened. For shows and podcasts: the episodes in order, audio
/// ones playable. For comics: the issues as covers. The page reads the
/// library's type to know which face to wear.
class SeriesDetailView extends StatefulWidget {
  const SeriesDetailView({
    required this.player,
    required this.series,
    required this.items,
    required this.libraryType,
    required this.onBack,
    super.key,
  });

  final PlaybackController player;
  final String series;

  /// The run's items, in shelf order.
  final List<MediaItem> items;
  final LibraryType libraryType;
  final VoidCallback onBack;

  @override
  State<SeriesDetailView> createState() => _SeriesDetailViewState();
}

class _SeriesDetailViewState extends State<SeriesDetailView> {
  /// Sort choices live for the visit; the page keeps no ledger.
  ViewPrefs _prefs = const ViewPrefs();

  bool get _isComics => widget.libraryType == LibraryType.comics;

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    if (items.isEmpty) {
      return Center(
        child: EmptyState(
          icon: _isComics ? LucideIcons.bookImage : LucideIcons.tv,
          title: const TitleText('An empty run'),
          message: const BodyText('Nothing on the shelf carries this name.'),
        ),
      );
    }
    final playtime = items.fold(Duration.zero, (sum, item) {
      final duration = switch (item.metadata) {
        AudioMetadata(:final duration) => duration,
        VideoMetadata(:final duration) => duration,
        _ => null,
      };
      return sum + (duration ?? Duration.zero);
    });
    return ListenableBuilder(
      listenable: widget.player,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DetailHeader(
            onBack: widget.onBack,
            art: widget.series,
            artKind: _isComics ? MediaKind.document : MediaKind.video,
            artFileId: items.first.fileId,
            kicker: 'SERIES',
            title: widget.series,
            heroPrefix: 'series-${widget.series}',
            caption: _isComics
                ? '${items.length} issues'
                : '${items.length} episodes · ${formatClock(playtime)}',
          ),
          Expanded(child: _isComics ? _issues(context) : _episodes()),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ episodes

  Widget _episodes() => MediaTable<MediaItem>(
    columns: _episodeColumns,
    items: widget.items,
    prefs: _prefs,
    onPrefs: (prefs) => setState(() => _prefs = prefs),
    // The deck sorts out what activating means for the kind — audio
    // plays, video takes the watching face.
    onActivate: widget.player.open,
    itemOf: (item) => item,
    isCurrent: (item) => switch (item.metadata) {
      AudioMetadata() =>
        widget.player.opened == null && widget.player.current?.id == item.id,
      _ => widget.player.opened?.id == item.id,
    },
  );

  static String _episodeLabel(MediaItem item) => switch (item.metadata) {
    VideoMetadata(:final season, :final episode) =>
      season != null && episode != null
          ? 'S${season}E$episode'
          : episode != null
          ? 'E$episode'
          : '',
    AudioMetadata(:final trackNumber) =>
      trackNumber != null ? 'E$trackNumber' : '',
    _ => '',
  };

  static int _episodeOrder(MediaItem item) => switch (item.metadata) {
    VideoMetadata(:final season, :final episode) =>
      (season ?? 0) * 1000 + (episode ?? 0),
    AudioMetadata(:final trackNumber) => trackNumber ?? 0,
    _ => 0,
  };

  static Duration? _durationOf(MediaItem item) => switch (item.metadata) {
    AudioMetadata(:final duration) => duration,
    VideoMetadata(:final duration) => duration,
    _ => null,
  };

  static String _titleOf(MediaItem item) => switch (item.metadata) {
    AudioMetadata(:final title) => title,
    VideoMetadata(:final title) => title,
    _ => '',
  };

  static final _episodeColumns = <MediaColumn<MediaItem>>[
    MediaColumn(
      id: 'episode',
      label: 'Episode',
      width: 72,
      sortKey: _episodeOrder,
      cell: (context, i) => tableText(context, _episodeLabel(i)),
    ),
    MediaColumn(
      id: 'title',
      label: 'Title',
      flex: 6,
      sortKey: (i) => _titleOf(i).toLowerCase(),
      cell: (context, i) => tableText(context, _titleOf(i), strong: true),
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

  // -------------------------------------------------------------- issues

  Widget _issues(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final issues = [
      for (final item in widget.items)
        if (item.metadata case final DocumentMetadata metadata)
          (item, metadata),
    ];
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
        theme.space.x6,
        theme.space.x3,
        theme.space.x6,
        theme.space.x6,
      ),
      gridDelegate: shelfGridDelegate(theme, tileAspect: bookAspect),
      itemCount: issues.length,
      itemBuilder: (context, index) {
        final (item, metadata) = issues[index];
        final number = switch (metadata.issueNumber) {
          final n? => '#${n == n.roundToDouble() ? n.toInt() : n}',
          _ => '',
        };
        return ItemTap(
          item: item,
          onOpen: () => widget.player.open(item),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ArtTile(
                metadata.title,
                kind: MediaKind.document,
                aspectRatio: bookAspect,
                fileId: item.fileId,
              ),
              Spacing(SpaceStep.x2),
              Text(
                metadata.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.bodySmall.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (number.isNotEmpty)
                CaptionText(number, emphasis: TextEmphasis.secondary),
            ],
          ),
        );
      },
    );
  }
}
