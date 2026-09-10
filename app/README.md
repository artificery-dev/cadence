# Cadence

The desktop face of Cadence: a Flutter app over the media library that
`cadenced` and `cadence_media` keep. Built on [Tome UI](https://pub.dev/packages/tomeui).

## Where the library runs

The app never opens the database itself. It speaks to a *host* through
`cadence_client`'s `MediaTransport`, and there are two hosts to choose from:

- **Built in** (the default). `EmbeddedLibrary` runs the daemon's own
  `ManagedLibraryHost` in an isolate of this process — the same code as
  `cadenced --database … --cache …`, on the same paths the user service
  would use — and goes away with the app.
- **In the background.** Settings › Background › *Allow Cadence to run in
  the background* installs `cadenced` as the user's systemd service
  (`~/.local/share/cadenced`, unit in `~/.config/systemd/user`), enables it
  to start with the session, and hands the library over: the built-in host
  closes, releasing the database's ownership lock; the daemon opens the same
  file; the app's transport is swapped for the daemon's socket without the
  deck stopping. Switching it off stops and disables the service and brings
  the library back inside. The choice is remembered in
  `~/.config/cadence/app.json`, and at boot a daemon that already answers on
  `$XDG_RUNTIME_DIR/cadence/media.sock` is used regardless.

If the daemon drops out — stopped, crashed, upgraded — the connection notices
the event line hang up (or a request fail to reach anyone) and the hosting
controller gives it a few seconds to be restarted by systemd. If it does not
come back, the app stops the unit for this session, takes the library back
inside, and says so in a toast and under the switch; the preference is left
on, so the next launch tries the background again.

`LibraryConnection` is the seam: one typed `MediaClient` whose transport can
be exchanged while requests wait; `HostingController` does the exchanging.
The host's events (`change`, item events, artwork) reach the shell and
refresh the shelves, so a scan the daemon runs on its own — a folder watch,
another client — shows up without a click.

Paths, installed on Linux (portable runs put all three under
`<dir>/.cadence/`):

| What | Where |
|---|---|
| Database | `$XDG_STATE_HOME/cadence/library.sqlite` |
| Artwork cache | `$XDG_CACHE_HOME/cadence` |
| Preferences | `$XDG_CONFIG_HOME/cadence/app.json` |
| Daemon socket | `$XDG_RUNTIME_DIR/cadence/media.sock` |

The background service needs Linux with a systemd user session and a daemon
the app can find, in this order: `CADENCE_DAEMON_BUNDLE`; the `cadenced`
package's copy at `/usr/lib/cadenced`, which is run in place (the app never
copies it, and the package manager keeps it current); `daemon/` beside the
app's executable (what `cadence app build` lays down); or the workspace's
`build/cli/bundle` from a dev run. The last two are copied to
`~/.local/share/cadenced` when the service is enabled. A packaged app should
therefore `Recommends: cadenced` rather than conflict with it: the package's
system unit (system scope, the `cadence` account, `/run/cadence`) and the
app's user unit (`$XDG_RUNTIME_DIR/cadence`) run different libraries and
never collide.

## Developing

`app/` sits outside the pub workspace — it needs the Flutter SDK, which the
daemon's toolchain does not carry — and depends on `../packages/media`,
`../packages/client` and `../daemon` by path.

```sh
dart run tool/bin/cadence.dart build        # cadenced + probe into build/cli/bundle
cd app && flutter run -d linux --no-enable-impeller --dart-entrypoint-args=--portable-dir=../storage
```

The `.vscode/launch.json` configurations do the same. `flutter analyze` and
`flutter test` run from `app/`; from the root, `dart run tool/bin/cadence.dart app check`
does both, and `… app build` produces `app/build/linux/x64/release/bundle`
with the daemon bundled beside it.

`--portable-dir=<path>` keeps everything under `<path>/.cadence/` and opens
file pickers at `<path>`. The demo library lives in `storage/` (gitignored),
which is what the launch configurations point at.

The toolchain container carries Flutter too, so `toolchain/run.sh cadence app
check` and `… app build` reproduce what CI does. A checkout shared between the
host and the container is resolved afresh by each (`cadence app …` drops
`app/.dart_tool/package_config.json` before `flutter pub get`), so the host's
next `flutter` command re-resolves as well.

## Packaging

`cadence package app-deb --bundle app/build/linux/x64/release/bundle --version …
--maintainer … --output build/dist` builds `cadence_<version>_amd64.deb`: the
Flutter bundle under `/usr/lib/cadence` (without the bundled daemon), a
`/usr/bin/cadence` link, the desktop entry, AppStream metainfo and hicolor
icons from `assets/cadence/linux`, and `Recommends: cadenced`. The tarball CI
also publishes keeps `daemon/` inside for a manual install without the daemon
package. The application id is `dev.artificery.cadence` everywhere: the GTK
application id and program name, the desktop entry and icon names, and the
bundle identifiers on the other platforms. App and daemon share one version,
which CI checks.

Artwork lives in `../assets` (`cadence_assets`), one copy in every platform's
format; the platform runners under `app/` carry copies where the toolchains
insist on them.
