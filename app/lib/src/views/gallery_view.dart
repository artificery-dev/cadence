import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

import '../model/player.dart';
import '../model/view_prefs.dart';

import '../widgets/art_tile.dart';
import '../widgets/item_tap.dart';
import '../widgets/shelf_grid.dart';
import '../widgets/media_table.dart';
import '../widgets/shelf_header.dart';

/// The wallpaper crate: image tiles with their dimensions, or — through
/// the toggle — rows in a [MediaTable]. A tap stands the picture on the
/// deck; the full-size viewer is still to come.
class GalleryView extends StatelessWidget {
  const GalleryView({
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
    final images = [
      for (final item in items)
        if (item.metadata case final ImageMetadata metadata) (item, metadata),
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
              ? _grid(theme, images)
              : MediaTable<(MediaItem, ImageMetadata)>(
                  columns: _columns,
                  items: images,
                  prefs: prefs,
                  onPrefs: onPrefs,
                  onActivate: (image) => player.open(image.$1),
                  isCurrent: (image) => player.opened?.id == image.$1.id,
                  itemOf: (image) => image.$1,
                ),
        ),
      ],
    );
  }

  Widget _grid(Theme theme, List<(MediaItem, ImageMetadata)> images) =>
      GridView.builder(
        padding: EdgeInsets.fromLTRB(
          theme.space.x6,
          0,
          theme.space.x6,
          theme.space.x6,
        ),
        gridDelegate: shelfGridDelegate(theme),
        itemCount: images.length,
        itemBuilder: (context, index) {
          final (item, metadata) = images[index];
          final palette = theme.palette;
          final title = metadata.title ?? item.path;
          return ItemTap(
            item: item,
            onOpen: () => player.open(item),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ArtTile(title, kind: MediaKind.image, fileId: item.fileId),
                Spacing(SpaceStep.x2),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.bodySmall.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  metadata.width != null && metadata.height != null
                      ? '${metadata.width} × ${metadata.height}'
                      : '',
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

  static final _columns = <MediaColumn<(MediaItem, ImageMetadata)>>[
    MediaColumn(
      id: 'title',
      label: 'Title',
      flex: 5,
      sortKey: (i) => (i.$2.title ?? i.$1.path).toLowerCase(),
      cell: (context, i) =>
          tableText(context, i.$2.title ?? i.$1.path, strong: true),
    ),
    MediaColumn(
      id: 'dimensions',
      label: 'Dimensions',
      width: 96,
      sortKey: (i) => i.$2.width != null && i.$2.height != null
          ? i.$2.width! * i.$2.height!
          : null,
      cell: (context, i) => tableText(
        context,
        i.$2.width != null && i.$2.height != null
            ? '${i.$2.width}×${i.$2.height}'
            : '',
      ),
    ),
    MediaColumn(
      id: 'taken',
      label: 'Taken',
      width: 96,
      sortKey: (i) => i.$2.takenAt,
      cell: (context, i) => tableText(context, _date(i.$2.takenAt)),
    ),
    MediaColumn(
      id: 'camera',
      label: 'Camera',
      flex: 3,
      sortKey: (i) => _camera(i.$2)?.toLowerCase(),
      cell: (context, i) => tableText(context, _camera(i.$2) ?? ''),
    ),
  ];

  /// The day the shutter fell, spoken plainly: `yyyy-MM-dd` or nothing.
  static String _date(DateTime? at) => at == null
      ? ''
      : '${at.year.toString().padLeft(4, '0')}'
            '-${at.month.toString().padLeft(2, '0')}'
            '-${at.day.toString().padLeft(2, '0')}';

  static String? _camera(ImageMetadata metadata) {
    final words = [?metadata.cameraMake, ?metadata.cameraModel];
    return words.isEmpty ? null : words.join(' ');
  }
}
