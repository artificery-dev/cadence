import 'package:tomeui/tomeui.dart';

import 'library_connection.dart';

/// The pictures, as the app remembers them: asked of the library once per
/// file, kept as [ImageProvider]s, and a null remembered just as firmly —
/// a bare file should not be asked about on every rebuild.
///
/// Asking is the trigger: [of] returns what has arrived and quietly sends
/// for what hasn't; listeners hear when something lands.
class ArtworkCache extends ChangeNotifier {
  ArtworkCache(this._connection);

  final LibraryConnection _connection;
  final _images = <int, ImageProvider?>{};
  final _pending = <int>{};

  /// The picture for [fileId], or null while it's on its way — or forever,
  /// when the file sits bare.
  ImageProvider? of(int fileId) {
    if (_images.containsKey(fileId)) return _images[fileId];
    if (_pending.add(fileId)) {
      _connection
          .artwork(fileId)
          .then((bytes) {
            _pending.remove(fileId);
            _images[fileId] = bytes == null ? null : MemoryImage(bytes);
            if (bytes != null) notifyListeners();
          })
          .catchError((Object _) {
            _pending.remove(fileId);
          });
    }
    return null;
  }

  /// One file's picture changed — the artwork queue rendered it — so the
  /// next asking fetches it afresh.
  void forget(int fileId) {
    if (_images.remove(fileId) != null || _pending.contains(fileId)) {
      notifyListeners();
    }
  }

  /// A scan may have brought new pictures: forget everything and let the
  /// next asking fetch afresh.
  void invalidate() {
    _images.clear();
    notifyListeners();
  }
}

/// Hands the cache down the tree; anything that depends rebuilds when a
/// picture lands.
class ArtworkScope extends InheritedNotifier<ArtworkCache> {
  const ArtworkScope({
    required ArtworkCache cache,
    required super.child,
    super.key,
  }) : super(notifier: cache);

  static ArtworkCache? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ArtworkScope>()?.notifier;
}
