#!/bin/sh
# Run a command inside the Cadence build toolchain container.
#
#   toolchain/run.sh dart run tool/bin/cadence.dart build --arch arm64
#   toolchain/run.sh --shell
#
# The image is built from toolchain/Containerfile on first use and tagged
# with a digest of this directory, so editing the Containerfile rebuilds it
# automatically. The checkout is bind-mounted at its real host path and the
# command runs there as the calling user (--userns=keep-id), with cargo and
# Dart's cross-compilation caches kept under build/ and the host's pub cache
# shared. Inside the container the command simply runs.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
engine=${CADENCE_CONTAINER_ENGINE:-podman}

if [ "${CADENCE_TOOLCHAIN:-}" = 1 ]; then
  cd "$root"
  exec "$@"
fi

if [ "${1:-}" = --shell ]; then
  shift
  set -- bash
fi
if [ $# -eq 0 ]; then
  echo "usage: toolchain/run.sh [--shell | command ...]" >&2
  exit 64
fi

digest=$(cd "$root/toolchain" && find . -type f -not -name '.*' | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-12)
image="cadence-toolchain:$digest"

if ! "$engine" image exists "$image" 2>/dev/null; then
  echo "Building $image from toolchain/Containerfile" >&2
  "$engine" build -t "$image" -t cadence-toolchain:latest "$root/toolchain"
fi

# The pub cache is shared with the host at its own path, so the package
# resolution the container writes into .dart_tool stays valid outside it.
pub_cache=${PUB_CACHE:-$HOME/.pub-cache}
mkdir -p "$root/build/cargo" "$root/build/home" "$pub_cache"

tty=
if [ -t 0 ] && [ -t 1 ]; then tty=-t; fi

# Linked worktrees keep Git metadata outside the checkout; builds that record
# the source revision need it readable.
extra=
if [ -f "$root/.git" ]; then
  gitdir=$(sed -n 's/^gitdir: //p' "$root/.git")
  case $gitdir in /*) ;; *) gitdir=$root/$gitdir ;; esac
  if [ -f "$gitdir/commondir" ]; then
    common=$(cat "$gitdir/commondir")
    case $common in /*) ;; *) common=$gitdir/$common ;; esac
    gitdir=$common
  fi
  extra="-v $gitdir:$gitdir:ro"
fi

# shellcheck disable=SC2086
exec "$engine" run --rm -i $tty \
  -v "$root:$root" $extra \
  -w "$root" \
  --userns=keep-id \
  -e CADENCE_TOOLCHAIN=1 \
  -e "HOME=$root/build/home" \
  -e "CARGO_HOME=$root/build/cargo" \
  -v "$pub_cache:$pub_cache" \
  -e "PUB_CACHE=$pub_cache" \
  "$image" "$@"
