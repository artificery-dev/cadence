import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

import 'library_views.dart';

/// How a shelf presents itself: pictures on a grid, or rows in a table.
enum ViewMode { grid, table }

/// One view's presentation choices — all optional, because absence means
/// the view's own defaults. Persisted as JSON in the settings table under
/// `views.<libraryId>.<viewKind>`.
class ViewPrefs {
  const ViewPrefs({
    this.mode,
    this.columns,
    this.sortColumn,
    this.sortAscending = true,
    this.facet,
  });

  factory ViewPrefs.fromJson(Map<String, Object?> json) => ViewPrefs(
    mode: switch (json['mode']) {
      final String name => ViewMode.values.byName(name),
      _ => null,
    },
    columns: switch (json['columns']) {
      final List raw => raw.cast<String>(),
      _ => null,
    },
    sortColumn: json['sortColumn'] as String?,
    sortAscending: json['sortAscending'] as bool? ?? true,
    facet: json['facet'] as String?,
  );

  /// Grid or table — null takes the view's own default.
  final ViewMode? mode;

  /// Visible column ids, in the table's own order — null takes the
  /// column roster's defaults.
  final List<String>? columns;

  /// The column the table sorts by — null keeps the shelf's own order.
  final String? sortColumn;
  final bool sortAscending;

  /// Which face a many-faced view shows — a name the view itself defines
  /// ('series', 'episodes', …); null takes the view's own default. Music
  /// keeps its facet under its own key instead, because each of its
  /// faces carries separate prefs.
  final String? facet;

  ViewPrefs copyWith({
    ViewMode? mode,
    List<String>? columns,
    String? Function()? sortColumn,
    bool? sortAscending,
    String? facet,
  }) => ViewPrefs(
    mode: mode ?? this.mode,
    columns: columns ?? this.columns,
    sortColumn: sortColumn == null ? this.sortColumn : sortColumn(),
    sortAscending: sortAscending ?? this.sortAscending,
    facet: facet ?? this.facet,
  );

  Map<String, Object?> toJson() => {
    if (mode != null) 'mode': mode!.name,
    if (columns != null) 'columns': columns,
    if (sortColumn != null) 'sortColumn': sortColumn,
    if (!sortAscending) 'sortAscending': false,
    if (facet != null) 'facet': facet,
  };
}

/// The presentation choices for every view, loaded lazily and remembered:
/// asking answers what has arrived (defaults meanwhile) and quietly sends
/// for the rest; updates land locally at once and persist behind the
/// scenes. Listeners hear both.
class ViewPrefsStore extends ChangeNotifier {
  ViewPrefsStore(this._client);

  final MediaClient _client;
  final _prefs = <String, ViewPrefs>{};
  final _pending = <String>{};

  static String _key(int libraryId, LibraryViewKind kind) =>
      'views.$libraryId.${kind.name}';

  static SettingDef<Map<String, Object?>> _def(String key) =>
      SettingDef.json<Map<String, Object?>>(key, const {});

  /// This view's choices as last known — defaults until the settings
  /// table has answered.
  ViewPrefs of(int libraryId, LibraryViewKind kind) {
    final key = _key(libraryId, kind);
    final held = _prefs[key];
    if (held != null) return held;
    if (_pending.add(key)) {
      _client
          .getSetting(_def(key))
          .then((json) {
            _pending.remove(key);
            _prefs[key] = ViewPrefs.fromJson(json.cast<String, Object?>());
            notifyListeners();
          })
          .catchError((Object _) {
            _pending.remove(key);
          });
    }
    return const ViewPrefs();
  }

  /// Takes the change now and writes it down after — the shelf must not
  /// wait on the settings table to re-sort.
  void update(int libraryId, LibraryViewKind kind, ViewPrefs prefs) {
    final key = _key(libraryId, kind);
    _prefs[key] = prefs;
    notifyListeners();
    _client.setSetting(_def(key), prefs.toJson()).catchError((Object _) {});
  }

  // --- Facets: which face a multi-faceted view (Music) shows ---

  final _facets = <int, LibraryViewKind>{};
  final _facetsPending = <int>{};

  static SettingDef<String> _facetDef(int libraryId) =>
      SettingDef.json<String>('views.$libraryId.facet', '');

  /// The facet last chosen for [libraryId], or [fallback] until the
  /// settings table has answered (or when nothing was ever chosen).
  LibraryViewKind facetOf(int libraryId, {required LibraryViewKind fallback}) {
    final held = _facets[libraryId];
    if (held != null) return held;
    if (_facetsPending.add(libraryId)) {
      _client
          .getSetting(_facetDef(libraryId))
          .then((name) {
            _facetsPending.remove(libraryId);
            final kind = LibraryViewKind.values
                .where((k) => k.name == name)
                .firstOrNull;
            if (kind != null) {
              _facets[libraryId] = kind;
              notifyListeners();
            }
          })
          .catchError((Object _) {
            _facetsPending.remove(libraryId);
          });
    }
    return fallback;
  }

  void setFacet(int libraryId, LibraryViewKind kind) {
    _facets[libraryId] = kind;
    notifyListeners();
    _client
        .setSetting(_facetDef(libraryId), kind.name)
        .catchError((Object _) {});
  }
}
