/// Artwork bundled once for Flutter consumers. Native launchers and platform
/// tools read the platform formats alongside these files in this package:
/// `cadence/<platform>/` holds each launcher's icons in the layout that
/// platform wants, `cadence/svg/` the sources, and `cadence/linux/` the
/// hicolor set plus the desktop entry and AppStream metadata the Linux
/// package installs.
abstract final class CadenceAssets {
  static const package = 'cadence_assets';

  /// The application id every platform carries.
  static const applicationId = 'dev.artificery.cadence';
  static const icon = 'cadence/web/icon-512.png';
}
