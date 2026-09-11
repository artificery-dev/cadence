# Packaging cadenced

Everything here is produced by the workspace tool (`tool/bin/cadence.dart`)
running inside the shared toolbox image
(https://git.artificery.dev/artificery/toolbox), which is also what
`.forgejo/workflows/ci.yml` runs. From the repository root:

```sh
toolchain/run.sh dart pub get --enforce-lockfile
toolchain/run.sh cadence build --arch armhf
toolchain/run.sh cadence package bundle \
  --bundle build/cli/armhf/bundle --arch armhf \
  --source-commit "$(git rev-parse HEAD)" --dart-version 3.13.3 \
  --output build/dist/cadenced-1.0.0-linux-armhf.tar.gz
toolchain/run.sh cadence package deb \
  --bundle build/cli/armhf/bundle --arch armhf --version 1.0.0 \
  --maintainer 'Name <email>' --output build/dist
```

`toolchain/run.sh` is a thin wrapper over the toolbox's own `run.sh`,
expected at `~/Projects/toolbox` (or `TOOLBOX_DIR`): it mounts the checkout
at its real path, runs the command as the calling user, and keeps HOME and
the cargo home per project under `~/.local/state/toolbox`. A leading
`cadence` runs the tool from source, since the image carries no compiled
copy (`dart run tool/bin/cadence.dart` is the same program; compiled, it
treats the current directory as the workspace, or `CADENCE_ROOT` when set).
`--arch` accepts `amd64`, `arm64` and `armhf`; without it `build` targets the
host into `build/cli`. The toolbox builds `localhost/toolbox:latest` from its
checkout the first time; `TOOLBOX_IMAGE=git.artificery.dev/artificery/toolbox:<tag>`
uses the registry copy CI pins instead, and `toolchain/run.sh --shell` opens
a shell inside it.

`cadence check` builds the host bundle before the daemon integration suites
and points them at it through `CADENCE_VOLUME_EXECUTABLE`, so the daemons
those suites spawn are compiled rather than JIT-run; without that, readiness
and job timeouts tripped on loaded runners.

The desktop app in `app/` is packaged by `cadence app build`, which runs
`flutter build linux` and copies a `cadence build` bundle to `daemon/`
beside the app's executable; the app installs that copy as the user's
`cadenced.service` when asked to run in the background (see `app/README.md`).

## Bundle

`build` leaves a `dart build cli` bundle at `build/cli/<arch>/bundle`:

| Path | Origin |
|---|---|
| `bin/cadenced`, `bin/cadencectl` | `dart build cli --target-os linux --target-arch …` |
| `lib/libsqlite3.so` | the `sqlite3` package's build hook (prebuilt for the target) |
| `lib/libcadence_probe.so` | `cargo build --target …` of `crates/probe` |
| `LICENSE` | repository root |

`package bundle` adds `manifest.json` (source commit, Dart SDK version, Dart
architecture name, SHA-256 per file) in the layout Tempo's rootfs staging
verifies, and archives the directory as `cadenced/…` in a gzip tarball. The
daemon finds the probe in `lib/` beside its `bin/` without `CADENCE_PROBE_PATH`.

## Debian package

`package deb` stages a binary package under `build/deb/<arch>/` and builds it
with `dpkg-deb --root-owner-group`. The package:

- installs the bundle to `/usr/lib/cadenced` and links `/usr/sbin/cadenced`
  and `/usr/bin/cadencectl` into it;
- ships `/usr/lib/systemd/system/cadenced.service`, rendered from
  `systemd/cadenced.system.service.liquid` for the `cadence` service account
  with native extraction on, and leaves it **disabled**: hosts that supervise
  the daemon themselves (Tempo's `tempod`) must not also start the unit, and a
  standalone host runs `systemctl enable --now cadenced` once it has granted
  `cadence` read access to its media;
- creates the `cadence` system account on install, stops the unit on removal,
  and removes `/var/lib/cadenced` and `/var/cache/cadenced` on purge;
- declares `libc6 (>= 2.NN)` from the newest glibc symbol version any shipped
  ELF file binds to, plus `libgcc-s1` and `adduser`.

The toolbox image is Debian bookworm so cross-linked binaries need nothing
newer than glibc 2.36, which bookworm-based targets provide.

Versions follow `daemon/pubspec.yaml`, and `app/pubspec.yaml` must carry the
same number. CI packages a tag `vX.Y.Z` as `X.Y.Z` and fails if the tag and
pubspecs disagree; every other build is
`X.Y.Z~git<date>.<sha>`, which sorts before the release.

## Continuous integration

`.forgejo/workflows/ci.yml` runs on pushes to `main` and `ci`, on pull
requests, on `v*` tags and on manual dispatch. The `ci` branch is for trying
the pipeline without touching `main` (which is mirrored publicly): every run
on it goes through to a disposable prerelease at the moving tag `ci-test`.
The check job runs `cadence check --no-integration` in CI for now; the daemon
integration suites spawn real daemons and mounts and have not been reliable
on the shared runners, so run the full `cadence check` locally.

The desktop app's own Debian package comes from `cadence package app-deb`
(see `app/README.md`); it recommends this one rather than bundling a daemon.

The desktop app has two jobs of its own in the same image — which carries
the current stable Flutter SDK under FVM and the Linux desktop build
dependencies (GTK, clang/cmake/ninja, libmpv, epoxy) for it — running side
by side with the daemon's check: one analyzes and tests the app (`cadence
app check`), the other builds it (`cadence app build`) and saves the bundle
tarball (with `cadenced` inside) and the app's Debian package as the
`cadence-app-amd64` artifact; releases attach them beside the daemon
packages. Pushes to `main` run every job but publish nothing.

The jobs run on the `linux-amd64-container` runners, which execute every
job inside a container with no docker socket and no privileges. Every job
runs inside the toolbox image, pinned in the workflow by the first twelve
characters of the toolbox commit that built it (one `sed` bumps every
`container: image:` line together; the container key cannot read `env`).
The image is private to the instance, so jobs pull it with the workflow
token, or with the `CI_FORGEJO_REGISTRY_USERNAME` /
`CI_FORGEJO_REGISTRY_TOKEN` secrets when set. Each job resolves the
workspace, compiles the tool to `build/bin/cadence`, and runs it; the build
jobs check every shipped ELF file with `file` against the target
architecture, since some Dart SDKs have packaged an x86-64 launcher for
cross builds. On a `v*` tag a release is published with all six daemon
files and the two app files attached.
