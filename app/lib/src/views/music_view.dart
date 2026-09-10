import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

import '../model/library_views.dart';
import '../model/player.dart';
import '../model/view_prefs.dart';
import '../widgets/media_table.dart';
import '../widgets/shelf_header.dart';
import 'albums_view.dart';
import 'artists_view.dart';
import 'library_view.dart';

/// The music library's one page: Songs, Albums, and Artists as facets
/// toggled inline, with the summary standing over all three. Each facet
/// keeps its own presentation choices under its own prefs key — a sort
/// chosen for the songs table does not chase the albums grid around.
/// Search left the page body for the sidebar's palette.
class MusicView extends StatefulWidget {
  const MusicView({
    required this.player,
    required this.items,
    required this.client,
    required this.prefs,
    required this.libraryId,
    required this.onOpenAlbum,
    required this.onOpenArtist,
    super.key,
  });

  final PlaybackController player;
  final List<AudioItem> items;
  final MediaClient client;
  final ViewPrefsStore prefs;
  final int libraryId;

  /// A sleeve or a name was chosen: the shell opens its page.
  final void Function(String album) onOpenAlbum;
  final void Function(String artist) onOpenArtist;

  @override
  State<MusicView> createState() => _MusicViewState();
}

class _MusicViewState extends State<MusicView> {
  String get _summary {
    final items = widget.items;
    final albums = {for (final i in items) i.metadata.album}.length;
    final total = items.fold(
      Duration.zero,
      (sum, i) => sum + (i.metadata.duration ?? Duration.zero),
    );
    final hours = total.inHours;
    final minutes = total.inMinutes.remainder(60);
    return '${items.length} songs · $albums albums · ${hours}h ${minutes}m';
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return ListenableBuilder(
      listenable: widget.prefs,
      builder: (context, _) {
        final facet = widget.prefs.facetOf(
          widget.libraryId,
          fallback: LibraryViewKind.songs,
        );
        final faceted = facet == LibraryViewKind.albums
            ? LibraryViewKind.albums
            : facet == LibraryViewKind.artists
            ? LibraryViewKind.artists
            : LibraryViewKind.songs;
        final facetPrefs = widget.prefs.of(widget.libraryId, faceted);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ShelfHeader(
              leading: [
                SegmentedControl<LibraryViewKind>(
                  value: facet,
                  onChanged: (kind) =>
                      widget.prefs.setFacet(widget.libraryId, kind),
                  segments: const [
                    SegmentOption(
                      value: LibraryViewKind.songs,
                      label: Text('Songs'),
                    ),
                    SegmentOption(
                      value: LibraryViewKind.albums,
                      label: Text('Albums'),
                    ),
                    SegmentOption(
                      value: LibraryViewKind.artists,
                      label: Text('Artists'),
                    ),
                  ],
                ),
              ],
              trailing: [
                // Songs is table through and through; the crate and the
                // roster answer the toggle.
                if (faceted != LibraryViewKind.songs)
                  ViewModeToggle(
                    mode: facetPrefs.mode ?? ViewMode.grid,
                    onChanged: (mode) => widget.prefs.update(
                      widget.libraryId,
                      faceted,
                      facetPrefs.copyWith(mode: mode),
                    ),
                  ),
              ],
            ),
            // The tallies, right under the picker's arm.
            Padding(
              padding: EdgeInsets.fromLTRB(
                theme.space.x4,
                0,
                theme.space.x4,
                theme.space.x3,
              ),
              child: Row(children: [CaptionText(_summary)]),
            ),
            Expanded(child: _facetBody(facet)),
          ],
        );
      },
    );
  }

  Widget _facetBody(LibraryViewKind facet) {
    final visible = widget.items;
    ViewPrefs prefsOf(LibraryViewKind kind) =>
        widget.prefs.of(widget.libraryId, kind);
    void save(LibraryViewKind kind, ViewPrefs value) =>
        widget.prefs.update(widget.libraryId, kind, value);
    return switch (facet) {
      LibraryViewKind.albums => AlbumsView(
        player: widget.player,
        items: visible,
        prefs: prefsOf(LibraryViewKind.albums),
        onPrefs: (value) => save(LibraryViewKind.albums, value),
        onOpen: widget.onOpenAlbum,
      ),
      LibraryViewKind.artists => ArtistsView(
        player: widget.player,
        items: visible,
        prefs: prefsOf(LibraryViewKind.artists),
        onPrefs: (value) => save(LibraryViewKind.artists, value),
        onOpen: widget.onOpenArtist,
      ),
      _ => LibraryView(
        player: widget.player,
        items: visible,
        prefs: prefsOf(LibraryViewKind.songs),
        onPrefs: (value) => save(LibraryViewKind.songs, value),
      ),
    };
  }
}
