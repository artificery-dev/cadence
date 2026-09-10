#!/bin/sh
# Print the short digest that names the toolchain image.
#
# The image bakes in an AOT build of the workspace tool, so its identity
# covers the tool's sources and the workspace resolution as well as this
# directory. toolchain/run.sh and .forgejo/workflows/ci.yml both call this
# so local and CI images agree on their tags.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
{
  find toolchain tool packages/client -type f -not -name '.*' -not -path '*/.dart_tool/*'
  printf '%s\n' pubspec.yaml pubspec.lock daemon/pubspec.yaml packages/media/pubspec.yaml LICENSE .dockerignore
} | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-12
