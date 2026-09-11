#!/bin/sh
# Run a command inside the shared toolbox image, from the repository root.
#
#   toolchain/run.sh cadence build --arch arm64
#   toolchain/run.sh cargo test --workspace
#   toolchain/run.sh --shell
#
# The image is the toolbox (https://git.artificery.dev/artificery/toolbox),
# the one build and CI image every project on the instance shares; CI pins a
# tag of it in .forgejo/workflows/ci.yml. The toolbox's own run.sh does the
# work: it bind-mounts the checkout at its real host path, runs the command
# there as the calling user, keeps HOME and CARGO_HOME in a per-project
# directory under ~/.local/state/toolbox, and shares the host's pub cache.
# It builds localhost/toolbox:latest from its checkout the first time; set
# TOOLBOX_IMAGE to the tag CI pins to use the registry's copy instead. The
# toolbox checkout is expected at ~/Projects/toolbox, or where TOOLBOX_DIR
# points.
#
# The image carries no compiled copy of the workspace tool, so a leading
# `cadence` runs it from source (`dart run tool/bin/cadence.dart`). Inside
# the container the command simply runs.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

if [ "${1:-}" = cadence ]; then
  shift
  set -- dart run tool/bin/cadence.dart "$@"
fi

if [ "${TOOLBOX_CONTAINER:-}" = 1 ]; then
  exec "$@"
fi

toolbox=${TOOLBOX_DIR:-$HOME/Projects/toolbox}
if [ ! -x "$toolbox/run.sh" ]; then
  echo "toolchain/run.sh: no toolbox checkout at $toolbox; clone" \
    "git.artificery.dev/artificery/toolbox there or set TOOLBOX_DIR" >&2
  exit 69
fi

exec "$toolbox/run.sh" "$@"
