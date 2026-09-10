import 'dart:convert';
import 'dart:io';

/// The handful of choices that must be known before the library is
/// reached — chiefly whether to reach it through the background daemon —
/// kept in a small JSON file in the config directory rather than in the
/// settings table, which lives on the far side of that very choice.
class AppPreferences {
  AppPreferences(this.file, {bool background = false})
    : _background = background; // ignore: prefer_initializing_formals

  final File file;
  bool _background;

  /// Whether the user asked Cadence to run its library in the background,
  /// as the `cadenced` user service.
  bool get background => _background;

  static Future<AppPreferences> load(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        return AppPreferences(file, background: decoded['background'] == true);
      }
    } on Object {
      // Missing or unreadable: every preference at its default.
    }
    return AppPreferences(file);
  }

  Future<void> setBackground(bool value) async {
    _background = value;
    await _save();
  }

  Future<void> _save() async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert({'background': _background})}\n',
      flush: true,
    );
  }
}
