import 'dart:convert';

import '../database/database.dart';

/// One setting, described once: the namespaced key, the fallback, and how
/// the value crosses the JSON boundary. Call sites hold a definition, never
/// a bare string — the app's roster of settings is a list of these (an enum
/// wearing definitions, ideally), and typos stop compiling.
class SettingDef<T> {
  const SettingDef({
    required this.key,
    required this.fallback,
    required this.encode,
    required this.decode,
  });

  /// A setting whose value is already JSON-representable (String, num,
  /// bool, List, Map).
  static SettingDef<T> json<T>(String key, T fallback) => SettingDef(
    key: key,
    fallback: fallback,
    encode: (value) => value,
    decode: (raw) => raw as T,
  );

  /// A setting holding one value of an enum, stored by name.
  static SettingDef<T> enumOf<T extends Enum>(
    String key,
    List<T> values,
    T fallback,
  ) => SettingDef(
    key: key,
    fallback: fallback,
    encode: (value) => value.name,
    decode: (raw) =>
        raw is String ? values.asNameMap()[raw] ?? fallback : fallback,
  );

  /// Dotted, namespaced, of indiscriminate length.
  final String key;

  /// What [SettingsStore.get] answers before anything was ever written.
  final T fallback;

  final Object? Function(T value) encode;
  final T Function(Object? json) decode;
}

/// The scanner's corner of the roster, held where every setting lives.
abstract final class ScannerSettings {
  /// Whether library roots are watched between scans, changes rescanned as
  /// they land. Off by default — watching costs inotify handles and
  /// surprises.
  static final SettingDef<bool> watchFolders = SettingDef.json(
    'scanner.watchFolders',
    false,
  );
}

/// The settings table, spoken to through definitions.
class SettingsStore {
  const SettingsStore(this.db);

  final MediaDatabase db;

  Future<T> get<T>(SettingDef<T> def) async {
    final row = await (db.select(
      db.settings,
    )..where((s) => s.key.equals(def.key))).getSingleOrNull();
    if (row == null) return def.fallback;
    return def.decode(jsonDecode(row.value));
  }

  Future<void> set<T>(SettingDef<T> def, T value) =>
      putRaw(def.key, jsonEncode(def.encode(value)));

  /// The wire's way in: the value is already encoded JSON text.
  Future<void> putRaw(String key, String encodedValue) => db
      .into(db.settings)
      .insertOnConflictUpdate(
        SettingsCompanion.insert(key: key, value: encodedValue),
      );

  /// The value, live — emits the fallback until a row exists.
  Stream<T> watch<T>(SettingDef<T> def) =>
      (db.select(
        db.settings,
      )..where((s) => s.key.equals(def.key))).watchSingleOrNull().map(
        (row) => row == null ? def.fallback : def.decode(jsonDecode(row.value)),
      );
}
