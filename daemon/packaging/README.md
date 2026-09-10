# Packaging cadenced

Everything here is produced by the workspace tool (`tool/bin/cadence.dart`)
running inside the toolchain container (`toolchain/Containerfile`), which is
also what `.forgejo/workflows/ci.yml` runs. From the repository root:

```sh
toolchain/run.sh dart pub get --enforce-lockfile
toolchain/run.sh dart run tool/bin/cadence.dart build --arch armhf
toolchain/run.sh dart run tool/bin/cadence.dart package bundle \
  --bundle build/cli/armhf/bundle --arch armhf \
  --source-commit "$(git rev-parse HEAD)" --dart-version 3.13.2 \
  --output build/dist/cadenced-1.0.0-linux-armhf.tar.gz
toolchain/run.sh dart run tool/bin/cadence.dart package deb \
  --bundle build/cli/armhf/bundle --arch armhf --version 1.0.0 \
  --maintainer 'Name <email>' --output build/dist
```

`--arch` accepts `amd64`, `arm64` and `armhf`; without it `build` targets the
host into `build/cli`. The container tag is a digest of `toolchain/`, so
editing the Containerfile rebuilds it on the next run; `toolchain/run.sh
--shell` opens a shell inside it. Set `CADENCE_CONTAINER_ENGINE=docker` to use
Docker instead of podman.

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

The toolchain image is Debian bookworm so cross-linked binaries need nothing
newer than glibc 2.36, which bookworm-based targets provide.

Versions follow `daemon/pubspec.yaml`. CI packages a tag `vX.Y.Z` as `X.Y.Z`
and fails if the tag and pubspec disagree; every other build is
`X.Y.Z~git<date>.<sha>`, which sorts before the release.

## Continuous integration

`.forgejo/workflows/ci.yml` runs `cadence check` and one build job per
architecture on every push and pull request, saves the tarball and `.deb` of
each as an artifact, and on a `v*` tag publishes a release with all six files
attached. The jobs run `toolchain/run.sh`, so they need a runner label that
executes on a host with podman; the workflow uses `native`.
