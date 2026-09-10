import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

/// The views a library can open in the sidebar. A library type exposes one
/// or more of these: one, and the library's own row is the destination;
/// more, and the library becomes a collapsible section with its views
/// beneath it.
enum LibraryViewKind {
  /// The music library's one view; Songs, Albums, and Artists live inside
  /// it as facets, toggled in the page rather than the sidebar.
  music('Music', LucideIcons.music),
  songs('Songs', LucideIcons.music),
  albums('Albums', LucideIcons.discAlbum),
  artists('Artists', LucideIcons.micVocal),
  episodes('Episodes', LucideIcons.tv),
  movies('Movies', LucideIcons.film),
  books('Books', LucideIcons.bookOpen),
  comics('Comics', LucideIcons.bookImage),
  gallery('Gallery', LucideIcons.images);

  const LibraryViewKind(this.label, this.icon);

  final String label;
  final IconData icon;
}

extension LibraryTypeViews on LibraryType {
  /// What this kind of library opens as — one view each, every one of
  /// them configurable in the page (facets, grid or table, columns)
  /// rather than special in the sidebar.
  List<LibraryViewKind> get views => switch (this) {
    LibraryType.music => const [LibraryViewKind.music],
    // Podcasts are episodic like Shows and borrow their view until they
    // deepen enough (feeds, unplayed counts) to deserve their own.
    LibraryType.podcasts => const [LibraryViewKind.episodes],
    LibraryType.shows => const [LibraryViewKind.episodes],
    LibraryType.movies => const [LibraryViewKind.movies],
    LibraryType.books => const [LibraryViewKind.books],
    LibraryType.comics => const [LibraryViewKind.comics],
    LibraryType.images => const [LibraryViewKind.gallery],
  };

  /// The glyph the library itself wears in the sidebar.
  IconData get icon => switch (this) {
    LibraryType.music => LucideIcons.music,
    LibraryType.podcasts => LucideIcons.podcast,
    LibraryType.shows => LucideIcons.tv,
    LibraryType.movies => LucideIcons.film,
    LibraryType.books => LucideIcons.book,
    LibraryType.comics => LucideIcons.bookImage,
    LibraryType.images => LucideIcons.images,
  };
}
