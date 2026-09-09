import '../filesystem.dart';
import 'dart:async';
import 'dart:collection';

import 'package:drift/drift.dart';

import '../database/database.dart';
import '../extract/extract.dart';
import '../extract/extractor.dart';
import '../extract/image_extractor.dart' as images;
import '../kinds.dart';
import '../repositories/scanner_repository.dart';

import 'scanner.dart';

/// The pictures, made later.
///
/// Decoding a cover is the slow step of a scan — seconds per track in
/// pure Dart on a small machine — and nothing about a library's shelves
/// waits on it. So under [ArtworkPolicy.deferred] the scan lands files
/// and tags and leaves the pictures to this: a queue of file ids, drained
/// one at a time in the injected filesystem scope, rendering
/// a thumbnail from the file's embedded art or its folder's cover and
/// storing it where the scan would have.
///
/// The queue has a front and a back. [sweep] fills the back with every
/// file that has no thumbnail yet — the scan calls it when it finishes —
/// and [promote] moves ids to the front: the rows on screen, the album
/// being browsed, whatever the player is about to draw. [ensure] promotes
/// one file and waits for its picture, which is how a row asks for art
/// and gets it while the rest of the library is still being drawn in.
class ArtworkQueue {
  ArtworkQueue(
    this.db, {
    FileSystem? fileSystem,
    this.buildExtractor = defaultMediaExtractor,
    this.renderThumbnail = images.renderThumbnail,
    this.thumbnailSide = 256,
    this.onArtworkChanged,
  }) : fileSystem = fileSystem ?? mediaFileSystem,
       _repo = ScannerRepository(db);

  final FileSystem fileSystem;

  final MediaDatabase db;
  final ScannerRepository _repo;

  final ExtractorBuilder buildExtractor;
  final ThumbnailRenderer renderThumbnail;
  final int thumbnailSide;
  final void Function(int fileId)? onArtworkChanged;

  final _queue = ListQueue<int>();
  final _queued = <int>{};
  final _waiters = <int, List<Completer<ArtworkRow?>>>{};

  /// Files looked at and found bare: no embedded art, no folder cover.
  /// Not asked again until the next [sweep], which starts afresh.
  final _bare = <int>{};

  MediaExtractor? _local;
  bool _pumping = false;
  bool _closed = false;
  Completer<void>? _idle;

  /// How many pictures have been rendered since the queue was made.
  int rendered = 0;

  /// How many files turned out to have nothing to render.
  int bare = 0;

  int get pending => _queue.length;
  bool get running => _pumping;

  Map<String, Object?> toJson() => {
    'pending': pending,
    'running': running,
    'rendered': rendered,
    'bare': bare,
  };

  /// Put [fileIds] at the front, first of them first. Ids already queued
  /// move; ids already rendered or known bare are ignored.
  void promote(Iterable<int> fileIds) {
    final front = <int>[];
    for (final id in fileIds) {
      if (_bare.contains(id) || front.contains(id)) continue;
      if (_queued.remove(id)) _queue.remove(id);
      front.add(id);
    }
    for (final id in front.reversed) {
      _queue.addFirst(id);
      _queued.add(id);
    }
    _pump();
  }

  /// Put every file without a thumbnail at the back — all of them, or
  /// only a library's. Answers how many were added. Files that were found
  /// bare are given another look: the sweep is where a new cover beside
  /// an old track gets noticed.
  Future<int> sweep([int? libraryId]) async {
    _bare.clear();
    final thumbed = db.selectOnly(db.artworks)
      ..addColumns([db.artworks.fileId])
      ..where(db.artworks.role.equalsValue(ArtworkRole.thumbnail));
    final query = db.selectOnly(db.files)
      ..addColumns([db.files.id])
      ..where(
        db.files.missingSince.isNull() &
            db.files.id.isNotInQuery(thumbed) &
            db.files.kind.equalsValue(MediaKind.document).not(),
      )
      ..orderBy([OrderingTerm.asc(db.files.id)]);
    if (libraryId != null) {
      final members = db.selectOnly(db.libraryItems)
        ..addColumns([db.libraryItems.fileId])
        ..where(db.libraryItems.libraryId.equals(libraryId));
      query.where(db.files.id.isInQuery(members));
    }
    final rows = await query.get();
    var added = 0;
    for (final row in rows) {
      final id = row.read(db.files.id)!;
      if (_queued.add(id)) {
        _queue.addLast(id);
        added++;
      }
    }
    _pump();
    return added;
  }

  /// The file's thumbnail: the stored one at once, or — promoted to the
  /// front — the one rendered within [timeout]. Null when the file has no
  /// art to render, or the wait ran out (the job stays queued; a later
  /// ask finds the picture stored).
  Future<ArtworkRow?> ensure(
    int fileId, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final stored = await _stored(fileId);
    if (stored != null) return stored;
    if (_bare.contains(fileId) || _closed) return null;
    final completer = Completer<ArtworkRow?>();
    _waiters.putIfAbsent(fileId, () => []).add(completer);
    promote([fileId]);
    return completer.future.timeout(timeout, onTimeout: () => null);
  }

