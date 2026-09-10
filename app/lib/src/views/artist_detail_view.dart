import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

import '../model/player.dart';
import '../util/format.dart';
import '../widgets/art_tile.dart';
import '../widgets/detail_header.dart';
import '../widgets/item_tap.dart';
import '../widgets/row_surface.dart';

/// One name on the roster, opened: their records as sleeves, their songs
/// beneath. Play deals their whole catalogue onto the deck.
class ArtistDetailView extends StatelessWidget {
  const ArtistDetailView({
    required this.player,
    required this.artist,
    required this.tracks,
    required this.onBack,
    required this.onOpenAlbum,
    required this.onAddToCollection,
    super.key,
  });

  final PlaybackController player;
  final String artist;

  /// Every track crediting the artist, in shelf order.
  final List<AudioItem> tracks;
  final VoidCallback onBack;
  final void Function(String album) onOpenAlbum;

  /// The shell runs the collection flow; the page only offers the door.
  final void Function(List<AudioItem> items) onAddToCollection;

  List<(String, List<AudioItem>)> get _albums {
    final groups = <String, List<AudioItem>>{};
    for (final track in tracks) {
      groups
          .putIfAbsent(track.metadata.album ?? 'Unknown', () => [])
          .add(track);
    }
    return [for (final MapEntry(:key, :value) in groups.entries) (key, value)];
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    if (tracks.isEmpty) {
      return const Center(
        child: EmptyState(
          icon: LucideIcons.micVocal,
          title: TitleText('An empty bill'),
          message: BodyText('Nothing on the shelf credits this artist.'),
        ),
      );
    }
    final albums = _albums;
    final playtime = tracks.fold(
      Duration.zero,
      (sum, t) => sum + (t.metadata.duration ?? Duration.zero),
    );
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) => ListView(
        children: [
          DetailHeader(
            onBack: onBack,
            art: artist,
            artKind: MediaKind.audio,
            artFileId: tracks.first.fileId,
            kicker: 'ARTIST',
            title: artist,
            heroPrefix: 'artist-$artist',
            caption:
                '${albums.length} albums · ${tracks.length} songs · '
                '${formatClock(playtime)}',
            actions: [
              DetailAction(
                icon: LucideIcons.play,
                label: 'Play',
                onPressed: () => player.playCollection(tracks),
                primary: true,
              ),
              DetailAction(
                icon: LucideIcons.shuffle,
                label: 'Shuffle',
                onPressed: () => player.playShuffled(tracks),
              ),
              DetailAction(
                icon: LucideIcons.listPlus,
                label: 'Queue',
                onPressed: () => player.enqueue(tracks),
              ),
              DetailAction(
                icon: LucideIcons.list,
                label: 'Add to…',
                onPressed: () => onAddToCollection(tracks),
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              theme.space.x6,
              theme.space.x4,
              theme.space.x6,
              theme.space.x2,
            ),
            child: const KickerText('ALBUMS'),
          ),
          SizedBox(
            height: 236,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: theme.space.x6),
              itemCount: albums.length,
              separatorBuilder: (context, _) => SizedBox(width: theme.space.x5),
              itemBuilder: (context, index) {
                final (title, items) = albums[index];
                return SizedBox(
                  width: 160,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onOpenAlbum(title),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Hero(
                            tag: 'album-$title-art',
                            child: ArtTile(title, fileId: items.first.fileId),
                          ),
                          Spacing(SpaceStep.x2),
                          Hero(
                            tag: 'album-$title-title',
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.typography.bodySmall.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          CaptionText(
                            '${items.length} tracks',
                            emphasis: TextEmphasis.secondary,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              theme.space.x6,
              theme.space.x4,
              theme.space.x6,
              theme.space.x2,
            ),
            child: const KickerText('SONGS'),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              theme.space.x3,
              0,
              theme.space.x3,
              theme.space.x3,
            ),
            child: Column(
              children: [
                for (final (index, track) in tracks.indexed) ...[
                  _SongRow(
                    track: track,
                    index: index,
                    player: player,
                    all: tracks,
                  ),
                  SizedBox(height: theme.space.x1),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One song on the artist's page — the shared row dress, needle drop on
/// tap, playing straight out of the artist's own catalogue.
class _SongRow extends StatefulWidget {
  const _SongRow({
    required this.track,
    required this.index,
    required this.player,
    required this.all,
  });

  final AudioItem track;
  final int index;
  final PlaybackController player;
  final List<AudioItem> all;

  @override
  State<_SongRow> createState() => _SongRowState();
}

class _SongRowState extends State<_SongRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final metadata = widget.track.metadata;
    final current = widget.player.current?.id == widget.track.id;
    final secondary = theme.palette.text.withValues(
      alpha: theme.opacities.secondary,
    );

    final content = Padding(
      padding: EdgeInsets.symmetric(horizontal: theme.space.x4),
      child: SizedBox(
        height: 28,
        child: DefaultTextStyle.merge(
          style: theme.typography.bodySmall,
          child: Row(
            children: [
              if (current) ...[
                Icon(
                  LucideIcons.audioLines,
                  size: 14,
                  color: theme.palette.primary.s400,
                ),
                SizedBox(width: theme.space.x2),
              ],
              Expanded(
                flex: 5,
                child: Text(
                  metadata.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
              Expanded(
                flex: 4,
                child: Text(
                  metadata.album ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: secondary),
                ),
              ),
              SizedBox(
                width: 56,
                child: Text(
                  formatClock(metadata.duration ?? Duration.zero),
                  textAlign: TextAlign.right,
                  style: theme.typography.caption.copyWith(color: secondary),
                ),
              ),
            ],
          ),
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

    return ItemTap(
      item: mediaItemOf(widget.track),
      onOpen: () =>
          widget.player.playCollection(widget.all, startAt: widget.track),
      onHover: (hover) => setState(() => _hover = hover),
      child: dressed,
    );
  }
}
