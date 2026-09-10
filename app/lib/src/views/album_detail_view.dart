import 'package:cadence_media/cadence_media.dart' hide Link;
import 'package:tomeui/tomeui.dart';

import '../model/player.dart';
import '../model/view_prefs.dart';
import '../util/format.dart';
import '../widgets/detail_header.dart';
import '../widgets/media_table.dart';

/// One record, opened: the sleeve and its credits up top, the tracks in
/// order beneath. Play deals the album onto the deck as its own queue;
/// a track row drops the needle right there.
class AlbumDetailView extends StatefulWidget {
  const AlbumDetailView({
    required this.player,
    required this.album,
    required this.tracks,
    required this.onBack,
    required this.onOpenArtist,
    required this.onAddToCollection,
    super.key,
  });

  final PlaybackController player;
  final String album;

  /// The album's tracks, in shelf order.
  final List<AudioItem> tracks;
  final VoidCallback onBack;
  final void Function(String artist) onOpenArtist;

  /// The shell runs the collection flow; the page only offers the door.
  final void Function(List<AudioItem> items) onAddToCollection;

  @override
  State<AlbumDetailView> createState() => _AlbumDetailViewState();
}

class _AlbumDetailViewState extends State<AlbumDetailView> {
  /// Sort choices live for the visit; the page keeps no ledger. The
  /// record opens in its own running order.
  ViewPrefs _prefs = const ViewPrefs(sortColumn: 'track');

  void _play([AudioItem? startAt]) =>
      widget.player.playCollection(widget.tracks, startAt: startAt);

  @override
  Widget build(BuildContext context) {
    final tracks = widget.tracks;
    if (tracks.isEmpty) {
      return const Center(
        child: EmptyState(
          icon: LucideIcons.discAlbum,
          title: TitleText('An empty sleeve'),
          message: BodyText('This album has no tracks on the shelf.'),
        ),
      );
    }
    final first = tracks.first.metadata;
    final artist = first.albumArtist ?? first.artist ?? 'Unknown';
    final year = first.year;
    final playtime = tracks.fold(
      Duration.zero,
      (sum, t) => sum + (t.metadata.duration ?? Duration.zero),
    );
    final header = DetailHeader(
      onBack: widget.onBack,
      art: widget.album,
      artKind: MediaKind.audio,
      artFileId: tracks.first.fileId,
      kicker: 'ALBUM',
      title: widget.album,
      heroPrefix: 'album-${widget.album}',
      subtitle: Link(artist, onPressed: () => widget.onOpenArtist(artist)),
      caption: [
        if (year != null) '$year',
        '${tracks.length} tracks',
        formatClock(playtime),
      ].join(' · '),
      actions: [
        DetailAction(
          icon: LucideIcons.play,
          label: 'Play',
          onPressed: _play,
          primary: true,
        ),
        DetailAction(
          icon: LucideIcons.shuffle,
          label: 'Shuffle',
          onPressed: () => widget.player.playShuffled(widget.tracks),
        ),
        DetailAction(
          icon: LucideIcons.listPlus,
          label: 'Queue',
          onPressed: () => widget.player.enqueue(widget.tracks),
        ),
        DetailAction(
          icon: LucideIcons.list,
          label: 'Add to…',
          onPressed: () => widget.onAddToCollection(widget.tracks),
        ),
      ],
    );
    return ListenableBuilder(
      listenable: widget.player,
      builder: (context, _) => NestedScrollView(
        headerSliverBuilder: (context, _) => [
          SliverPersistentHeader(
            pinned: true,
            delegate: CollapsingDetailHeader(
              header: header,
              details: [
                artist,
                if (year != null) '$year',
                '${tracks.length} tracks · ${formatClock(playtime)}',
              ],
            ),
          ),
        ],
        body: MediaTable<AudioItem>(
          columns: _columns,
          items: tracks,
          prefs: _prefs,
          onPrefs: (prefs) => setState(() => _prefs = prefs),
          onActivate: _play,
          isCurrent: (item) => widget.player.current?.id == item.id,
          itemOf: mediaItemOf,
          primary: true,
        ),
      ),
    );
  }

  static final _columns = <MediaColumn<AudioItem>>[
    MediaColumn(
      id: 'track',
      label: '#',
      width: 36,
      numeric: true,
      // Disc-aware: side two follows side one, whatever order the shelf
      // holds the files in.
      sortKey: (i) =>
          (i.metadata.discNumber ?? 1) * 1000 + (i.metadata.trackNumber ?? 0),
      cell: (context, i) => tableText(
        context,
        i.metadata.trackNumber?.toString() ?? '',
        numeric: true,
      ),
    ),
    MediaColumn(
      id: 'title',
      label: 'Title',
      flex: 6,
      sortKey: (i) => i.metadata.title.toLowerCase(),
      cell: (context, i) => tableText(context, i.metadata.title, strong: true),
    ),
    MediaColumn(
      id: 'artist',
      label: 'Artist',
      flex: 3,
      defaultVisible: false,
      sortKey: (i) => i.metadata.artist?.toLowerCase(),
      cell: (context, i) => tableText(context, i.metadata.artist ?? ''),
    ),
    MediaColumn(
      id: 'time',
      label: 'Time',
      width: 56,
      numeric: true,
      sortKey: (i) => i.metadata.duration?.inMilliseconds,
      cell: (context, i) => tableText(
        context,
        formatClock(i.metadata.duration ?? Duration.zero),
        numeric: true,
      ),
    ),
  ];
}
