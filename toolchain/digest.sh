#!/bin/sh
# Print the short digest that names the toolchain image.
#
# The image bakes in an AOT build of the workspace tool, so its identity
# covers the tool's sources and the workspace resolution (pubspec.lock) as
# well as this directory. The other members' pubspecs are copied into the
# image only so the workspace resolves; their contents are deliberately not
# hashed, so a daemon version bump does not rebuild the toolchain (a real
# dependency change shows up in the lockfile). toolchain/run.sh and
# .forgejo/workflows/ci.yml both call this so local and CI images agree.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
{
  find toolchain tool packages/client -type f -not -name '.*' -not -path '*/.dart_tool/*'
  printf '%s\n' pubspec.yaml pubspec.lock LICENSE .dockerignore
} | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-12
