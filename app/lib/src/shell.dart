import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:cadence_media/cadence_media.dart'
    hide File, Directory, FileSystemEntity, FileSystem, Link;
import 'package:file_selector/file_selector.dart' show getDirectoryPath;
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;
import 'package:path/path.dart' as p;
import 'package:tomeui/tomeui.dart';
import 'package:window_manager/window_manager.dart';

import 'data/artwork_cache.dart';
import 'data/bootstrap.dart';
import 'model/library_views.dart';
import 'model/details.dart';
import 'model/settings.dart';
import 'model/view_prefs.dart';
import 'views/books_view.dart';
import 'views/album_detail_view.dart';
import 'views/artist_detail_view.dart';
import 'views/collection_view.dart';
import 'views/comics_view.dart';
import 'views/series_detail_view.dart';
import 'views/gallery_view.dart';
import 'views/music_view.dart';
import 'views/now_playing_view.dart';
import 'views/settings_view.dart';
import 'views/shows_view.dart';
import 'views/videos_view.dart';
import 'widgets/app_dialog.dart';
import 'widgets/shelf_actions.dart';
import 'widgets/trailing_panel.dart';
import 'widgets/video_surface.dart';
import 'widgets/row_surface.dart';
import 'widgets/transport_bar.dart';

/// The fixed destinations that belong to no library.
enum AppView { nowPlaying, settings }

/// Where the sidebar can point: a view of a library, a collection, or one
/// of the fixed destinations. A sealed set rather than strings, so the
/// switch is exhaustive.
sealed class NavTarget {
  const NavTarget();
}

class LibraryTarget extends NavTarget {
  const LibraryTarget(this.libraryId, this.view);

  final int libraryId;
  final LibraryViewKind view;

  @override
  bool operator ==(Object other) =>
      other is LibraryTarget &&
      other.libraryId == libraryId &&
      other.view == view;

  @override
  int get hashCode => Object.hash(libraryId, view);
}

class CollectionTarget extends NavTarget {
  const CollectionTarget(this.collectionId);

  final int collectionId;

  @override
  bool operator ==(Object other) =>
      other is CollectionTarget && other.collectionId == collectionId;

  @override
  int get hashCode => collectionId.hashCode;
}

/// Not a destination: choosing it opens the search palette, and the
/// sidebar's selection stays where it was.
class SearchTrigger extends NavTarget {
  const SearchTrigger();

  @override
  bool operator ==(Object other) => other is SearchTrigger;

  @override
  int get hashCode => (SearchTrigger).hashCode;
}

class AppTarget extends NavTarget {
  const AppTarget(this.view);

  final AppView view;

  @override
  bool operator ==(Object other) => other is AppTarget && other.view == view;

  @override
  int get hashCode => view.hashCode;
}

/// The window: title bar up top, navigation down the side, the transport
/// deck along the bottom, and the current view in the middle.
class AppShell extends StatefulWidget {
  const AppShell({required this.boot, super.key});

  /// The breath between scan status polls. Tests turn it down; the running
  /// app leaves it alone.
  static Duration scanPollInterval = const Duration(milliseconds: 800);

  /// Stands in for the OS folder browser. Tests hand one in; the running
  /// app leaves it null and gets the real thing.
  static Future<String?> Function(String startIn)? pickDirectoryOverride;

  /// Stands in for showing a folder in the OS file explorer, the same way.
  static Future<void> Function(String path)? revealDirectoryOverride;

  /// Stands in for the OS window going fullscreen. Tests hand one in;
  /// the running app leaves it null and gets window_manager.
  static Future<void> Function(bool fullscreen)? setFullScreenOverride;

  final Bootstrap boot;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  /// The deck's home — the first audio shelf — re-chosen when it is
  /// deleted. Null means no audio library exists yet.
  late int? _homeId = boot.library?.id;

  late NavTarget _target =
      _decodeTarget(boot.settings.lastView) ??
      (_homeId == null
          ? const AppTarget(AppView.nowPlaying)
          : LibraryTarget(_homeId!, LibraryViewKind.music));

  /// The target last written down, so build only writes changes.
  NavTarget? _persistedTarget;

  /// Where the sidebar points, as the settings table stores it.
  static Map<String, Object?> _encodeTarget(NavTarget target) =>
      switch (target) {
        LibraryTarget(:final libraryId, :final view) => {
          'library': libraryId,
          'view': view.name,
        },
        CollectionTarget(:final collectionId) => {'collection': collectionId},
        AppTarget(:final view) => {'app': view.name},
        SearchTrigger() => const {},
      };

  /// The remembered target, when what it names still exists — a deleted
  /// library or collection falls back to the default quietly.
  NavTarget? _decodeTarget(Map<String, Object?> json) {
    if (json['library'] case final num id) {
      final library = boot.allLibraries
          .where((l) => l.id == id.toInt())
          .firstOrNull;
      if (library == null) return null;
      final kind = LibraryViewKind.values
          .where((k) => k.name == json['view'])
          .firstOrNull;
      if (kind == null || !library.type.views.contains(kind)) return null;
      return LibraryTarget(library.id, kind);
    }
    if (json['collection'] case final num id) {
      return boot.collections.any((c) => c.id == id.toInt())
          ? CollectionTarget(id.toInt())
          : null;
    }
    if (json['app'] case final String name) {
      final view = AppView.values.where((v) => v.name == name).firstOrNull;
      return view == null ? null : AppTarget(view);
    }
    return null;
  }

  /// Libraries and collections live locally so creating one lands without
  /// a restart. Copies, because dragging rearranges them in place.
  late List<LibraryRow> _libraries = List.of(boot.allLibraries);
  late Map<int, List<MediaItem>> _itemsByLibrary = boot.itemsByLibrary;

  /// The audio shelves, reloaded alongside [_itemsByLibrary] — the songs,
  /// albums, and artists views read these, never the bootstrap's frozen
  /// list, so a scan's arrivals actually reach the screen.
  late Map<int, List<AudioItem>> _audioByLibrary = {
    if (boot.library case final home?) home.id: boot.items,
  };
  late List<CollectionRow> _collections = List.of(boot.collections);

  /// The drill-in walk: album pages, artist pages, series pages, stacked
  /// over the library view that opened them. Sidebar choices clear it.
  final List<DetailTarget> _trail = [];

  /// The item the trailing panel's Info tab holds — null when the
  /// queue stands alone, untabbed.
  MediaItem? _inspected;

  /// Which tab fronts while [_inspected] stands — true is Info. A new
  /// inspection always fronts it; the Queue tab flips back without
  /// letting the inspection go.
  bool _infoTab = false;
  late Map<int, List<int>> _collectionEntries = boot.collectionEntries;

  /// Whether each section has been unlocked for dragging. A mode, not a
  /// setting: it lasts as long as the rearranging does, and the next
  /// launch comes up locked again.
  bool _rearrangeLibraries = false;
  bool _rearrangeCollections = false;

  /// The pictures, fetched once and remembered; scans clear it so new
  /// covers reach the shelves.
  late final ArtworkCache _artwork = ArtworkCache(boot.connection);

  /// Every view's presentation choices — facets, grid or table, columns,
  /// sorts — loaded lazily, persisted quietly.
  late final ViewPrefsStore _viewPrefs = ViewPrefsStore(boot.client);

  Bootstrap get boot => widget.boot;

  /// The film the shell last walked to Now Playing for — so scrubbing
  /// and pausing don't re-navigate, only a new opening does.
  int? _followedFilm;

