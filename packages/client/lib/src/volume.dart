/// Portable volume status. Activity describes Cadence work, not kernel or
/// player I/O. Only the host's successful OS unmount permits physical removal.
class VolumeStatus {
  VolumeStatus.fromJson(Map<String, Object?> json)
    : id = json['id'] as String?,
      generation = json['generation'] as String?,
      state = json['state'] as String,
      readyToUnmount = json['readyToUnmount'] == true,
      activity = (json['activity'] as Map? ?? const {}).cast<String, Object?>(),
      error = json['error'] as String?;
  final String? id, generation, error;
  final String state;
  final bool readyToUnmount;
  final Map<String, Object?> activity;
}

/// A local playback path supplied by the host adapter. Valid only for the
/// returned attachment generation. Discard on quiescing/removal/reconnect,
/// and release all player handles before requesting Cadence eject.
class MediaLocation {
  MediaLocation.fromJson(Map<String, Object?> json)
    : libraryUuid = json['libraryUuid'] as String,
      itemId = json['itemId'] as int,
      volumeId = json['volumeId'] as String,
      generation = json['generation'] as String,
      path = json['path'] as String;
  final String libraryUuid, volumeId, generation, path;
  final int itemId;
}
