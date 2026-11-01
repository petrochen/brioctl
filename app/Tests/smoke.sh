#!/bin/sh
# Headless smoke test: starts build/brioctl.app on emulated cameras (the fake CLI of the repository, never USB), sends it
# brioctl:// URLs with `open` and checks the result with the fake CLI. Nothing is clicked. Run it with `make smoke`.
#
# Everything the app reads from outside is redirected (see AppEnvironment.swift): the CLI, the LaunchAgents directory,
# the preferences suite. The same variables go to `open --env`, so even a copy of the app that LaunchServices starts
# afresh talks to the fake and not to a real camera.
set -u

HERE=$(cd "$(dirname "$0")" && pwd) || exit 1
ROOT=$(cd "$HERE/../.." && pwd)
APP=$(cd "$HERE/../build/brioctl.app" 2>/dev/null && pwd -P)  # the path the app's process shows, without ..
FAKE=$ROOT/tests/brioctl-fake
BUNDLE_ID=com.github.petrochen.brioctl.app

fail() { echo "FAIL: $*"; FAILED=1; }
FAILED=0

[ -n "$APP" ] && [ -x "$APP/Contents/MacOS/brioctl-app" ] || { echo "Bail out! build the app first: make -C app"; exit 1; }
[ -x "$FAKE" ] || { echo "Bail out! $FAKE is not built: make tests/brioctl-fake"; exit 1; }
case $(env -u BRIOCTL_FAKE "$FAKE" show 2>&1 < /dev/null) in
*"BRIOCTL_FAKE is not set"*) ;;
*) echo "Bail out! $FAKE is not the fake build; refusing to go on"; exit 1 ;;
esac
# A running copy would get the URLs, and it may talk to a real camera.
if [ -n "$(lsappinfo find bundleid=$BUNDLE_ID 2>/dev/null)" ]; then
    echo "Bail out! brioctl.app ($BUNDLE_ID) is already running; quit it first"
    exit 1
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/brioctl-smoke.XXXXXX") || exit 1
SUITE=$BUNDLE_ID.smoke.$$
PID=
cleanup() {
    # Only this copy of the app, by its full path: a bare `pkill brioctl` would also stop a real `brioctl watch` agent.
    pkill -f "$APP/Contents/MacOS/brioctl-app" 2>/dev/null
    defaults delete "$SUITE" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

mkdir -p "$TMP/home" "$TMP/agents"
cp "$ROOT/tests/mxbrio-1.1.394.snap" "$TMP/camera1.snap"
cp "$ROOT/tests/generic-uvc.snap" "$TMP/camera2.snap"
SNAPS=$TMP/camera1.snap:$TMP/camera2.snap

fake() { BRIOCTL_FAKE=$SNAPS HOME=$TMP/home "$FAKE" "$@"; }
launch() {  # launch URL...: open the app (with the fake environment) and hand it the URLs
    open -a "$APP" \
        --env "BRIOCTL_FAKE=$SNAPS" --env "BRIOCTL_APP_CLI=$FAKE" --env "BRIOCTL_APP_AGENTS_DIR=$TMP/agents" \
        --env "BRIOCTL_APP_DEFAULTS_SUITE=$SUITE" --env "HOME=$TMP/home" \
        --stdout "$TMP/app.out" --stderr "$TMP/app.err" "$@" 2>&1 | grep -v "was already running"
}
app_pid() { pgrep -f "$APP/Contents/MacOS/brioctl-app" | head -n 1; }
wait_for() {  # wait_for WHAT CAMERA NAME VALUE: poll the fake camera for up to 20 s
    n=0
    while [ $n -lt 100 ]; do
        [ "$(fake --camera "$2" get "$3" 2>/dev/null)" = "$4" ] && { echo "ok:   $1 ($3 = $4 on camera $2)"; return 0; }
        sleep 0.2
        n=$((n + 1))
    done
    fail "$1: $3 is '$(fake --camera "$2" get "$3" 2>&1)' on camera $2, wanted '$4'"
    return 1
}
expect() {  # expect WHAT CAMERA NAME VALUE: the value now, no waiting
    got=$(fake --camera "$2" get "$3" 2>&1)
    [ "$got" = "$4" ] && echo "ok:   $1 ($3 = $4 on camera $2)" || fail "$1: $3 is '$got' on camera $2, wanted '$4'"
}
alive() { kill -0 "$PID" 2>/dev/null; }

# the starting point
expect "start" 1 fov 78
expect "start" 1 zoom 115
expect "start" 1 warmth 62
expect "start" 2 zoom 115

echo "--- cold start with a URL"
launch "brioctl://set?fov=65&zoom=130"
wait_for "set by the URL that started the app" 1 fov 65
wait_for "set by the URL that started the app" 1 zoom 130
PID=$(app_pid)
if [ -z "$PID" ]; then fail "the app is not running"; exit 1; fi
echo "ok:   app is running (pid $PID), no window needed"

echo "--- running app"
launch "brioctl://apply?name=warmer"
wait_for "apply a preset" 1 warmth 60

launch "brioctl://set?fov=90&bogus=1&--camera=2"
wait_for "set, unknown keys ignored" 1 fov 90
expect "unknown key did not reach camera 2" 2 zoom 115

launch "brioctl://camera?id=2"
sleep 1
launch "brioctl://set?zoom=222&fov=65"
wait_for "set after choosing camera 2" 2 zoom 222
expect "camera 1 untouched" 1 zoom 130
expect "camera 1 untouched" 1 fov 90

echo "--- URLs that must do nothing"
launch "brioctl://apply?name=../../etc/hosts"
launch "brioctl://factory-reset?yes=1"
launch "brioctl://set?mic=maybe%20not"
launch "https://example.com/"
sleep 2
alive && echo "ok:   still running after refused URLs" || fail "the app died on a refused URL"
expect "nothing changed" 1 fov 90
expect "nothing changed" 1 warmth 60
expect "nothing changed" 1 mic on

echo "--- no LaunchAgent was written"
if [ -z "$(ls -A "$TMP/agents")" ]; then echo "ok:   the agents directory is empty"; else fail "files in the agents directory: $(ls "$TMP/agents")"; fi

echo "--- quit"
kill "$PID"
n=0
while alive && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
if alive; then fail "the app did not quit"; else echo "ok:   quit"; PID=; fi

# what the app logged (informational: the unified log may be unavailable)
log show --last 2m --style compact --predicate "subsystem == \"$BUNDLE_ID\"" 2>/dev/null | grep -v '^Timestamp' | tail -n 12

if [ $FAILED = 0 ]; then echo "smoke test passed"; else echo "smoke test FAILED"; fi
exit $FAILED
