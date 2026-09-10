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

/// The long-form shelf: every film as a poster tile at one-sheet
/// proportions, or — through the toggle — as rows in a [MediaTable]. A tap hands the film to the deck,
/// which wears its watching face; the video surface itself is still to
/// come.
class VideosView extends StatelessWidget {
  const VideosView({
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
    final films = [
      for (final item in items)
        if (item.metadata case final VideoMetadata metadata) (item, metadata),
    ];
    final mode = prefs.mode ?? ViewMode.grid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ShelfHeader(
          trailing: [
            ViewModeToggle(
              mode: mode,
              onChanged: (value) => onPrefs(prefs.copyWith(mode: value)),
            ),
          ],
        ),
        Expanded(
          child: mode == ViewMode.grid
              ? _grid(theme, films)
              : MediaTable<(MediaItem, VideoMetadata)>(
                  columns: _columns,
                  items: films,
                  prefs: prefs,
                  onPrefs: onPrefs,
                  onActivate: (film) => player.open(film.$1),
                  isCurrent: (film) => player.opened?.id == film.$1.id,
                  itemOf: (film) => film.$1,
                ),
        ),
      ],
    );
  }

  Widget _grid(Theme theme, List<(MediaItem, VideoMetadata)> films) =>
      GridView.builder(
        padding: EdgeInsets.fromLTRB(
          theme.space.x6,
          0,
          theme.space.x6,
          theme.space.x6,
        ),
        gridDelegate: shelfGridDelegate(theme, tileAspect: posterAspect),
        itemCount: films.length,
        itemBuilder: (context, index) {
          final (item, metadata) = films[index];
          final palette = theme.palette;
          return ItemTap(
            item: item,
            onOpen: () => player.open(item),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ArtTile(
                  metadata.title,
                  kind: MediaKind.video,
                  aspectRatio: posterAspect,
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
                Text(
                  [
                    if (metadata.year != null) '${metadata.year}',
                    if (metadata.duration != null)
                      formatClock(metadata.duration!),
                  ].join(' · '),
                  style: theme.typography.caption.copyWith(
                    color: palette.text.withValues(
                      alpha: theme.opacities.secondary,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );

  static final _columns = <MediaColumn<(MediaItem, VideoMetadata)>>[
    MediaColumn(
      id: 'title',
      label: 'Title',
      flex: 5,
      sortKey: (f) => f.$2.title.toLowerCase(),
      cell: (context, f) => tableText(context, f.$2.title, strong: true),
    ),
    MediaColumn(
      id: 'year',
      label: 'Year',
      width: 48,
      numeric: true,
      sortKey: (f) => f.$2.year,
      cell: (context, f) =>
          tableText(context, f.$2.year?.toString() ?? '', numeric: true),
    ),
    MediaColumn(
      id: 'time',
      label: 'Time',
      width: 64,
      numeric: true,
      sortKey: (f) => f.$2.duration?.inMilliseconds,
      cell: (context, f) => tableText(
        context,
        formatClock(f.$2.duration ?? Duration.zero),
        numeric: true,
      ),
    ),
    MediaColumn(
      id: 'resolution',
      label: 'Resolution',
      width: 88,
      sortKey: (f) => f.$2.height,
      cell: (context, f) => tableText(
        context,
        f.$2.width != null && f.$2.height != null
            ? '${f.$2.width}×${f.$2.height}'
            : '',
      ),
    ),
    MediaColumn(
      id: 'codec',
      label: 'Codec',
      width: 64,
      sortKey: (f) => f.$2.videoCodec?.toLowerCase(),
      cell: (context, f) => tableText(context, f.$2.videoCodec ?? ''),
    ),
  ];
}
