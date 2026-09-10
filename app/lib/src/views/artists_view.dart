import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

import '../model/player.dart';
import '../model/view_prefs.dart';
import '../util/format.dart';
import '../widgets/art_tile.dart';
import '../widgets/shelf_grid.dart';
import '../widgets/media_table.dart';

/// One name on the roster, with everything filed under it.
class _ArtistGroup {
  const _ArtistGroup(this.name, this.tracks);

  final String name;
  final List<AudioItem> tracks;

  /// Distinct records on their shelf.
  int get albums => {
    for (final t in tracks)
      if (t.metadata.album != null) t.metadata.album,
  }.length;

  /// Their whole catalogue, added up.
  Duration get playtime => tracks.fold(
    Duration.zero,
    (sum, t) => sum + (t.metadata.duration ?? Duration.zero),
  );
}

/// The roster: every artist as a tile on a grid, or sortable rows in a
/// table. Choosing one either way drops the needle on their first track;
/// a proper artist page comes later.
class ArtistsView extends StatelessWidget {
  const ArtistsView({
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

  /// A tile or a row was chosen: the artist's page opens.
  final void Function(String artist) onOpen;

  List<_ArtistGroup> get _artists {
    final groups = <String, List<AudioItem>>{};
    for (final item in items) {
      groups.putIfAbsent(item.metadata.artist ?? 'Unknown', () => []).add(item);
    }
    final sorted = groups.entries.toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    return [for (final entry in sorted) _ArtistGroup(entry.key, entry.value)];
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final artists = _artists;
    final mode = prefs.mode ?? ViewMode.grid;
    // No strip of its own: the music view's header drives the mode.
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) => mode == ViewMode.table
          ? MediaTable<_ArtistGroup>(
              columns: _columns,
              items: artists,
              prefs: prefs,
              onPrefs: onPrefs,
              onActivate: (artist) => onOpen(artist.name),
              isCurrent: (artist) =>
                  artist.tracks.any((t) => t.id == player.current?.id),
            )
          : GridView.builder(
              padding: EdgeInsets.fromLTRB(
                theme.space.x6,
                0,
                theme.space.x6,
                theme.space.x6,
              ),
              gridDelegate: shelfGridDelegate(theme),
              itemCount: artists.length,
              itemBuilder: (context, index) => _ArtistCell(
                artist: artists[index],
                player: player,
                onOpen: () => onOpen(artists[index].name),
              ),
            ),
    );
  }

  static final _columns = <MediaColumn<_ArtistGroup>>[
    MediaColumn(
      id: 'artist',
      label: 'Artist',
      flex: 5,
      sortKey: (a) => a.name.toLowerCase(),
      cell: (context, a) => tableText(context, a.name, strong: true),
    ),
    MediaColumn(
      id: 'albums',
      label: 'Albums',
      width: 64,
      numeric: true,
      sortKey: (a) => a.albums,
      cell: (context, a) =>
          tableText(context, a.albums.toString(), numeric: true),
    ),
    MediaColumn(
      id: 'songs',
      label: 'Songs',
      width: 64,
      numeric: true,
      sortKey: (a) => a.tracks.length,
      cell: (context, a) =>
          tableText(context, a.tracks.length.toString(), numeric: true),
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

class _ArtistCell extends StatelessWidget {
  const _ArtistCell({
    required this.artist,
    required this.player,
    required this.onOpen,
  });

  final _ArtistGroup artist;
  final PlaybackController player;

  /// The tile opens the artist's page; playing lives there now.
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final palette = theme.palette;
    final secondary = palette.text.withValues(alpha: theme.opacities.secondary);
    final current = artist.tracks.any((t) => t.id == player.current?.id);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Hero(
              tag: 'artist-${artist.name}-art',
              child: ArtTile(artist.name, fileId: artist.tracks.first.fileId),
            ),
            Spacing(SpaceStep.x2),
            Row(
              spacing: theme.space.x1,
              children: [
                if (current)
                  Icon(
                    LucideIcons.audioLines,
                    size: 13,
                    color: palette.primary.s400,
                  ),
                Flexible(
                  child: Hero(
                    tag: 'artist-${artist.name}-title',
                    child: Text(
                      artist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.typography.bodySmall.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            Text(
              '${artist.albums} albums · ${artist.tracks.length} songs',
              style: theme.typography.caption.copyWith(color: secondary),
            ),
          ],
        ),
      ),
    );
  }
}
