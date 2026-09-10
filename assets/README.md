# Cadence assets

One copy of the artwork, in every format the platforms want, so nothing is
regenerated per consumer. Mirrors the layout Tempo keeps in its `assets/`.

| Path | Used by |
|---|---|
| `cadence/svg/` | the sources: square, rounded and macOS icon shapes, marks on light and dark |
| `cadence/android/res/` | copied into `app/android/app/src/main/res` (adaptive launcher icons) |
| `cadence/ios/AppIcon.appiconset/` | `app/ios/Runner/Assets.xcassets/AppIcon.appiconset` |
| `cadence/macos/` | `.icns` and the 1024 PNG the macOS asset catalogue is cut from |
| `cadence/web/` | favicons, PWA icons and the manifest fragment for `app/web` |
| `cadence/windows/` | the `.ico` for the Windows runner |
| `cadence/linux/` | the hicolor icon set, `dev.artificery.cadence.desktop` and the AppStream metainfo the Debian package installs |

The Dart package (`cadence_assets`) exposes the web PNGs as Flutter assets for
in-app use — the About card shows [CadenceAssets.icon].