  /// Completes when there is nothing left to draw.
  Future<void> idle() =>
      _pumping ? (_idle ??= Completer<void>()).future : Future<void>.value();

  Future<void> close() async {
    _closed = true;
    _queue.clear();
    _queued.clear();
    for (final waiters in _waiters.values) {
      for (final waiter in waiters) {
        if (!waiter.isCompleted) waiter.complete(null);
      }
    }
    _waiters.clear();
    await idle();
  }

  Future<ArtworkRow?> _stored(int fileId) =>
      (db.select(db.artworks)
            ..where(
              (a) =>
                  a.fileId.equals(fileId) &
                  a.role.equalsValue(ArtworkRole.thumbnail),
            )
            ..limit(1))
          .getSingleOrNull();

  void _pump() {
    if (_pumping || _closed) return;
    _pumping = true;
    unawaited(withMediaFileSystem(fileSystem, _drain));
  }

  Future<void> _drain() async {
    try {
      while (_queue.isNotEmpty && !_closed) {
        final id = _queue.removeFirst();
        _queued.remove(id);
        ArtworkRow? row;
        try {
          row = await _one(id);
        } on Object {
          row = null;
        }
        final waiters = _waiters.remove(id);
        if (waiters != null) {
          for (final waiter in waiters) {
            if (!waiter.isCompleted) waiter.complete(row);
          }
        }
        // A breath between pictures, so the isolate this runs on stays
        // answerable to whoever else shares it.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _pumping = false;
      _idle?.complete();
      _idle = null;
    }
  }

  Future<ArtworkRow?> _one(int fileId) async {
    final stored = await _stored(fileId);
    if (stored != null) return stored;
    final file = await (db.select(
      db.files,
    )..where((f) => f.id.equals(fileId))).getSingleOrNull();
    if (file == null || file.kind == MediaKind.document) return null;
    final cover =
        await (db.select(db.sidecars)
              ..where(
                (s) =>
                    s.fileId.equals(fileId) &
                    s.kind.equalsValue(SidecarKind.artwork),
              )
              ..limit(1))
            .getSingleOrNull();
    final job = _ArtworkJob(file.path, file.kind, cover?.path, thumbnailSide);
    final _Rendered? rendered;
    rendered = await _renderWith(
      _local ??= buildExtractor(),
      renderThumbnail,
      job,
    );
    if (rendered == null) {
      _bare.add(fileId);
      bare++;
      return null;
    }
    await _repo.replaceArtwork(fileId, ArtworkRole.thumbnail, [
      ExtractedArtwork(
        bytes: rendered.bytes,
        mime: rendered.mime,
        role: ArtworkRole.thumbnail,
      ),
    ]);
    this.rendered++;
    try {
      onArtworkChanged?.call(fileId);
    } catch (_) {}
    return _stored(fileId);
  }
}

/// One picture to make: the file, what it is, the cover beside it if the
/// scan found one, and how big.
class _ArtworkJob {
  const _ArtworkJob(this.path, this.kind, this.folderArt, this.side);

  final String path;
  final MediaKind kind;
  final String? folderArt;
  final int side;
}

class _Rendered {
  const _Rendered(this.bytes, this.mime);

  final Uint8List bytes;
  final String mime;
}

/// Where a thumbnail comes from: the image itself when the file is one,
/// else its embedded art, else the folder's cover. Null when there is
/// none of those, or the render refused.
Future<_Rendered?> _renderWith(
  MediaExtractor extractor,
  ThumbnailRenderer render,
  _ArtworkJob job,
) async {
  List<int>? source;
  if (job.kind == MediaKind.image) {
    source = await mediaFileSystem.file(job.path).readAsBytes();
  } else {
    final extracted = await extractor.extract(job.path, job.kind);
    for (final art in extracted.artwork) {
      if (art.role == ArtworkRole.embedded) {
        source = art.bytes;
        break;
      }
    }
  }
  final folderArt = job.folderArt;
  if (source == null &&
      folderArt != null &&
      mediaFileSystem.file(folderArt).existsSync()) {
    source = await mediaFileSystem.file(folderArt).readAsBytes();
  }
  if (source == null) return null;
  final ExtractedArtwork? thumb;
  try {
    thumb = render(source, longestSide: job.side);
  } on Object {
    return null;
  }
  if (thumb == null) return null;
  return _Rendered(
    thumb.bytes is Uint8List
        ? thumb.bytes as Uint8List
        : Uint8List.fromList(thumb.bytes),
    thumb.mime,
  );
}
