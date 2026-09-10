import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

import '../model/player.dart';
import '../model/view_prefs.dart';
import '../util/format.dart';
import '../widgets/art_tile.dart';
import '../widgets/shelf_grid.dart';
import '../widgets/media_table.dart';

/// One record in the crate, grouped out of the items' metadata.
class _AlbumGroup {
  const _AlbumGroup(this.title, this.artist, this.year, this.items);

  final String title;
  final String artist;
  final int? year;
  final List<AudioItem> items;

  /// The whole side, added up.
  Duration get playtime => items.fold(
    Duration.zero,
    (sum, item) => sum + (item.metadata.duration ?? Duration.zero),
  );
}

/// The record crate: every album as a sleeve, or — flipped to table — as
/// a sortable row. Choosing one either way drops the needle on track one.
class AlbumsView extends StatelessWidget {
  const AlbumsView({
    required this.player,
    required this.items,
    required this.prefs,
    required this.onPrefs,
    required this.onOpen,
    super.key,
  });

  final PlaybackController player;
  final List<AudioItem> items;

  /// Presentation choices (mode, columns, sort) and where they land.
  final ViewPrefs prefs;
  final void Function(ViewPrefs prefs) onPrefs;

  /// A sleeve or a row was chosen: the album's page opens.
  final void Function(String album) onOpen;

  List<_AlbumGroup> get _albums {
    final groups = <String, List<AudioItem>>{};
    for (final item in items) {
      groups.putIfAbsent(item.metadata.album ?? 'Unknown', () => []).add(item);
    }
    return [
      for (final MapEntry(key: title, value: tracks) in groups.entries)
        _AlbumGroup(
          title,
          tracks.first.metadata.albumArtist ??
              tracks.first.metadata.artist ??
              'Unknown',
          tracks.first.metadata.year,
          tracks,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final albums = _albums;
    final mode = prefs.mode ?? ViewMode.grid;
    // No strip of its own: the music view's header drives the mode.
    return mode == ViewMode.table
        ? MediaTable<_AlbumGroup>(
            columns: _columns,
            items: albums,
            prefs: prefs,
            onPrefs: onPrefs,
            onActivate: (album) => onOpen(album.title),
          )
        : _grid(theme, albums);
  }

  Widget _grid(Theme theme, List<_AlbumGroup> albums) => GridView.builder(
    padding: EdgeInsets.fromLTRB(
      theme.space.x6,
      0,
      theme.space.x6,
      theme.space.x6,
    ),
    gridDelegate: shelfGridDelegate(theme),
    itemCount: albums.length,
    itemBuilder: (context, index) {
      final album = albums[index];
      return _AlbumCell(album: album, onOpen: () => onOpen(album.title));
    },
  );

  static final _columns = <MediaColumn<_AlbumGroup>>[
    MediaColumn(
      id: 'album',
      label: 'Album',
      flex: 5,
      sortKey: (a) => a.title.toLowerCase(),
      // The sleeve rides with the name.
      cell: (context, a) => Row(
        spacing: ThemeProvider.of(context).space.x2,
        children: [
          ArtTile(a.title, size: 32, fileId: a.items.first.fileId),
          Flexible(child: tableText(context, a.title, strong: true)),
        ],
      ),
    ),
    MediaColumn(
      id: 'artist',
      label: 'Artist',
      flex: 4,
      sortKey: (a) => a.artist.toLowerCase(),
      cell: (context, a) => tableText(context, a.artist),
    ),
    MediaColumn(
      id: 'year',
      label: 'Year',
      width: 48,
      numeric: true,
      sortKey: (a) => a.year,
      cell: (context, a) =>
          tableText(context, a.year?.toString() ?? '', numeric: true),
    ),
    MediaColumn(
      id: 'tracks',
      label: 'Tracks',
      width: 56,
      numeric: true,
      sortKey: (a) => a.items.length,
      cell: (context, a) =>
          tableText(context, a.items.length.toString(), numeric: true),
    ),
    MediaColumn(
      id: 'time',
      label: 'Time',
      width: 64,
      numeric: true,
      sortKey: (a) => a.playtime.inMilliseconds,
      cell: (context, a) =>
          tableText(context, formatClock(a.playtime), numeric: true),
    ),
  ];
}

class _AlbumCell extends StatelessWidget {
  const _AlbumCell({required this.album, required this.onOpen});

  final _AlbumGroup album;

  /// The sleeve opens the record's page; playing lives there now.
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final palette = theme.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Hero(
              tag: 'album-${album.title}-art',
              child: ArtTile(album.title, fileId: album.items.first.fileId),
            ),
            Spacing(SpaceStep.x2),
            Hero(
              tag: 'album-${album.title}-title',
              child: Text(
                album.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.bodySmall.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              album.year == null
                  ? album.artist
                  : '${album.artist} · ${album.year}',
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
    );
  }
}
