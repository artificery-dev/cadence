import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

import '../model/player.dart';
import '../model/view_prefs.dart';
import '../util/format.dart';
import '../widgets/art_tile.dart';
import '../widgets/media_table.dart';

/// The songs table — the music library's first facet, spoken through
/// [MediaTable]: sortable headers, a right-click column roster, the
/// playing track wearing the primary dress. Search and the summary live
/// upstairs in the music view; this is just the table.
class LibraryView extends StatelessWidget {
  const LibraryView({
    required this.player,
    required this.items,
    required this.prefs,
    required this.onPrefs,
    super.key,
  });

  final PlaybackController player;
  final List<AudioItem> items;
  final ViewPrefs prefs;
  final void Function(ViewPrefs prefs) onPrefs;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Center(
        child: EmptyState(
          icon: LucideIcons.searchX,
          title: TitleText('No matches'),
          message: BodyText('Nothing in the library sounds like that.'),
        ),
      );
    }
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) => _PlayingScope(
        player: player,
        child: MediaTable<AudioItem>(
          columns: _columns,
          items: items,
          prefs: prefs,
          onPrefs: onPrefs,
          onActivate: player.play,
          isCurrent: (item) => player.current?.id == item.id,
          itemOf: mediaItemOf,
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
      defaultVisible: false,
      sortKey: (i) => i.metadata.trackNumber,
      cell: (context, i) => tableText(
        context,
        i.metadata.trackNumber?.toString() ?? '',
        numeric: true,
      ),
    ),
    MediaColumn(
      id: 'title',
      label: 'Title',
      flex: 5,
      sortKey: (i) => i.metadata.title.toLowerCase(),
      cell: _titleCell,
    ),
    MediaColumn(
      id: 'artist',
      label: 'Artist',
      flex: 4,
      sortKey: (i) => i.metadata.artist?.toLowerCase(),
      cell: (context, i) => tableText(context, i.metadata.artist ?? ''),
    ),
    MediaColumn(
      id: 'album',
      label: 'Album',
      flex: 4,
      sortKey: (i) => i.metadata.album?.toLowerCase(),
      // The record's sleeve rides with its name.
      cell: (context, i) => Row(
        spacing: ThemeProvider.of(context).space.x2,
        children: [
          ArtTile(
            i.metadata.album ?? i.metadata.title,
            size: 32,
            fileId: i.fileId,
          ),
          Flexible(child: tableText(context, i.metadata.album ?? '')),
        ],
      ),
    ),
    MediaColumn(
      id: 'year',
      label: 'Year',
      width: 48,
      numeric: true,
      defaultVisible: false,
      sortKey: (i) => i.metadata.year,
      cell: (context, i) =>
          tableText(context, i.metadata.year?.toString() ?? '', numeric: true),
    ),
    MediaColumn(
      id: 'genre',
      label: 'Genre',
      flex: 2,
      defaultVisible: false,
      sortKey: (i) => i.metadata.genres.firstOrNull?.toLowerCase(),
      cell: (context, i) =>
          tableText(context, i.metadata.genres.firstOrNull ?? ''),
    ),
    MediaColumn(
      id: 'format',
      label: 'Format',
      width: 64,
      defaultVisible: false,
      sortKey: (i) => _format(i),
      cell: (context, i) => tableText(context, _format(i) ?? ''),
    ),
    MediaColumn(
      id: 'bitrate',
      label: 'kbps',
      width: 56,
      numeric: true,
      defaultVisible: false,
      sortKey: (i) => i.metadata.bitrateKbps,
      cell: (context, i) => tableText(
        context,
        i.metadata.bitrateKbps?.toString() ?? '',
        numeric: true,
      ),
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

  static String? _format(AudioItem item) => item.tags
      .where((t) => t.namespace == TagNamespace.format.id)
      .firstOrNull
      ?.name;

  static Widget _titleCell(BuildContext context, AudioItem item) {
    final theme = ThemeProvider.of(context);
    // The playing marker rides in the title cell, as it always has; the
    // row's dress says the rest.
    return Row(
      children: [
        if (_playingIn(context, item)) ...[
          Icon(
            LucideIcons.audioLines,
            size: 14,
            color: theme.palette.primary.s400,
          ),
          SizedBox(width: theme.space.x2),
        ],
        Flexible(child: tableText(context, item.metadata.title, strong: true)),
      ],
    );
  }

  /// Whether [item] is the deck's current track — read through the
  /// nearest player the table was built under.
  static bool _playingIn(BuildContext context, AudioItem item) =>
      _PlayingScope.of(context)?.current?.id == item.id;
}

/// Hands the player down to the title cells without threading it through
/// every column closure.
class _PlayingScope extends InheritedWidget {
  const _PlayingScope({required this.player, required super.child});

  final PlaybackController player;

  static PlaybackController? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PlayingScope>()?.player;

  @override
  bool updateShouldNotify(_PlayingScope oldWidget) =>
      oldWidget.player != player;
}
