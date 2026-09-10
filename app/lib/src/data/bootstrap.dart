import 'package:cadence_media/cadence_media.dart'
    hide File, Directory, FileSystemEntity, FileSystem, Link;

import '../model/audio_engine.dart';
import '../model/player.dart';
import '../model/settings.dart';
import 'environment.dart';
import 'hosting.dart';
import 'library_connection.dart';

/// Everything the app carries out of startup: the library reached,
/// settings read back, the music library loaded when one exists, and the
/// deck queued. The database itself lives behind [connection]'s transport
/// — the host in its own isolate, or the daemon in its own process. An
/// empty world boots empty: real libraries come from Folders… and a scan,
/// not a seed.
class Bootstrap {
  const Bootstrap({
    required this.environment,
    required this.connection,
    this.hosting,
    required this.settings,
    required this.player,
    required this.library,
    required this.items,
    required this.allLibraries,
    required this.itemsByLibrary,
    required this.collections,
    required this.collectionEntries,
  });

  /// Installed or portable, and where pickers open.
  final AppEnvironment environment;

  /// The line to the library, whoever hosts it.
  final LibraryConnection connection;

  /// The hand on the media service — [connection]'s typed client.
  MediaClient get client => connection.client;

  /// Who runs the library and the switch between them; null when the
  /// app was booted over a fixed client, as tests do.
  final HostingController? hosting;
  final SettingsModel settings;
  final PlaybackController player;

  /// The audio library the player's queue draws from — the deck's home.
  /// Null until the first audio library exists.
  final LibraryRow? library;
  final List<AudioItem> items;

  /// Every library, in the order the sidebar was left in.
  final List<LibraryRow> allLibraries;

  /// Library id → its items, whatever their kinds.
  final Map<int, List<MediaItem>> itemsByLibrary;

  /// Every collection — app-level lists that may point into any library.
  final List<CollectionRow> collections;

  /// Collection id → item ids, in laid order.
  final Map<int, List<int>> collectionEntries;

  /// [engine] is what actually makes sound — main hands in media_kit;
  /// tests leave it null and the deck keeps its silent mock clock.
  static Future<Bootstrap> load(
    LibraryConnection connection, {
    AppEnvironment environment = const AppEnvironment.installed(),
    AudioEngine? engine,
    HostingController? hosting,
  }) async {
    final client = connection.client;
    final settings = SettingsModel(client);
    await settings.load();

    final allLibraries = inSidebarOrder(
      await client.listLibraries(),
      settings.libraryOrder,
      (row) => row.id,
    );
    final library = allLibraries
        .where((l) => l.type == LibraryType.music)
        .firstOrNull;
    final items = library == null
        ? const <AudioItem>[]
        : await client.audioItems(library.id);
    final itemsByLibrary = {
      for (final row in allLibraries) row.id: await client.mediaItems(row.id),
    };

    final collections = inSidebarOrder(
      await client.listCollections(),
      settings.collectionOrder,
      (row) => row.id,
    );
    final collectionEntries = {
      for (final collection in collections)
        collection.id: await client.collectionEntries(collection.id),
    };

    return Bootstrap(
      environment: environment,
      connection: connection,
      hosting: hosting,
      settings: settings,
      player: PlaybackController(
        List.of(items),
        journal: client,
        engine: engine,
        // The deck opens at last session's level, and writes the level
        // back down whenever it settles somewhere new.
        initialVolume: settings.volume,
        onVolumeChanged: (value) => settings.volume = value,
      ),
      library: library,
      items: items,
      allLibraries: allLibraries,
      itemsByLibrary: itemsByLibrary,
      collections: collections,
      collectionEntries: collectionEntries,
    );
  }
}
