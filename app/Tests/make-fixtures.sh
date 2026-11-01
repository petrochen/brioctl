#!/bin/sh
# Rewrites Tests/BrioctlCoreTests/Fixtures from the fake brioctl (tests/brioctl-fake, built by `make tests/brioctl-fake` in
# the repository root): the real output of --json, list --json and profiles --json for the emulated cameras.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
FAKE=$ROOT/tests/brioctl-fake
OUT=$HERE/BrioctlCoreTests/Fixtures
[ -x "$FAKE" ] || { echo "build $FAKE first: make -C $ROOT tests/brioctl-fake" >&2; exit 1; }
case $(env -u BRIOCTL_FAKE "$FAKE" show 2>&1 < /dev/null) in
*"BRIOCTL_FAKE is not set"*) ;;
*) echo "$FAKE is not the fake build; refusing to run" >&2; exit 1 ;;
esac

TMP=$(mktemp -d "${TMPDIR:-/tmp}/brioctl-fixtures.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT" "$TMP/home/.config/brioctl"
cp "$ROOT/tests/mxbrio-1.1.394.snap" "$TMP/mxbrio.snap"
cp "$ROOT/tests/generic-uvc.snap" "$TMP/generic.snap"
cp "$ROOT/tests/generic-uvc-extra.snap" "$TMP/extra.snap"
cp "$ROOT/tests/brio500-sim.snap" "$TMP/brio500.snap"
export HOME=$TMP/home
ALL=$TMP/mxbrio.snap:$TMP/generic.snap:$TMP/brio500.snap:$TMP/extra.snap

BRIOCTL_FAKE=$ALL "$FAKE" list --json > "$OUT/list-four-cameras.json"
BRIOCTL_FAKE=$TMP/mxbrio.snap "$FAKE" list --json > "$OUT/list-one-camera.json"
BRIOCTL_FAKE=$ALL "$FAKE" --camera 1 --json > "$OUT/state-mxbrio.json"
BRIOCTL_FAKE=$ALL "$FAKE" --camera 2 --json > "$OUT/state-generic.json"
BRIOCTL_FAKE=$ALL "$FAKE" --camera 3 --json > "$OUT/state-brio500.json"
BRIOCTL_FAKE=$ALL "$FAKE" --camera 4 --json > "$OUT/state-generic-extra.json" || true

# two saved files, as `save` writes them, and the path the app must not show as the user's
BRIOCTL_FAKE=$TMP/mxbrio.snap "$FAKE" save settings > /dev/null
BRIOCTL_FAKE=$TMP/mxbrio.snap "$FAKE" save desk > /dev/null
BRIOCTL_FAKE=$TMP/mxbrio.snap "$FAKE" profiles --json | sed "s|$TMP/home|/Users/example|" > "$OUT/profiles.json"
ls -l "$OUT"
