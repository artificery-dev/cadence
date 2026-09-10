import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

import '../model/player.dart';
import '../model/view_prefs.dart';
import '../util/format.dart';
import '../widgets/art_tile.dart';
import '../widgets/item_tap.dart';
import '../widgets/media_table.dart';
import '../widgets/shelf_grid.dart';
import '../widgets/shelf_header.dart';

/// The reading (and listening) shelf, kept in the longbox's shape: a grid
/// of covers, or a sortable table — the toggle chooses. Every spine goes
/// to the deck on a tap: audiobooks play, documents open at their first
/// page, and the deck wears the right face either way.
class BooksView extends StatelessWidget {
  const BooksView({
    required this.player,
    required this.items,
    required this.prefs,
    required this.onPrefs,
    super.key,
  });

  final PlaybackController player;
  final List<MediaItem> items;

  /// Presentation choices (mode, columns, sort) and where they land.
  final ViewPrefs prefs;
  final void Function(ViewPrefs prefs) onPrefs;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    if (items.isEmpty) {
      return const Center(
        child: EmptyState(
          icon: LucideIcons.bookHeadphones,
          title: TitleText('An empty shelf'),
          message: BodyText(
            'Scan a folder of audiobooks or ebooks and fill it.',
          ),
        ),
      );
    }
    final mode = prefs.mode ?? ViewMode.grid;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ShelfHeader(
            trailing: [
              ViewModeToggle(
                mode: mode,
                onChanged: (mode) => onPrefs(prefs.copyWith(mode: mode)),
              ),
            ],
          ),
          Expanded(child: mode == ViewMode.table ? _table() : _grid(theme)),
        ],
      ),
    );
  }

  /// The cover grid — spine, title, and the byline the shelf speaks.
  Widget _grid(Theme theme) => GridView.builder(
    padding: EdgeInsets.fromLTRB(
      theme.space.x6,
      0,
      theme.space.x6,
      theme.space.x6,
    ),
    gridDelegate: shelfGridDelegate(theme, tileAspect: bookAspect),
    itemCount: items.length,
    itemBuilder: (context, index) =>
        _BookTile(item: items[index], player: player),
  );

  Widget _table() => MediaTable<MediaItem>(
    columns: _columns,
    items: items,
    prefs: prefs,
    onPrefs: onPrefs,
    // The deck sorts out what activating means for the kind.
    onActivate: player.open,
    itemOf: (item) => item,
    isCurrent: (item) => switch (item.metadata) {
      AudioMetadata() => player.opened == null && player.current?.id == item.id,
      _ => player.opened?.id == item.id,
    },
  );

  static final _columns = <MediaColumn<MediaItem>>[
    MediaColumn(
      id: 'title',
      label: 'Title',
      flex: 5,
      sortKey: (i) => _titleOf(i).toLowerCase(),
      cell: (context, i) => tableText(context, _titleOf(i), strong: true),
    ),
    MediaColumn(
      id: 'author',
      label: 'Author',
      flex: 3,
      sortKey: (i) => _authorOf(i)?.toLowerCase(),
      cell: (context, i) => tableText(context, _authorOf(i) ?? ''),
    ),
    MediaColumn(
      id: 'kind',
      label: 'Kind',
      width: 72,
      sortKey: _kindOf,
      cell: (context, i) => tableText(context, _kindOf(i)),
    ),
    MediaColumn(
      id: 'length',
      label: 'Length',
      width: 72,
      numeric: true,
      sortKey: (i) => switch (i.metadata) {
        AudioMetadata(:final duration) => duration?.inMilliseconds,
        DocumentMetadata(:final pageCount) => pageCount,
        _ => null,
      },
      cell: (context, i) => tableText(context, switch (i.metadata) {
        AudioMetadata(:final duration) => formatClock(
          duration ?? Duration.zero,
        ),
        DocumentMetadata(:final pageCount?) => '$pageCount pp',
        _ => '',
      }, numeric: true),
    ),
  ];

  static String _titleOf(MediaItem item) => switch (item.metadata) {
    AudioMetadata(:final title) => title,
    DocumentMetadata(:final title) => title,
    _ => '',
  };

  /// Audiobooks credit the reader through [AudioMetadata.artist];
  /// documents through [DocumentMetadata.author] — the same names the
  /// grid's bylines speak.
  static String? _authorOf(MediaItem item) => switch (item.metadata) {
    AudioMetadata(:final artist) => artist,
    DocumentMetadata(:final author) => author,
    _ => null,
  };

  /// What sort of book this is: `audiobook`, or the document's format
  /// the way the table shouts it (`PDF`).
  static String _kindOf(MediaItem item) => switch (item.metadata) {
    AudioMetadata() => 'audiobook',
    DocumentMetadata() =>
      item.tags
              .where((t) => t.namespace == TagNamespace.format.id)
              .firstOrNull
              ?.name
              .toUpperCase() ??
          'PDF',
    _ => '',
  };
}

/// One spine on the shelf. Every cover goes to the deck on a tap — the
/// player knows whether that means playing or opening.
class _BookTile extends StatelessWidget {
  const _BookTile({required this.item, required this.player});

  final MediaItem item;
  final PlaybackController player;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final metadata = item.metadata;

    final (title, byline) = switch (metadata) {
      AudioMetadata(:final title, :final artist) => (
        title,
        artist == null ? 'audiobook' : 'read by $artist',
      ),
      DocumentMetadata(:final title, :final author) => (
        title,
        author ?? 'document',
      ),
      _ => ('', ''),
    };
    final current = switch (metadata) {
      AudioMetadata() => player.opened == null && player.current?.id == item.id,
      _ => player.opened?.id == item.id,
    };

    return ItemTap(
      item: item,
      onOpen: () => player.open(item),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ArtTile(
            title,
            kind: metadata.kind,
            aspectRatio: bookAspect,
            fileId: item.fileId,
          ),
          Spacing(SpaceStep.x2),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.typography.bodySmall.copyWith(
              fontWeight: current ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
          CaptionText(byline, emphasis: TextEmphasis.secondary),
        ],
      ),
    );
  }
}
