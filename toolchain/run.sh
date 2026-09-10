#!/bin/sh
# Run a command inside the Cadence build toolchain container.
#
#   toolchain/run.sh cadence build --arch arm64
#   toolchain/run.sh --shell
#
# The image is built from toolchain/Containerfile on first use and tagged
# with the digest from toolchain/digest.sh (this directory plus the sources
# of the workspace tool it AOT-compiles), so editing either rebuilds it
# automatically; CI computes the same digest to name the image it pushes to
# the Forgejo registry (see .forgejo/workflows/ci.yml). Inside the image the
# tool is on PATH as `cadence`. The checkout is bind-mounted at its real host path and the
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

digest=$(sh "$root/toolchain/digest.sh")
image="cadence-toolchain:$digest"

if ! "$engine" image exists "$image" 2>/dev/null; then
  echo "Building $image from toolchain/Containerfile" >&2
  # The image is x86-64 only (the Dart SDK inside is), so say so rather than
  # inherit whatever platform the host last pulled the base image for.
  "$engine" build --platform linux/amd64 -t "$image" -t cadence-toolchain:latest \
    -f "$root/toolchain/Containerfile" "$root"
fi

# The pub cache is shared with the host at its own path, so the package
# resolution the container writes into .dart_tool stays valid outside it.
pub_cache=${PUB_CACHE:-$HOME/.pub-cache}
mkdir -p "$root/build/cargo" "$root/build/home" "$pub_cache"

# The Flutter app's build tree and package resolution are per toolchain: a
# CMake cache names the machine's own compilers and a package config names
# its own SDK, so the container gets separate directories mounted over the
# app's, and both it and the host keep their incremental builds.
mkdir -p "$root/build/container/app-build" "$root/build/container/app-dart_tool"

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
  -v "$root/build/container/app-build:$root/app/build" \
  -v "$root/build/container/app-dart_tool:$root/app/.dart_tool" \
  "$image" "$@"
