/// Where a drill-in points: a page about one thing — an album, an
/// artist, a series — layered over the library view that opened it.
/// The shell keeps these on a trail; back pops, and choosing anything
/// in the sidebar clears the whole walk.
sealed class DetailTarget {
  const DetailTarget(this.libraryId);

  /// The library whose shelves the page reads from.
  final int libraryId;
}

/// One record: its sleeve, its credits, its tracks.
class AlbumDetail extends DetailTarget {
  const AlbumDetail(super.libraryId, this.album);

  final String album;

  @override
  bool operator ==(Object other) =>
      other is AlbumDetail &&
      other.libraryId == libraryId &&
      other.album == album;

  @override
  int get hashCode => Object.hash(AlbumDetail, libraryId, album);
}

/// One name on the roster: their records, their songs.
class ArtistDetail extends DetailTarget {
  const ArtistDetail(super.libraryId, this.artist);

  final String artist;

  @override
  bool operator ==(Object other) =>
      other is ArtistDetail &&
      other.libraryId == libraryId &&
      other.artist == artist;

  @override
  int get hashCode => Object.hash(ArtistDetail, libraryId, artist);
}

/// One run — a show's episodes, a podcast's feed, a comic's issues; the
/// page reads the library's type to know which it is.
class SeriesDetail extends DetailTarget {
  const SeriesDetail(super.libraryId, this.series);

  final String series;

  @override
  bool operator ==(Object other) =>
      other is SeriesDetail &&
      other.libraryId == libraryId &&
      other.series == series;

  @override
  int get hashCode => Object.hash(SeriesDetail, libraryId, series);
}
