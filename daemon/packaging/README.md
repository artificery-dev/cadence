# Packaging cadenced

Everything here is produced by the workspace tool (`tool/bin/cadence.dart`)
running inside the toolchain container (`toolchain/Containerfile`), which is
also what `.forgejo/workflows/ci.yml` runs. From the repository root:

```sh
toolchain/run.sh dart pub get --enforce-lockfile
toolchain/run.sh cadence build --arch armhf
toolchain/run.sh cadence package bundle \
  --bundle build/cli/armhf/bundle --arch armhf \
  --source-commit "$(git rev-parse HEAD)" --dart-version 3.13.2 \
  --output build/dist/cadenced-1.0.0-linux-armhf.tar.gz
toolchain/run.sh cadence package deb \
  --bundle build/cli/armhf/bundle --arch armhf --version 1.0.0 \
  --maintainer 'Name <email>' --output build/dist
```

Inside the image `cadence` is the AOT-compiled workspace tool (outside it,
`dart run tool/bin/cadence.dart` is the same program; it treats the current
directory as the workspace when compiled, or `CADENCE_ROOT` when set).
`--arch` accepts `amd64`, `arm64` and `armhf`; without it `build` targets the
host into `build/cli`. The container tag comes from `toolchain/digest.sh`,
which covers `toolchain/`, the tool's sources and the workspace pubspecs, so
editing any of them rebuilds the image on the next run; `toolchain/run.sh
--shell` opens a shell inside it. Set `CADENCE_CONTAINER_ENGINE=docker` to use
Docker instead of podman.

`cadence check` builds the host bundle before the daemon integration suites
and points them at it through `CADENCE_VOLUME_EXECUTABLE`, so the daemons
those suites spawn are compiled rather than JIT-run; without that, readiness
and job timeouts tripped on loaded runners.

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

`.forgejo/workflows/ci.yml` runs on the `linux-amd64-container` runners,
which execute every job inside a container with no docker socket and no
privileges. The first job computes the toolchain digest (`toolchain/digest.sh`, the
same formula `toolchain/run.sh` uses) and asks the instance's container registry
whether `<host>/<owner>/cadence-toolchain:<digest>` exists; if not, a kaniko
job builds `toolchain/Containerfile` from the repository archive (context:
the repository root, trimmed by `.dockerignore`) and pushes it. The check job and one build job per architecture then run inside that
image, save the tarball and `.deb` of each architecture as artifacts, and on
a `v*` tag a release is published with all six files attached.

Registry access uses the workflow token by default. If the instance does not
let workflow tokens read or write packages, set the
`CI_FORGEJO_REGISTRY_USERNAME` and `CI_FORGEJO_REGISTRY_TOKEN` secrets (the
same names the outsized workflows use) to an account with package access.
Changing the toolchain image is a normal commit: the new digest is built on
the next run and older tags stay in the registry until pruned.