  /// The host's own word that something changed — a scan the daemon ran
  /// on its own, a watcher's rescan, another client's edit — gathered
  /// for a beat, then the shelves reload. Quiet while a scan is being
  /// followed from here: the follow reloads when it lands.
  StreamSubscription<Map<String, Object?>>? _events;
  Timer? _refresh;
  int _following = 0;

  @override
  void initState() {
    super.initState();
    boot.player.addListener(_followTheFilm);
    boot.player.addListener(_syncFullscreen);
    _events = boot.connection.events.listen(_onLibraryEvent);
    boot.hosting?.addListener(_watchHosting);
    if (boot.hosting?.notice case final notice?) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showToast(
            context,
            swatch: SemanticSwatch.warning,
            duration: const Duration(seconds: 12),
            message: Text(notice),
          );
        }
      });
    }
  }

  @override
  void dispose() {
    boot.player.removeListener(_followTheFilm);
    boot.player.removeListener(_syncFullscreen);
    _events?.cancel();
    _refresh?.cancel();
    boot.hosting?.removeListener(_watchHosting);
    _artwork.dispose();
    _viewPrefs.dispose();
    super.dispose();
  }

  /// The hosting spoke: a handover finished, or the daemon dropped out and
  /// the library came back inside. Say so once, and reload — the shelves
  /// may have moved on while the line was down.
  String? _hostingError;
  bool _hostingBusy = false;

  void _watchHosting() {
    final hosting = boot.hosting!;
    if (!mounted) return;
    final error = hosting.error;
    if (error != null && error != _hostingError) {
      showToast(
        context,
        swatch: SemanticSwatch.warning,
        duration: const Duration(seconds: 12),
        message: Text(error),
      );
    }
    _hostingError = error;
    if (_hostingBusy && !hosting.busy) {
      unawaited(() async {
        try {
          await _reloadLibraries();
          await _reloadCollections();
          _artwork.invalidate();
        } on Object {
          // The next event or click reloads.
        }
      }());
    }
    _hostingBusy = hosting.busy;
  }

  static const _shelfEvents = {
    'change',
    'snapshot-required',
    'media-item-added',
    'media-item-updated',
    'media-item-field-update',
    'media-item-enriched',
  };

  void _onLibraryEvent(Map<String, Object?> event) {
    final type = event['type'];
    if (type == 'media-artwork-updated') {
      if (event['fileId'] case final int fileId) _artwork.forget(fileId);
      return;
    }
    if (!_shelfEvents.contains(type)) return;
    _refresh?.cancel();
    _refresh = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted || _following > 0) return;
      unawaited(() async {
        try {
          await _reloadLibraries();
          await _reloadCollections();
        } on Object {
          // A reload that fails is retried by the next event; the shelves
          // keep what they had.
        }
      }());
    });
  }

  /// The OS window follows the deck's fullscreen flag; the layout below
  /// follows with it.
  bool _windowFullscreen = false;

  void _syncFullscreen() {
    final want = boot.player.fullscreen;
    if (want == _windowFullscreen || !mounted) return;
    _windowFullscreen = want;
    final set = AppShell.setFullScreenOverride;
    unawaited(() async {
      try {
        await (set != null ? set(want) : windowManager.setFullScreen(want));
      } catch (_) {
        // A window that refuses fullscreen still gets the layout.
      }
    }());
    setState(() {});
  }

  /// Starting a film takes you to Now Playing; leaving it again leaves
  /// the pip window behind instead.
  void _followTheFilm() {
    final opened = boot.player.opened;
    if (opened == null || opened.metadata is! VideoMetadata) {
      _followedFilm = null;
      return;
    }
    if (opened.id == _followedFilm) return;
    _followedFilm = opened.id;
    setState(() {
      _target = const AppTarget(AppView.nowPlaying);
      _trail.clear();
    });
  }

  /// One item, found wherever it shelves — collections point across
  /// libraries, so their entries resolve against everything loaded.
  MediaItem? _itemById(int id) {
    for (final items in _itemsByLibrary.values) {
      for (final item in items) {
        if (item.id == id) return item;
      }
    }
    return null;
  }

  Future<void> _reloadLibraries() async {
    final libraries = inSidebarOrder(
      await boot.client.listLibraries(),
      boot.settings.libraryOrder,
      (row) => row.id,
    );
    final items = {
      for (final row in libraries) row.id: await boot.client.mediaItems(row.id),
    };
    final audio = {
      for (final row in libraries)
        if (row.type == LibraryType.music)
          row.id: await boot.client.audioItems(row.id),
    };
    if (!mounted) return;
    setState(() {
      _libraries = libraries;
      _itemsByLibrary = items;
      _audioByLibrary = audio;
      // An inspected item that left with its shelf takes its page along.
      if (_inspected case final held? when _itemById(held.id) == null) {
        _inspected = null;
        _infoTab = false;
      }
    });
  }

  Future<void> _reloadCollections() async {
    final collections = inSidebarOrder(
      await boot.client.listCollections(),
      boot.settings.collectionOrder,
      (row) => row.id,
    );
    final entries = {
      for (final collection in collections)
        collection.id: await boot.client.collectionEntries(collection.id),
    };
    if (!mounted) return;
    setState(() {
      _collections = collections;
      _collectionEntries = entries;
    });
  }

  Future<void> _createLibrary() async {
    final draft = await showDialog<(String, LibraryType, List<String>)>(
      context,
      builder: (context) => _CreateLibraryDialog(
        startIn: _browseStart,
        pickDirectory: AppShell.pickDirectoryOverride,
      ),
    );
    if (draft == null) return;
    final (name, type, roots) = draft;
    final id = await boot.client.createLibrary(name, type);
    for (final root in roots) {
      try {
        await boot.client.addRoot(id, root);
      } on StateError {
        // A duplicate or a vanished path — the Folders… dialog can sort
        // it out later; creation itself carries on.
      }
    }
    await _reloadLibraries();
    setState(() => _target = LibraryTarget(id, type.views.first));
  }

  Future<void> _createCollection() async {
    final name = await showDialog<String>(
      context,
      builder: (context) => const _CreateCollectionDialog(),
    );
    if (name == null) return;
    final id = await boot.client.createCollection(name);
    await _reloadCollections();
    setState(() => _target = CollectionTarget(id));
  }

  /// The Libraries section's own verbs, behind the heading's three dots:
  /// making one, and unlocking the run for dragging. The rest are drawn
  /// but not wired.
  List<MenuEntry> _librariesMenu() {
    final icons = ThemeProvider.of(context).icons;
    return [
      MenuItem(
        label: const Text('New Library…'),
        leading: Icon(icons.add, size: 14),
        onPressed: _createLibrary,
      ),
      const MenuSeparator(),
      _rearrangeItem(
        'Rearrange Libraries',
        unlocked: _rearrangeLibraries,
        onPressed: () =>
            setState(() => _rearrangeLibraries = !_rearrangeLibraries),
      ),
      const MenuSeparator(),
      _notYet('Sort Libraries…', icons.sort),
      _notYet('Import Library…', LucideIcons.folderInput),
      MenuItem(
        label: const Text('Scan All Libraries'),
        leading: Icon(icons.refresh, size: 14),
        onPressed: _scanAllLibraries,
      ),
      _notYet('Show Item Counts', LucideIcons.hash),
    ];
  }

  /// The same shape for collections, with the verbs a run of playlists
  /// wants rather than a run of shelves.
  List<MenuEntry> _collectionsMenu() {
    final icons = ThemeProvider.of(context).icons;
    return [
      MenuItem(
        label: const Text('New Collection…'),
        leading: Icon(icons.add, size: 14),
        onPressed: _createCollection,
      ),
      const MenuSeparator(),
      _rearrangeItem(
        'Rearrange Collections',
        unlocked: _rearrangeCollections,
        onPressed: () =>
            setState(() => _rearrangeCollections = !_rearrangeCollections),
      ),
      const MenuSeparator(),
      _notYet('New Smart Collection…', LucideIcons.wandSparkles),
      _notYet('Import Playlist…', LucideIcons.fileInput),
      _notYet('Export All…', LucideIcons.fileOutput),
      _notYet('Show Item Counts', LucideIcons.hash),
    ];
  }

  /// The lock. The padlock reads as the state the section is *in*, the
  /// tick as the mode being on — a menu row that is both a verb and a
  /// switch needs to say so twice.
  MenuItem _rearrangeItem(
    String label, {
    required bool unlocked,
    required VoidCallback onPressed,
  }) => MenuItem(
    label: Text(label),
    leading: Icon(unlocked ? LucideIcons.lockOpen : LucideIcons.lock, size: 14),
    trailing: unlocked
        ? Icon(ThemeProvider.of(context).icons.confirm, size: 14)
        : null,
    onPressed: onPressed,
  );

  /// A control that is drawn but not wired: it wears the badge, and says
  /// as much rather than doing nothing at all. [label] keeps the ellipsis
  /// the real verb would earn; the toast drops it, nothing being opened.
  MenuItem _notYet(String label, IconData icon) {
    final name = label.replaceAll('…', '');
    return MenuItem(
      label: Text(label),
      leading: Icon(icon, size: 14),
      trailing: const _NotYetBadge(),
      onPressed: () => showToast(
        context,
        icon: LucideIcons.ban,
        message: Text('$name is not yet implemented.'),
      ),
    );
  }

  /// A drag landed. The list moves first so the row lands where it was
  /// dropped, then the new run of ids is what the sidebar remembers.
  void _reorderLibraries(int from, int to) {
    setState(() => _libraries.insert(to, _libraries.removeAt(from)));
    boot.settings.libraryOrder = [for (final row in _libraries) row.id];
  }

  void _reorderCollections(int from, int to) {
    setState(() => _collections.insert(to, _collections.removeAt(from)));
    boot.settings.collectionOrder = [for (final row in _collections) row.id];
  }

  /// A library with one view is one row; with more, a collapsible section
  /// with its views beneath it. Either way the label answers a right
  /// click with the library's own menu.
  List<NavEntry> _libraryEntries(LibraryRow library) {
    final views = library.type.views;
    final label = ContextMenu(
      entries: _libraryMenu(library),
      child: Text(library.name),
    );
    if (views.length == 1) {
      return [
        NavDestination<NavTarget>(
          value: LibraryTarget(library.id, views.single),
          label: label,
          icon: library.type.icon,
        ),
      ];
    }
    return [
      NavGroup<NavTarget>(
        label: label,
        icon: library.type.icon,
        destinations: [
          for (final view in views)
            NavDestination(
              value: LibraryTarget(library.id, view),
              label: Text(view.label),
              icon: view.icon,
            ),
        ],
      ),
    ];
  }

  /// The library's own verbs — contextual: the deck's home library can
  /// deal its whole shelf into the queue, and any library may be deleted;
  /// when the home goes, the deck moves house to the next audio shelf.
  List<MenuEntry> _libraryMenu(LibraryRow library) => [
    if (library.type == LibraryType.music && library.id == _homeId)
      MenuItem(
        label: const Text('Shuffle All'),
        leading: const Icon(LucideIcons.shuffle, size: 14),
        onPressed: () {
          boot.player.shuffleAll();
          showToast(
            context,
            icon: LucideIcons.shuffle,
            message: Text(
              'Shuffled ${boot.player.queue.length} songs into the queue',
            ),
          );
        },
      ),
    MenuItem(
      label: const Text('Rename'),
      leading: Icon(ThemeProvider.of(context).icons.edit, size: 14),
      onPressed: () => _renameLibrary(library),
    ),
    MenuItem(
      label: const Text('Folders…'),
      leading: const Icon(LucideIcons.folders, size: 14),
      onPressed: () => _editFolders(library),
    ),
    MenuItem(
      label: const Text('Scan'),
      leading: const Icon(LucideIcons.folderSearch, size: 14),
      onPressed: () => _scanLibrary(library),
    ),
    const MenuSeparator(),
    MenuItem(
      label: const Text('Delete'),
      leading: Icon(ThemeProvider.of(context).icons.delete, size: 14),
      swatch: SemanticSwatch.error,
      onPressed: () => _deleteLibrary(library),
    ),
  ];

  Future<void> _renameLibrary(LibraryRow library) async {
    final name = await showDialog<String>(
      context,
      builder: (context) => _RenameDialog(initial: library.name),
    );
    if (name == null || name == library.name) return;
    await boot.client.renameLibrary(library.id, name);
    await _reloadLibraries();
  }

  /// Where the folders dialog's add row starts: the portable root when
  /// there is one — the media usually lives beside the `.cadence` drawer —
  /// else home.
  /// Where the native folder browser opens its first look.
  String get _browseStart =>
      boot.environment.defaultPickerDirectory?.path ??
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '';

  Future<void> _editFolders(LibraryRow library) => showDialog<void>(
    context,
    builder: (context) => _FoldersDialog(
      client: boot.client,
      library: library,
      startIn: _browseStart,
      pickDirectory: AppShell.pickDirectoryOverride,
      revealDirectory: AppShell.revealDirectoryOverride,
    ),
  );

  Future<void> _scanLibrary(LibraryRow library) async {
    try {
      final outcome = await boot.client.scan(library.id);
      if (!mounted) return;
      if (!outcome.accepted) {
        showToast(
          context,
          icon: LucideIcons.folderSearch,
          swatch: SemanticSwatch.info,
          message: Text(outcome.message),
        );
        return;
      }
      final status = await _followScan(library.id, library.name);
      if (status == null || !mounted) return;
      await _reloadLibraries();
      _artwork.invalidate();
      if (mounted) _reportScan(library.name, status);
    } on Object {
      _reportScanLost(library.name);
    }
  }

  /// Queues every library on the host — one job each, in sidebar order;
  /// the host drains them one at a time — then follows the drain from
  /// here: each library in turn behind its own live toast, the shelves
  /// reloading as they finish, one tally at the end. A library the host
  /// refuses (a scan of it already queued) is left to that scan.
  Future<void> _scanAllLibraries() async {
    final anchor = DateTime.now();
    var following = 'your libraries';
    try {
      final queued = <int>[];
      for (final row in await boot.client.listLibraries()) {
        if ((await boot.client.scan(row.id)).accepted) queued.add(row.id);
      }
      if (!mounted || queued.isEmpty) return;
      // Named off a fresh roster, not the sidebar's copy — a shelf the
      // sidebar hasn't met yet still deserves its own name in the toast.
      final names = {
        for (final row in await boot.client.listLibraries()) row.id: row.name,
      };
      var scanned = 0;
      var added = 0;
      var updated = 0;
      for (final (index, libraryId) in queued.indexed) {
        final name = following = names[libraryId] ?? 'a library';
        final status = await _followScan(
          libraryId,
          queued.length == 1
              ? name
              : '$name (${index + 1} of ${queued.length})',
          after: anchor,
          laterIds: queued.sublist(index + 1),
        );
        if (!mounted) return;
        if (status == null) continue;
        scanned++;
        added += status.added;
        updated += status.updated;
        await _reloadLibraries();
        _artwork.invalidate();
        if (!mounted) return;
        // A clean finish waits for the shared tally; anything else speaks
        // now.
        if (status.state == ScanState.done) {
          _reportScanErrors(name, status);
        } else {
          _reportScan(name, status);
        }
      }
      if (!mounted) return;
      showToast(
        context,
        swatch: SemanticSwatch.success,
        message: Text(
          'Scanned $scanned ${scanned == 1 ? 'library' : 'libraries'}: '
          '$added added, $updated updated.',
        ),
      );
    } on Object {
      _reportScanLost(following);
    }
  }

  /// Polls one library's scan to its end, narrating through a single live
  /// toast. With [after], only a scan started since then counts — scan-all
  /// leaves the previous outcome on the board until its drain reaches each
  /// library — and null comes back when the drain moved past this one
  /// instead: deleted mid-queue, settled while we blinked and [laterIds]
  /// already show the drain further along, or skipped outright because
  /// another scan held the library when the drain came by.
  Future<ScanStatus?> _followScan(
    int libraryId,
    String label, {
    DateTime? after,
    List<int> laterIds = const [],
  }) async {
    var sawRunning = false;
    var stalePolls = 0;
    _following++;
    final message = ValueNotifier('Scanning $label…');
    final dismiss = showToast(
      context,
      icon: LucideIcons.folderSearch,
      duration: const Duration(hours: 1),
      message: ValueListenableBuilder(
        valueListenable: message,
        builder: (context, text, _) => Text(text),
      ),
    );
    try {
      while (mounted) {
        await Future<void>.delayed(AppShell.scanPollInterval);
        if (!mounted) return null;
        final status = await boot.client.scanStatus(libraryId);
        if (status.running) sawRunning = true;
        final startedAt = status.startedAt;
        final ours =
            after == null ||
            sawRunning ||
            (startedAt != null && !startedAt.isBefore(after));
        if (!ours) {
          if (await _drainPassed(libraryId, after, laterIds)) return null;
          // By the time this library is being followed the drain has
          // already reached it; a stale outcome that outlasts a second
          // look means the drain skipped it — another scan held the
          // library as the drain came by — and nothing of ours is coming.
          if (++stalePolls >= 2) return null;
          continue;
        }
        if (!status.running) return status;
        message.value =
            'Scanning $label… ${status.seen} seen, ${status.added} added';
      }
      return null;
    } finally {
      _following--;
      // The toaster goes down with the shell; only reach for it standing.
      if (mounted) dismiss();
    }
  }

  /// Whether scan-all's drain has moved past a library without leaving a
  /// scan to follow: the library is gone, or a later one already shows
  /// this run's activity.
  Future<bool> _drainPassed(
    int libraryId,
    DateTime after,
    List<int> laterIds,
  ) async {
    final rows = await boot.client.listLibraries();
    if (!rows.any((row) => row.id == libraryId)) return true;
    for (final id in laterIds) {
      final status = await boot.client.scanStatus(id);
      final startedAt = status.startedAt;
      if (status.running || (startedAt != null && !startedAt.isBefore(after))) {
        return true;
      }
    }
    return false;
  }

  /// The end of a scan, told where the toasts go: the tally for a finish,
  /// the state for anything else, the failures either way.
  void _reportScan(String name, ScanStatus status) {
    switch (status.state) {
      case ScanState.done:
        showToast(
          context,
          swatch: SemanticSwatch.success,
          message: Text('Scanned $name: ${_tally(status)}.'),
        );
      case ScanState.cancelled:
        showToast(
          context,
          swatch: SemanticSwatch.info,
          message: Text('Scan of $name cancelled.'),
        );
      case ScanState.failed:
        showToast(
          context,
          swatch: SemanticSwatch.error,
          message: Text('Scan of $name failed.'),
        );
      case ScanState.idle:
      case ScanState.queued:
      case ScanState.interrupted:
      case ScanState.walking:
      case ScanState.discovering:
      case ScanState.extracting:
      case ScanState.finishing:
        break;
    }
    _reportScanErrors(name, status);
  }

  /// The line went dead mid-follow — the service stopped answering. The
  /// scan's own fate is unknowable from here; say what happened and stand
  /// down rather than throwing out of a fire-and-forget future.
  void _reportScanLost(String name) {
    if (!mounted) return;
    showToast(
      context,
      swatch: SemanticSwatch.error,
      message: Text(
        'Lost sight of the scan of $name — the service stopped answering.',
      ),
    );
  }

  /// Failures get their own red toast: how many, and the first by name.
  void _reportScanErrors(String name, ScanStatus status) {
    if (status.errorCount == 0) return;
    final count = status.errorCount == 1
        ? '1 error'
        : '${status.errorCount} errors';
    final detail = switch (status.errors.firstOrNull) {
      null => '',
      ScanError(:final path, :final message) when path.isEmpty => ' — $message',
      ScanError(:final path, :final message) =>
        ' — ${p.basename(path)}: $message',
    };
    showToast(
      context,
      swatch: SemanticSwatch.error,
      message: Text('$count scanning $name$detail'),
    );
  }

  String _tally(ScanStatus status) => [
    '${status.added} added',
    '${status.updated} updated',
    if (status.moved > 0) '${status.moved} moved',
    if (status.missing > 0) '${status.missing} missing',
  ].join(', ');

  Future<void> _deleteLibrary(LibraryRow library) async {
    final sure = await showDialog<bool>(
      context,
      builder: (context) => AppDialog(
        icon: ThemeProvider.of(context).icons.delete,
        swatch: SemanticSwatch.error,
        title: Text('Delete ${library.name}?'),
        content: const BodyText(
          'The library and its items are removed. Files on disk are left '
          'alone.',
        ),
        actions: [
          Button(
            onPressed: () => Navigator.of(context).pop(true),
            swatch: SemanticSwatch.error,
            center: const Text('Delete'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    await boot.client.deleteLibrary(library.id);
    await _reloadLibraries();
    _trail.removeWhere((detail) => detail.libraryId == library.id);
    if (library.id == _homeId) {
      // The deck moves house: the next audio shelf in sidebar order, or
      // nowhere.
      _homeId = _libraries
          .where((l) => l.type == LibraryType.music)
          .firstOrNull
          ?.id;
      boot.player.adopt(_audioByLibrary[_homeId] ?? const []);
    }
    // Collections stand apart from libraries, but the deleted shelf's
    // entries cascaded away with its items — re-read what remains.
    await _reloadCollections();
    final dangling = switch (_target) {
      LibraryTarget(:final libraryId) => libraryId == library.id,
      AppTarget() || SearchTrigger() || CollectionTarget() => false,
    };
    if (dangling && mounted) {
      setState(
        () => _target = _homeId == null
            ? const AppTarget(AppView.nowPlaying)
            : LibraryTarget(_homeId!, LibraryViewKind.music),
      );
    }
  }

  Widget _libraryBody(LibraryTarget target) {
    final items = _itemsByLibrary[target.libraryId] ?? const <MediaItem>[];
    final songs = _audioByLibrary[target.libraryId] ?? const <AudioItem>[];
    ViewPrefs prefsOf(LibraryViewKind kind) =>
        _viewPrefs.of(target.libraryId, kind);
    void save(LibraryViewKind kind, ViewPrefs value) =>
        _viewPrefs.update(target.libraryId, kind, value);
    return switch (target.view) {
      LibraryViewKind.music ||
      LibraryViewKind.songs ||
      LibraryViewKind.albums ||
      LibraryViewKind.artists => MusicView(
        player: boot.player,
        items: songs,
        client: boot.client,
        prefs: _viewPrefs,
        libraryId: target.libraryId,
        onOpenAlbum: (album) =>
            _openDetail(AlbumDetail(target.libraryId, album)),
        onOpenArtist: (artist) =>
            _openDetail(ArtistDetail(target.libraryId, artist)),
      ),
      LibraryViewKind.episodes => ShowsView(
        player: boot.player,
        items: items,
        prefs: prefsOf(LibraryViewKind.episodes),
        onPrefs: (value) => save(LibraryViewKind.episodes, value),
        onOpenSeries: (series) =>
            _openDetail(SeriesDetail(target.libraryId, series)),
      ),
      LibraryViewKind.movies => VideosView(
        player: boot.player,
        items: items,
        prefs: prefsOf(LibraryViewKind.movies),
        onPrefs: (value) => save(LibraryViewKind.movies, value),
      ),
      LibraryViewKind.books => BooksView(
        player: boot.player,
        items: items,
        prefs: prefsOf(LibraryViewKind.books),
        onPrefs: (value) => save(LibraryViewKind.books, value),
      ),
      LibraryViewKind.comics => ComicsView(
        player: boot.player,
        items: items,
        prefs: prefsOf(LibraryViewKind.comics),
        onPrefs: (value) => save(LibraryViewKind.comics, value),
        onOpenSeries: (series) =>
            _openDetail(SeriesDetail(target.libraryId, series)),
      ),
      LibraryViewKind.gallery => GalleryView(
        player: boot.player,
        items: items,
        prefs: prefsOf(LibraryViewKind.gallery),
        onPrefs: (value) => save(LibraryViewKind.gallery, value),
      ),
    };
  }

  /// The "Add to collection" flow a detail page opens: every collection
  /// as a list of doors, a way to found a new one, and the chosen items
  /// appended once each. Collections take any kind — songs into a
  /// playlist, issues into a reading order, films into a watch order.
  Future<void> _addToCollection(List<int> itemIds) async {
    final collections = await boot.client.listCollections();
    if (!mounted) return;
    final chosen = await showDialog<Object>(
      context,
      builder: (context) => AppDialog(
        icon: LucideIcons.list,
        title: const Text('Add to collection'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (collections.isEmpty)
              const CaptionText(
                'No collections yet — found one below.',
                emphasis: TextEmphasis.secondary,
              )
            else
              for (final collection in collections)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Button(
                    onPressed: () => Navigator.of(context).pop(collection),
                    variant: SurfaceVariant.ghost,
                    swatch: SemanticSwatch.neutral,
                    center: Row(
                      children: [
                        const Icon(LucideIcons.list, size: 14),
                        Spacing(SpaceStep.x2, axis: Axis.horizontal),
                        Expanded(
                          child: Text(
                            collection.name,
                            textAlign: TextAlign.left,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            Spacing(SpaceStep.x3),
            const Divider(),
            Spacing(SpaceStep.x3),
            Row(
              children: [
                Button(
                  onPressed: () => Navigator.of(context).pop(#create),
                  variant: SurfaceVariant.ghost,
                  swatch: SemanticSwatch.neutral,
                  center: const Text('New Collection…'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (!mounted || chosen == null) return;

    CollectionRow? into;
    if (chosen == #create) {
      final name = await showDialog<String>(
        context,
        builder: (context) => const _CreateCollectionDialog(),
      );
      if (name == null || !mounted) return;
      final id = await boot.client.createCollection(name);
      into = CollectionRow(id: id, name: name, createdAt: DateTime.now());
    } else if (chosen is CollectionRow) {
      into = chosen;
    }
    if (into == null) return;

    final existing = await boot.client.collectionEntries(into.id);
    final added = [
      for (final id in itemIds)
        if (!existing.contains(id)) id,
    ];
    if (added.isNotEmpty) {
      await boot.client.setCollectionEntries(into.id, [...existing, ...added]);
    }
    await _reloadCollections();
    if (!mounted) return;
    showToast(
      context,
      icon: LucideIcons.list,
      message: Text(
        added.isEmpty
            ? 'Already all in ${into.name}.'
            : 'Added ${added.length} '
                  '${added.length == 1 ? 'item' : 'items'} to ${into.name}.',
      ),
    );
  }

  void _openDetail(DetailTarget detail) => setState(() => _trail.add(detail));

  void _popDetail() => setState(() => _trail.removeLast());

  Widget _detailBody(DetailTarget detail) {
    final songs = _audioByLibrary[detail.libraryId] ?? const <AudioItem>[];
    final items = _itemsByLibrary[detail.libraryId] ?? const <MediaItem>[];
    return switch (detail) {
      AlbumDetail(:final album) => AlbumDetailView(
        player: boot.player,
        album: album,
        tracks: [
          for (final t in songs)
            if ((t.metadata.album ?? 'Unknown') == album) t,
        ],
        onBack: _popDetail,
        onOpenArtist: (artist) =>
            _openDetail(ArtistDetail(detail.libraryId, artist)),
        onAddToCollection: (items) =>
            _addToCollection([for (final item in items) item.id]),
      ),
      ArtistDetail(:final artist) => ArtistDetailView(
        player: boot.player,
        artist: artist,
        tracks: [
          for (final t in songs)
            if ((t.metadata.artist ?? 'Unknown') == artist ||
                t.metadata.albumArtist == artist)
              t,
        ],
        onBack: _popDetail,
        onOpenAlbum: (album) =>
            _openDetail(AlbumDetail(detail.libraryId, album)),
        onAddToCollection: (items) =>
            _addToCollection([for (final item in items) item.id]),
      ),
      SeriesDetail(:final series) => SeriesDetailView(
        player: boot.player,
        series: series,
        items: [
          for (final item in items)
            if (_seriesNameOf(item) == series) item,
        ],
        libraryType:
            _libraries
                .where((l) => l.id == detail.libraryId)
                .firstOrNull
                ?.type ??
            LibraryType.shows,
        onBack: _popDetail,
      ),
    };
  }

  /// The name a run goes by — mirrored from the shows and comics views so
  /// a series page gathers exactly the items its tile stood for.
  static String _seriesNameOf(MediaItem item) => switch (item.metadata) {
    VideoMetadata(:final series?) => series,
    VideoMetadata(:final title) => title,
    AudioMetadata(:final album?) => album,
    AudioMetadata(:final title) => title,
    DocumentMetadata(:final series?) => series,
    _ => 'Unknown',
  };

  /// The body is a navigator of its own: the library view as the base
  /// page, the drill-in trail as routes above it — real routes, so the
  /// art and the names fly between them as heroes.
  Widget get _body => Navigator(
    observers: [HeroController()],
    onDidRemovePage: (page) {
      // The trail is the source of truth; the back button edits it and
      // this echo keeps them agreeing when the framework lets a page go.
      if (page.key case final ValueKey<Object?> key) {
        _trail.remove(key.value);
      }
    },
    pages: [
      // The target is captured per page, not read live: the outgoing
      // route keeps rebuilding through its exit, and a late-bound getter
      // would have it repaint as a second copy of the incoming page.
      _BodyPage(key: ValueKey(_target), builder: _rootBody(_target)),
      for (final detail in List.of(_trail))
        _BodyPage(
          key: ValueKey(detail),
          builder: (context) => _detailBody(detail),
        ),
    ],
  );

  WidgetBuilder _rootBody(NavTarget target) =>
      (context) => switch (target) {
        // Never a resting place — the palette opens instead of navigating.
        SearchTrigger() => const SizedBox.shrink(),
        final LibraryTarget target => _libraryBody(target),
        AppTarget(view: AppView.nowPlaying) => NowPlayingView(
          player: boot.player,
          settings: boot.settings,
        ),
        AppTarget(view: AppView.settings) => SettingsView(
          settings: boot.settings,
          hosting: boot.hosting,
        ),
        CollectionTarget(:final collectionId) => CollectionView(
          player: boot.player,
          collection: _collections.firstWhere((c) => c.id == collectionId),
          // Entries resolve across every library; one that outran a reload
          // (its item just deleted) is quietly left out.
          items: [
            for (final id in _collectionEntries[collectionId] ?? const <int>[])
              ?_itemById(id),
          ],
        ),
      };

  void _openSearchPalette() => showDialog<void>(
    context,
    builder: (context) => const _SearchPaletteDialog(),
  );

  NavList<NavTarget> _nav(List<NavEntry> entries) => NavList<NavTarget>(
    value: _target,
    onChanged: (target) {
      if (target is SearchTrigger) {
        _openSearchPalette();
        return;
      }
      setState(() {
        _trail.clear();
        _target = target;
      });
    },
    entries: entries,
  );

  /// One section's rows. Locked, they are a single [NavList] and so a
  /// single keyboard walk; unlocked, each row becomes a block that drags,
  /// which wants a reorderable list — and that is why the sidebar's
  /// middle is slivers rather than a column in a scroll view.
  Widget _rows<T>({
    required bool rearranging,
    required List<T> rows,
    required int Function(T row) idOf,
    required List<NavEntry> Function(T row) entriesOf,
    required ReorderCallback onReorder,
  }) {
    if (!rearranging) {
      return SliverToBoxAdapter(
        child: _nav([for (final row in rows) ...entriesOf(row)]),
      );
    }
    return SliverReorderableList(
      itemCount: rows.length,
      onReorderItem: onReorder,
      // The flying block gets a solid coat, or it would drag its words
      // bare over the rows beneath.
      proxyDecorator: (child, index, animation) => RowSurface(
        swatch: SemanticSwatch.neutral,
        variant: SurfaceVariant.soft,
        child: child,
      ),
      itemBuilder: (context, index) => _DragBlock(
        key: ValueKey(idOf(rows[index])),
        index: index,
        child: _nav(entriesOf(rows[index])),
      ),
    );
  }

  /// The sections themselves, scrolling: each heading and the rows
  /// beneath it, as slivers so that an unlocked section can be a
  /// reorderable list of its own.
  Widget get _sections {
    final space = ThemeProvider.of(context).space;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.symmetric(
            horizontal: space.x2,
            vertical: space.x1,
          ),
          sliver: SliverMainAxisGroup(
            slivers: [
              SliverToBoxAdapter(
                child: _SectionHeader('Libraries', entries: _librariesMenu()),
              ),
              _rows(
                rearranging: _rearrangeLibraries,
                rows: _libraries,
                idOf: (library) => library.id,
                entriesOf: _libraryEntries,
                onReorder: _reorderLibraries,
              ),
              SliverToBoxAdapter(
                child: _SectionHeader(
                  'Collections',
                  entries: _collectionsMenu(),
                ),
              ),
              _rows(
                rearranging: _rearrangeCollections,
                rows: _collections,
                idOf: (collection) => collection.id,
                entriesOf: (collection) => [
                  NavDestination(
                    value: CollectionTarget(collection.id),
                    label: Text(collection.name),
                    icon: LucideIcons.list,
                  ),
                ],
                onReorder: _reorderCollections,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Now Playing pinned above, Settings pinned below, everything that can
  /// grow scrolling between them.
  Widget get _sidebar => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Inset.symmetric(
        horizontal: SpaceStep.x2,
        vertical: SpaceStep.x2,
        child: _nav(const [
          NavDestination(
            value: AppTarget(AppView.nowPlaying),
            label: Text('Now Playing'),
            icon: LucideIcons.audioLines,
          ),
          NavDestination(
            value: SearchTrigger(),
            label: Text('Search'),
            icon: LucideIcons.search,
          ),
          NavDestination(
            value: AppTarget(AppView.settings),
            label: Text('Settings'),
            icon: LucideIcons.settings,
          ),
        ]),
      ),
      const Divider(),
      Expanded(child: _sections),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    // Where you are is remembered for next launch — silently, and only
    // when it actually moved.
    if (_target != _persistedTarget && _target is! SearchTrigger) {
      _persistedTarget = _target;
      boot.settings.lastView = _encodeTarget(_target);
    }
    // Fullscreen: the picture and the deck, nothing else. Escape or the
    // bar's own button hands the window back.
    if (boot.player.fullscreen) {
      return ArtworkScope(
        cache: _artwork,
        child: Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape) {
              boot.player.toggleFullscreen();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Column(
            children: [
              Expanded(
                child: GestureDetector(
                  onDoubleTap: boot.player.toggleFullscreen,
                  child: SizedBox.expand(
                    child: DeckVideoSurface(player: boot.player),
                  ),
                ),
              ),
              TransportBar(player: boot.player),
            ],
          ),
        ),
      );
    }
    return ArtworkScope(
      cache: _artwork,
      // Above the scaffold, not just the body: the transport bar's
      // now-playing well reads the panel's tab through this too.
      child: ShelfActions(
        player: boot.player,
        inspect: (item) => setState(() {
          _inspected = item;
          _infoTab = true;
        }),
        inspected: _inspected,
        queueTab: !_infoTab,
        revealQueue: () => setState(() => _infoTab = false),
        child: Scaffold(
          toolbars: [
            TitleBar(
              // The name leads, standing a size above the bar's stock label;
              // the sidebar toggle follows it. The extra step of leading
              // padding sets the name's edge on the sidebar icons' line.
              leading: [
                Padding(
                  padding: EdgeInsetsDirectional.only(start: theme.space.x2),
                  child: Text('Cadence', style: theme.typography.title),
                ),
                const ScaffoldSidebarToggle(ScaffoldSide.leading),
              ],
              // The trailing panel is Info and Queue both now, so its
              // toggle wears the leading icon's mirror twin (the theme's
              // own trailing glyph) rather than a music note.
              actions: const [
                ScaffoldSidebarToggle(
                  ScaffoldSide.trailing,
                  showLabel: 'Show panel',
                  hideLabel: 'Hide panel',
                ),
              ],
            ),
          ],
          leading: SizedBox(width: 220, child: _sidebar),
          body: Stack(
            children: [
              ListenableBuilder(
                listenable: _viewPrefs,
                builder: (context, _) => _body,
              ),
              // The pip window: the running film, folded into the corner
              // of every view but its own stage.
              Positioned(
                right: theme.space.x4,
                bottom: theme.space.x4,
                child: ListenableBuilder(
                  listenable: boot.player,
                  builder: (context, _) {
                    final opened = boot.player.opened;
                    final showing =
                        opened?.metadata is VideoMetadata &&
                        _target != const AppTarget(AppView.nowPlaying);
                    if (!showing) return const SizedBox.shrink();
                    return PipWindow(
                      player: boot.player,
                      onTap: () => setState(
                        () => _target = const AppTarget(AppView.nowPlaying),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          trailing: SizedBox(
            width: 260,
            child: TrailingPanel(
              player: boot.player,
              inspected: _inspected,
              infoTab: _infoTab,
              onTab: (info) => setState(() => _infoTab = info),
              onCloseInspector: () => setState(() {
                _inspected = null;
                _infoTab = false;
              }),
              onAddToCollection: () {
                if (_inspected case final item?) _addToCollection([item.id]);
              },
            ),
          ),
          initialTrailingOpen: false,
          statusbars: [TransportBar(player: boot.player)],
        ),
      ),
    );
  }
}

/// A section heading with its overflow menu: the label in the nav's
/// heading voice, the three dots sharing the trailing edge with the rows
/// beneath it.
class _SectionHeader extends StatefulWidget {
  const _SectionHeader(this.label, {required this.entries});

  final String label;

  /// What the dots open. Rebuilt by the shell each frame, so a toggle
  /// inside shows its new state the next time the menu is asked for.
  final List<MenuEntry> entries;

  @override
  State<_SectionHeader> createState() => _SectionHeaderState();
}

class _SectionHeaderState extends State<_SectionHeader> {
  bool _open = false;

  /// The button's square side — bigger than the glyph for a hit target.
  static const _buttonSide = 24.0;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final navStyle = theme.widgets.navList.resolve();
    final row = navStyle.padding.resolve(TextDirection.ltr);
    final heading = navStyle.headingPadding.resolve(TextDirection.ltr);
    // The rows' trailing glyphs (a group's chevron) centre at
    // rowPad + iconSize/2 from the edge; the dots must land on the same
    // line, so its end inset backs the button's centre onto it.
    final end = math.max(
      0.0,
      row.right + navStyle.iconSize / 2 - _buttonSide / 2,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        heading.left,
        heading.top,
        end,
        heading.bottom,
      ),
      child: Row(
        children: [
          Text(widget.label, style: navStyle.headingStyle),
          const Spacer(),
          Menu(
            open: _open,
            onDismiss: () => setState(() => _open = false),
            entries: widget.entries,
            // Hung off the trailing edge: the sidebar is narrow, and a
            // menu starting at the dots would hang off the window.
            align: PopoverAlign.end,
            anchor: Semantics(
              label: '${widget.label} options',
              child: Tooltip(
                message: Text('${widget.label} options'),
                child: Button.custom(
                  onPressed: () => setState(() => _open = !_open),
                  style: theme.widgets.button
                      .resolve(SemanticSwatch.neutral, SurfaceVariant.ghost)
                      .copyWith(height: _buttonSide, padding: EdgeInsets.zero),
                  child: SizedBox.square(
                    dimension: _buttonSide,
                    child: Center(
                      child: Icon(
                        theme.icons.moreVertical,
                        size: navStyle.iconSize,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One library or collection while its section is unlocked: the grip, and
/// then the rows the section would show anyway.
///
/// The grip drags straight away; the whole block drags after a hold, the
/// way the queue's rows do, so a library that has unfolded into several
/// view rows can still be picked up anywhere along it.
class _DragBlock extends StatelessWidget {
  const _DragBlock({required this.index, required this.child, super.key});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final navStyle = theme.widgets.navList.resolve();
    return ReorderableDelayedDragStartListener(
      index: index,
      child: Row(
        // Against the block's own row, not the middle of a group that has
        // unfolded beneath it.
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ReorderableDragStartListener(
            index: index,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: SizedBox(
                width: navStyle.indent,
                height: navStyle.rowHeight,
                child: Icon(
                  theme.icons.drag,
                  size: navStyle.iconSize,
                  color: theme.palette.text.withValues(
                    alpha: theme.opacities.tertiary,
                  ),
                ),
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// The mark on a control that is drawn but not wired: a small red badge
/// carrying a slashed circle.
class _NotYetBadge extends StatelessWidget {
  const _NotYetBadge();

  @override
  Widget build(BuildContext context) {
    final style = ThemeProvider.of(
      context,
    ).widgets.badge.resolve(SemanticSwatch.error);
    return Semantics(
      label: 'Not yet implemented',
      container: true,
      // The glyph says it in red; the label says it in words, and the
      // badge's own node underneath has nothing to add.
      excludeSemantics: true,
      child: Badge.label(
        // A badge dresses words, not glyphs, so the colour its own
        // surface picked has to be handed to the icon.
        Icon(LucideIcons.ban, size: 10, color: style.textStyle.color),
        style: style,
      ),
    );
  }
}

/// The ground a library stands on: its claimed directories, each with the
/// way to release it, and a row for claiming another. Changes land as they
/// are made — the next scan is what acts on them.
class _FoldersDialog extends StatefulWidget {
  const _FoldersDialog({
    required this.client,
    required this.library,
    required this.startIn,
    this.pickDirectory,
    this.revealDirectory,
  });

  final MediaClient client;
  final LibraryRow library;

  /// Where the folder browser opens its first look.
  final String startIn;

  /// The folder browser itself — the OS's own by default; tests hand in
  /// a tame one.
  final Future<String?> Function(String startIn)? pickDirectory;

  /// Shows a folder in the OS's file explorer — likewise overridable.
  final Future<void> Function(String path)? revealDirectory;

  @override
  State<_FoldersDialog> createState() => _FoldersDialogState();
}

Future<String?> _nativePickDirectory(String startIn) =>
    getDirectoryPath(initialDirectory: startIn.isEmpty ? null : startIn);

/// Hands a folder to the OS's file explorer. Best effort: a desktop
/// without an opener just shrugs.
Future<void> _systemRevealDirectory(String path) async {
  final (command, args) = switch (Platform.operatingSystem) {
    'macos' => ('open', [path]),
    'windows' => ('explorer', [path]),
    _ => ('xdg-open', [path]),
  };
  try {
    await Process.start(command, args, mode: ProcessStartMode.detached);
  } catch (_) {}
}

class _FoldersDialogState extends State<_FoldersDialog> {
  final _path = TextEditingController();
  List<LibraryRootRow>? _roots;
  String? _complaint;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final roots = await widget.client.listRoots(widget.library.id);
    if (mounted) setState(() => _roots = roots);
  }

  /// What is wrong with [path] as a root, or null when nothing is.
  String? _vet(String path) {
    if (!p.isAbsolute(path)) return 'An absolute path, please.';
    return switch (FileSystemEntity.typeSync(path)) {
      FileSystemEntityType.notFound => 'Nothing lives at that path.',
      FileSystemEntityType.directory => null,
      _ => 'That is a file, not a folder.',
    };
  }

  Future<void> _add() async {
    final path = p.normalize(_path.text.trim());
    final complaint = _vet(path);
    if (complaint != null) {
      setState(() => _complaint = complaint);
      return;
    }
    try {
      await widget.client.addRoot(widget.library.id, path);
    } on StateError {
      if (mounted) {
        setState(() => _complaint = "Already one of this library's folders.");
      }
      return;
    }
    if (!mounted) return;
    _path.clear();
    setState(() => _complaint = null);
    await _load();
  }

  Future<void> _remove(LibraryRootRow root) async {
    await widget.client.removeRoot(widget.library.id, root.id);
    await _load();
  }

  /// Opens the OS's folder browser; a pick is its own confirmation, so
  /// the chosen folder goes straight onto the shelf.
  Future<void> _browse() async {
    final picked = await (widget.pickDirectory ?? _nativePickDirectory)(
      widget.startIn,
    );
    if (picked == null || !mounted) return;
    _path.text = picked;
    await _add();
  }

  Widget _rootRow(LibraryRootRow root) {
    final theme = ThemeProvider.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: theme.space.x1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Semantics(
            label: 'Open ${root.path}',
            child: Tooltip(
              message: const Text('Show in the file manager'),
              child: Button(
                onPressed: () =>
                    (widget.revealDirectory ?? _systemRevealDirectory)(
                      root.path,
                    ),
                variant: SurfaceVariant.ghost,
                swatch: SemanticSwatch.neutral,
                center: const Icon(LucideIcons.folder, size: 18),
              ),
            ),
          ),
          Spacing(SpaceStep.x2, axis: Axis.horizontal),
          Expanded(
            child: BodyText(
              root.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Semantics(
            label: 'Remove ${root.path}',
            child: Tooltip(
              message: const Text('Remove folder — files stay put'),
              child: Button(
                onPressed: () => _remove(root),
                variant: SurfaceVariant.ghost,
                swatch: SemanticSwatch.error,
                center: Icon(theme.icons.delete, size: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final roots = _roots;
    return AppDialog(
      icon: LucideIcons.folders,
      title: Text('${widget.library.name} folders'),
      // Room to breathe: a beat between the rows, and the rule holding
      // the add row at arm's length.
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (roots == null)
            const CaptionText(
              'Asking after the folders…',
              emphasis: TextEmphasis.secondary,
            )
          else if (roots.isEmpty)
            const CaptionText(
              'No folders yet — the scanner has nowhere to look.',
              emphasis: TextEmphasis.secondary,
            )
          else
            for (final root in roots) _rootRow(root),
          Spacing(SpaceStep.x4),
          const Divider(),
          Spacing(SpaceStep.x4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Button(onPressed: _browse, center: const Text('Browse…')),
              Spacing(SpaceStep.x2, axis: Axis.horizontal),
              Expanded(
                child: TextField(
                  controller: _path,
                  autofocus: true,
                  placeholder: const Text('/absolute/path/to/folder'),
                  error: _complaint == null ? null : Text(_complaint!),
                  onSubmitted: (_) => _add(),
                ),
              ),
              Spacing(SpaceStep.x2, axis: Axis.horizontal),
              Button(onPressed: _add, center: const Text('Add')),
            ],
          ),
        ],
      ),
    );
  }
}

/// One page of the body's own navigator, its content resolved fresh on
/// every rebuild — the shelves underneath keep moving while a page is up.
class _BodyPage extends Page<void> {
  const _BodyPage({required this.builder, super.key});

  final WidgetBuilder builder;

  @override
  Route<void> createRoute(BuildContext context) => _BodyPageRoute(this);
}

/// A quiet route: a short fade with the faintest rise, and the heroes do
/// the real talking.
class _BodyPageRoute extends PageRoute<void> {
  _BodyPageRoute(_BodyPage page) : super(settings: page);

  /// Read through settings each time — the navigator swaps the page
  /// instance in place as the shell rebuilds.
  _BodyPage get _page => settings as _BodyPage;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  bool get opaque => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 160);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => ColoredBox(
    // The page carries its own ground: bodies are transparent over the
    // window's background, and fading one in bare shows the old page
    // through it until the route turns opaque — a pop, not a fade.
    color: ThemeProvider.of(context).palette.background,
    child: _page.builder(context),
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => FadeTransition(
    opacity: animation,
    child: SlideTransition(
      position: animation.drive(
        Tween(begin: const Offset(0, 0.015), end: Offset.zero),
      ),
      child: child,
    ),
  );
}

/// The search palette's door: the box lives here now, out of the page
/// body, waiting for the engine to move in behind it.
class _SearchPaletteDialog extends StatelessWidget {
  const _SearchPaletteDialog();

  @override
  Widget build(BuildContext context) {
    return const AppDialog(
      icon: LucideIcons.search,
      title: Text('Search'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(autofocus: true, placeholder: Text('Search everything…')),
          Spacing(SpaceStep.x3),
          CaptionText(
            'The palette is still moving in — the box is here, the '
            'answers are on their way.',
            emphasis: TextEmphasis.secondary,
          ),
        ],
      ),
    );
  }
}

/// One field, prefilled: the new name or nothing.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      icon: ThemeProvider.of(context).icons.edit,
      title: const Text('Rename'),
      content: TextField(
        controller: _name,
        autofocus: true,
        onSubmitted: (_) => _submit(),
      ),
      actions: [Button(onPressed: _submit, center: const Text('Rename'))],
    );
  }
}

/// Name it, choose what it holds, hand it its folders, done.
class _CreateLibraryDialog extends StatefulWidget {
  const _CreateLibraryDialog({required this.startIn, this.pickDirectory});

  /// Where the folder browser opens its first look.
  final String startIn;

  /// The folder browser itself — the OS's own by default; tests hand in
  /// a tame one.
  final Future<String?> Function(String startIn)? pickDirectory;

  @override
  State<_CreateLibraryDialog> createState() => _CreateLibraryDialogState();
}

class _CreateLibraryDialogState extends State<_CreateLibraryDialog> {
  final _name = TextEditingController();
  LibraryType _type = LibraryType.music;
  final _roots = <String>[];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop((name, _type, List<String>.of(_roots)));
  }

  Future<void> _browse() async {
    final picked = await (widget.pickDirectory ?? _nativePickDirectory)(
      widget.startIn,
    );
    if (picked == null || !mounted || _roots.contains(picked)) return;
    setState(() => _roots.add(picked));
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return AppDialog(
      icon: LucideIcons.libraryBig,
      title: const Text('New library'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            placeholder: const Text('Name'),
            onSubmitted: (_) => _submit(),
          ),
          Spacing(SpaceStep.x3),
          Select<LibraryType>(
            value: _type,
            onChanged: (type) => setState(() => _type = type),
            options: [
              for (final type in LibraryType.values)
                SelectOption(
                  value: type,
                  label: Text(type.label),
                  leading: Icon(type.icon, size: 14),
                ),
            ],
          ),
          Spacing(SpaceStep.x4),
          const Divider(),
          Spacing(SpaceStep.x3),
          if (_roots.isEmpty)
            const CaptionText(
              'No folders yet — pick some now, or later from Folders….',
              emphasis: TextEmphasis.secondary,
            )
          else
            for (final root in _roots)
              Padding(
                padding: EdgeInsets.symmetric(vertical: theme.space.x1),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Icon(LucideIcons.folder, size: 18),
                    Spacing(SpaceStep.x2, axis: Axis.horizontal),
                    Expanded(
                      child: BodyText(
                        root,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Semantics(
                      label: 'Remove $root',
                      child: Tooltip(
                        message: const Text('Remove folder'),
                        child: Button(
                          onPressed: () => setState(() => _roots.remove(root)),
                          variant: SurfaceVariant.ghost,
                          swatch: SemanticSwatch.error,
                          center: Icon(theme.icons.delete, size: 14),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          Spacing(SpaceStep.x2),
          Row(
            children: [
              Button(
                onPressed: _browse,
                variant: SurfaceVariant.ghost,
                swatch: SemanticSwatch.neutral,
                center: const Text('Add Folder…'),
              ),
            ],
          ),
        ],
      ),
      actions: [Button(onPressed: _submit, center: const Text('Create'))],
    );
  }
}

/// Name it, done — every collection plays in its laid order, reorders
/// freely, and shuffles when asked.
class _CreateCollectionDialog extends StatefulWidget {
  const _CreateCollectionDialog();

  @override
  State<_CreateCollectionDialog> createState() =>
      _CreateCollectionDialogState();
}

class _CreateCollectionDialogState extends State<_CreateCollectionDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      icon: LucideIcons.list,
      title: const Text('New collection'),
      content: TextField(
        controller: _name,
        autofocus: true,
        placeholder: const Text('Name'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [Button(onPressed: _submit, center: const Text('Create'))],
    );
  }
}
