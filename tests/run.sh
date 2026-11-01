#!/bin/sh
# Offline tests for brioctl: the same source built with -DBRIOCTL_FAKE, so it talks to a camera that is read from a
# snapshot file (tests/mxbrio-1.1.394.snap, taken from a real MX Brio with `brioctl snapshot`) instead of USB.
# Every test gets its own copy of the snapshot (camera.snap) and of the other fixtures (generic.snap, extra.snap,
# brio500.snap: see make-fixtures.py) and its own HOME. Run it with `make test`.
set -u

HERE=$(cd "$(dirname "$0")" && pwd) || exit 1
BIN=${BIN:-$HERE/brioctl-fake}
FIXTURE=$HERE/mxbrio-1.1.394.snap
GENERIC=$HERE/generic-uvc.snap EXTRA=$HERE/generic-uvc-extra.snap BRIO500=$HERE/brio500-sim.snap
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/brioctl-test.XXXXXX") || exit 1
trap 'rm -rf "$ROOT"' EXIT
trap 'exit 1' HUP INT TERM

[ -x "$BIN" ] || { echo "Bail out! $BIN is not built (make test builds it)"; exit 1; }
for f in "$FIXTURE" "$GENERIC" "$EXTRA" "$BRIO500"; do
    [ -f "$f" ] || { echo "Bail out! missing $f (make fixtures)"; exit 1; }
done

# Never run these tests against a build that talks to USB: only the fake build says this without BRIOCTL_FAKE.
case $(env -u BRIOCTL_FAKE "$BIN" show 2>&1 < /dev/null) in
*"BRIOCTL_FAKE is not set"*) ;;
*) echo "Bail out! $BIN is not the fake build (-DBRIOCTL_FAKE); refusing to run against a real camera"; exit 1 ;;
esac

# Unit ids in the fixture's descriptor
CT=1 PU=3 INFO=8 VIDEOPIPE=10 PERIPHERAL=11 STATS=21 APP=22

# --- helpers -------------------------------------------------------------------------------------------------------

expect() {  # expect WHAT GOT WANT
    [ "$2" = "$3" ] && return 0
    echo "# $1: got '$2', want '$3'"
    return 1
}

has() {  # has WHAT TEXT STRING: TEXT contains STRING
    printf '%s\n' "$2" | grep -qF -- "$3" && return 0
    echo "# $1: '$3' not found in: $2"
    return 1
}

hasnt() {  # hasnt WHAT TEXT STRING
    printf '%s\n' "$2" | grep -qF -- "$3" || return 0
    echo "# $1: '$3' unexpectedly found in: $2"
    return 1
}

noline() {  # noline WHAT TEXT NAME: no line of TEXT starts with "NAME "
    printf '%s\n' "$2" | grep -q "^$3 " || return 0
    echo "# $1: a '$3' line is there: $2"
    return 1
}

matches() {  # matches WHAT TEXT REGEX (extended)
    printf '%s\n' "$2" | grep -qE -- "$3" && return 0
    echo "# $1: /$3/ does not match: $2"
    return 1
}

# edit_reg UNIT SEL KEY VALUE: change one field (info, len, cur, min, ...) of a register in this test's snapshot
edit_reg() {
    awk -v u="$1" -v s="$2" -v k="$3" -v v="$4" '
        $1 == "reg" && $2 == u && $3 == s { for (i = 4; i < NF; i++) if ($i == k) $(i + 1) = v }
        { print }' "$BRIOCTL_FAKE" > "$BRIOCTL_FAKE.new" && mv "$BRIOCTL_FAKE.new" "$BRIOCTL_FAKE"
}

# count SET_CUR lines in a trace file
setcurs() { grep -c '^fake SET_CUR' "$1"; }

# --- tests ---------------------------------------------------------------------------------------------------------

t_show() {
    out=$("$BIN" 2>&1); rc=$?
    expect "exit status" "$rc" 0 || return 1
    has "firmware" "$out" "firmware 1.1.394" || return 1
    has "serial is masked in the fixture" "$out" "serial 000000000000" || return 1
    for name in fov zoom smooth; do
        matches "$name line" "$out" "^  $name +[^ ]+ +default " || return 1
    done
    has "status" "$out" "video       on, 1920x1080" || return 1
    has "auto marker" "$out" "* set automatically right now" || return 1
}

t_json() {
    python3 -I -c pass >/dev/null 2>&1 || { echo "# python3 not available"; return 77; }
    "$BIN" --json > out.json || return 1
    python3 -I -m json.tool < out.json > /dev/null || return 1
    python3 -I - out.json <<'EOF' || return 1
import json, sys
d = json.load(open(sys.argv[1]))
for key in ("device", "status", "settings", "micgain"):
    assert key in d, "missing " + key
want = {"model": "MX Brio", "firmware": "1.1.394", "serial": "000000000000", "colour": 2}  # the keys of 1.0
assert all(d["device"][k] == v for k, v in want.items()), d["device"]
assert d["status"]["video"] == {"on": True, "width": 1920, "height": 1080}
assert d["status"]["rightsight"]["stored"] is True and d["status"]["led"] is True
s = d["settings"]
assert all(s["fov"][k] == v for k, v in {"value": "78", "default": "90", "auto": False}.items()), s["fov"]
assert s["zoom"]["value"] == 115 and isinstance(s["zoom"]["value"], int)
assert s["exposure"]["auto"] is True and s["priority"]["default"] is None
assert d["micgain"] == 0.2785
EOF
}

t_set_and_get() {
    out=$("$BIN" fov 65 2>&1); rc=$?
    expect "fov 65 status" "$rc" 0 || return 1
    expect "fov 65 output" "$out" "fov 65" || return 1
    expect "get fov" "$("$BIN" get fov)" 65 || return 1
    has "a later show sees it" "$("$BIN" 2>&1)" "fov         65" || return 1
}

t_rejects_bad_values() {
    out=$("$BIN" fov 70 2>&1); rc=$?
    expect "fov 70 status" "$rc" 1 || return 1
    has "fov 70 message" "$out" "bad value 70" || return 1
    out=$("$BIN" zoom 500 2>&1); rc=$?
    expect "zoom 500 status" "$rc" 1 || return 1
    has "zoom 500 message" "$out" "out of range" || return 1
    expect "zoom unchanged" "$("$BIN" get zoom)" 115 || return 1
    expect "fov unchanged" "$("$BIN" get fov)" 78
}

t_refuses_auto_controls() {
    grep -q '^reg 1 4 info 0f' "$BRIOCTL_FAKE" || { echo "# fixture has no auto-driven exposure"; return 1; }
    out=$("$BIN" exposure 500 2>&1); rc=$?
    expect "exposure status" "$rc" 1 || return 1
    has "exposure message" "$out" "set automatically right now" || return 1
    expect "exposure unchanged" "$("$BIN" get exposure)" 1250
}

t_read_modify_write() {
    "$BIN" tilt 5 > /dev/null || return 1
    BRIOCTL_FAKE_TRACE=1 "$BIN" pan 10 > /dev/null 2> trace || return 1
    expect "tilt kept" "$("$BIN" get tilt)" 5 || return 1
    expect "pan set" "$("$BIN" get pan)" 10 || return 1
    # pan 36000 = 0x8ca0, tilt 18000 = 0x4650: the write carries both
    has "one 8-byte write" "$(cat trace)" "fake SET_CUR unit $CT sel 13 a08c000050460000"
}

t_xu_length_check() {
    edit_reg "$VIDEOPIPE" 5 len 0002
    out=$(BRIOCTL_FAKE_TRACE=1 "$BIN" fov 78 2>&1); rc=$?
    expect "fov 78 status" "$rc" 1 || return 1
    has "message" "$out" "unexpected control size" || return 1
    out=$(BRIOCTL_FAKE_TRACE=1 "$BIN" fov 65 2>&1); rc=$?
    expect "fov 65 status" "$rc" 1 || return 1
    hasnt "no write" "$out" "fake SET_CUR"
}

t_save_skips_unusable_values() {
    "$BIN" save "$PWD/a" > /dev/null || return 1
    saved=$(cat a)
    has "fov saved" "$saved" "fov 78" || return 1
    has "micgain saved" "$saved" "micgain 0.2785" || return 1
    has "brightness saved" "$saved" "brightness 128" || return 1
    for name in exposure gain wb focus; do  # driven by auto exposure, white balance and autofocus
        noline "$name is auto-driven" "$saved" "$name" || return 1
    done
    edit_reg "$PU" 2 cur 0001  # brightness 256, the maximum is 255
    "$BIN" save "$PWD/b" > /dev/null || return 1
    saved=$(cat b)
    noline "brightness out of range" "$saved" brightness || return 1
    has "the rest is still saved" "$saved" "contrast 128"
}

t_apply_puts_mic_last() {
    printf 'mic off\nfov 65\nzoom 120\n' > settings
    "$BIN" apply "$PWD/settings" > out 2> trace || return 1
    expect "output order" "$(tr '\n' ' ' < out)" "fov 65 zoom 120 mic off " || return 1
    BRIOCTL_FAKE_TRACE=1 "$BIN" apply "$PWD/settings" > /dev/null 2> trace || return 1  # nothing to change now
    expect "second apply writes nothing" "$(setcurs trace)" 0 || return 1
    printf 'mic on\nzoom 130\n' > settings
    BRIOCTL_FAKE_TRACE=1 "$BIN" apply "$PWD/settings" > /dev/null 2> trace || return 1
    expect "write order" "$(grep -o 'unit [0-9]* sel [0-9]*' trace | tr '\n' ' ')" \
        "unit $CT sel 11 unit $PERIPHERAL sel 16 " || return 1
}

t_skips_equal_values() {
    out=$(BRIOCTL_FAKE_TRACE=1 "$BIN" zoom 115 2> trace); rc=$?
    expect "status" "$rc" 0 || return 1
    expect "output" "$out" "zoom 115" || return 1
    expect "no SET_CUR for the current value" "$(setcurs trace)" 0 || return 1
    out=$(BRIOCTL_FAKE_TRACE=1 "$BIN" mic on 2> trace); rc=$?
    expect "mic status" "$rc" 0 || return 1
    expect "mic output" "$out" "mic on" || return 1
    expect "no restart for an unchanged mic" "$(setcurs trace)" 0 || return 1
    BRIOCTL_FAKE_TRACE=1 "$BIN" zoom 120 > /dev/null 2> trace || return 1
    expect "a real change is written once" "$(setcurs trace)" 1
}

t_preset() {
    out=$("$BIN" apply colorboost 2>&1); rc=$?
    expect "status" "$rc" 0 || return 1
    expect "output" "$out" "saturation 255" || return 1
    expect "saturation" "$("$BIN" get saturation)" 255
}

t_version() {
    for cmd in --version version; do
        out=$("$BIN" $cmd); rc=$?
        expect "$cmd status" "$rc" 0 || return 1
        if [ -n "${VERSION:-}" ]; then expect "$cmd" "$out" "brioctl $VERSION" || return 1
        else matches "$cmd" "$out" '^brioctl [^ ]+$' || return 1
        fi
    done
}

t_dump() {
    out=$("$BIN" dump 2>&1); rc=$?
    expect "status" "$rc" 0 || return 1
    has "camera terminal" "$out" "camera terminal $CT" || return 1
    has "videopipe" "$out" "extension unit $VIDEOPIPE  49e40215-f434-47fe-b158-0e885023e51b" || return 1
    has "a register" "$out" "sel  5  get set len 1"
}

t_snapshot_round_trip() {
    "$BIN" snapshot "$PWD/copy" > /dev/null || return 1
    "$BIN" snapshot > stdout.snap || return 1
    grep -v '^#' "$FIXTURE" > want
    grep -v '^#' copy > got
    cmp -s want got || { echo "# snapshot of the fake differs from the fixture"; diff want got | head -5; return 1; }
    grep -v '^#' stdout.snap | cmp -s - want || { echo "# stdout snapshot differs"; return 1; }
    head -1 copy | grep -q '^# brioctl snapshot 1, firmware 1.1.394, ' || { echo "# bad header"; return 1; }
}

t_snapshot_never_reads_factory_reset() {
    sed "s/^\(reg $INFO 12 .*\)$/\1 cur aa/" "$BRIOCTL_FAKE" > with-cur && mv with-cur "$BRIOCTL_FAKE"
    grep -q "^reg $INFO 12 .* cur aa" "$BRIOCTL_FAKE" || { echo "# could not plant a value"; return 1; }
    BRIOCTL_FAKE_TRACE=2 "$BIN" snapshot > out.snap 2> trace || return 1
    out=$(grep "^reg $INFO 12 " out.snap)
    matches "info 12 line" "$out" '^reg 8 12 info 03 len 0001$' || return 1
    has "info 12 is asked" "$(cat trace)" "fake GET_INFO unit $INFO sel 12" || return 1
    expect "no value request for info 12" "$(grep -cE "^fake GET_(CUR|MIN|MAX|RES|DEF) unit $INFO sel 12\$" trace)" 0
}

t_snapshot_masks_serial() {
    hex=5445535453455249414c3031  # TESTSERIAL01, a made-up serial for this test's own copy of the fixture
    edit_reg "$INFO" 7 cur $hex
    has "the fake camera reports it" "$("$BIN" 2>&1)" "serial TESTSERIAL01" || return 1
    "$BIN" snapshot > out.snap || return 1
    "$BIN" snapshot "$PWD/file.snap" > /dev/null || return 1
    for f in out.snap file.snap; do
        hasnt "$f serial in hex" "$(cat $f)" $hex || return 1
        hasnt "$f serial" "$(cat $f)" TESTSERIAL01 || return 1
        has "$f mask" "$(grep "^reg $INFO 7 " $f)" "cur 303030303030303030303030" || return 1
    done
}

t_get() {
    expect "get micgain" "$("$BIN" get micgain)" 0.2785 || return 1
    expect "get pan" "$("$BIN" get pan)" 0 || return 1
    out=$("$BIN" get nosuch 2>&1); rc=$?
    expect "unknown status" "$rc" 1 || return 1
    has "unknown message" "$out" "unknown setting: nosuch" || return 1
    "$BIN" get > /dev/null 2>&1; rc=$?
    expect "missing name" "$rc" 2 || return 1
    sed "/^reg $PU 7 /d" "$BRIOCTL_FAKE" > no-sat && mv no-sat "$BRIOCTL_FAKE"  # saturation: the camera stalls
    out=$("$BIN" get saturation 2>&1); rc=$?
    expect "unreadable status" "$rc" 1 || return 1
    expect "nothing on stdout" "$("$BIN" get saturation 2>/dev/null)" ""
}

t_micgain_persists() {
    out=$("$BIN" micgain 0.5 2>&1); rc=$?
    expect "status" "$rc" 0 || return 1
    expect "output" "$out" "micgain 0.5000" || return 1
    expect "next process" "$("$BIN" get micgain)" 0.5000
}

t_negative_pan() {
    out=$("$BIN" pan -10 2>&1); rc=$?
    expect "pan -10 status" "$rc" 0 || return 1
    expect "pan -10 output" "$out" "pan -10" || return 1
    expect "get pan" "$("$BIN" get pan)" -10 || return 1
    BRIOCTL_FAKE_TRACE=1 "$BIN" pan -10 > /dev/null 2> trace || return 1
    expect "the same negative value sends no SET_CUR" "$(setcurs trace)" 0 || return 1
    # pan -36000 = 0xffff7360, tilt -18000 = 0xffffb9b0: both are in the write
    BRIOCTL_FAKE_TRACE=1 "$BIN" tilt -5 > /dev/null 2> trace || return 1
    has "one 8-byte write" "$(cat trace)" "fake SET_CUR unit $CT sel 13 6073ffffb0b9ffff" || return 1
    expect "pan kept" "$("$BIN" get pan)" -10
}

t_micgain_rejects_bad_values() {
    for bad in nan NaN inf -inf 0x1p-3 0x.8 1e-1 +0.5 -0.1 1.5 . abc 0.5x ""; do
        out=$("$BIN" micgain "$bad" 2>&1); rc=$?
        expect "micgain '$bad' status" "$rc" 1 || return 1
        has "micgain '$bad' message" "$out" "bad value" || return 1
    done
    expect "unchanged" "$("$BIN" get micgain)" 0.2785
}

t_micgain_skips_equal() {
    out=$(BRIOCTL_FAKE_TRACE=1 "$BIN" micgain 0.2785 2> trace); rc=$?
    expect "status" "$rc" 0 || return 1
    expect "output" "$out" "micgain 0.2785" || return 1
    hasnt "no write for the current value" "$(cat trace)" SET_MICGAIN || return 1
    out=$(BRIOCTL_FAKE_TRACE=1 "$BIN" micgain 0.27855 2> trace)  # less than 0.0001 away
    expect "close value shows the current one" "$out" "micgain 0.2785" || return 1
    hasnt "no write for a close value" "$(cat trace)" SET_MICGAIN || return 1
    out=$(BRIOCTL_FAKE_TRACE=1 "$BIN" micgain 0.2795 2> trace)
    expect "a real change" "$out" "micgain 0.2795" || return 1
    has "is written" "$(cat trace)" "fake SET_MICGAIN 0.2795"
}

t_micgain_not_a_number() {
    sed 's/^micgain .*/micgain nan/' "$BRIOCTL_FAKE" > nan && mv nan "$BRIOCTL_FAKE"
    out=$("$BIN" get micgain 2>&1); rc=$?
    expect "get status" "$rc" 1 || return 1
    expect "get stdout" "$("$BIN" get micgain 2>/dev/null)" "" || return 1
    has "get message" "$out" "micgain" || return 1
    has "show" "$("$BIN" 2>&1)" "micgain     ?" || return 1
    "$BIN" save "$PWD/s" > /dev/null || return 1
    noline "save" "$(cat s)" micgain || return 1
    python3 -I -c pass >/dev/null 2>&1 || { echo "# python3 not available"; return 77; }
    "$BIN" --json | python3 -I -c 'import json, sys; assert json.load(sys.stdin)["micgain"] is None'
}

t_json_without_stats_and_app() {
    python3 -I -c pass >/dev/null 2>&1 || { echo "# python3 not available"; return 77; }
    sed "/^reg $STATS /d;/^reg $APP /d" "$BRIOCTL_FAKE" > fewer && mv fewer "$BRIOCTL_FAKE"
    "$BIN" --json > out.json; rc=$?
    expect "status" "$rc" 0 || return 1
    python3 -I - out.json <<'EOF' || return 1
import json, sys
d = json.load(open(sys.argv[1]))
assert d["status"]["video"] is None and d["status"]["rightsight"] is None, d["status"]
assert d["status"]["led"] is True and d["settings"]["fov"]["value"] == "78"
EOF
}

t_dump_leaves_service_registers() {
    # Test Debug (9), AIT custom (6), the unknown unit (2) and info 12 and 13, all with values dump must not ask for
    cat >> "$BRIOCTL_FAKE" <<EOF
reg 9 1 info 03 len 0004 cur 01020304 min 00000000 max ffffffff res 01000000 def 00000000
reg 9 5 info 01 len 0001 cur aa
reg 6 1 info 03 len 0002 cur 0102 min 0000 max ffff
reg 2 1 info 03 len 0001 cur 55
reg 8 13 info 02 len 0004 cur 11223344
EOF
    BRIOCTL_FAKE_TRACE=2 "$BIN" dump > out 2> trace; rc=$?
    expect "status" "$rc" 0 || return 1
    expect "service registers" "$(grep -c 'service register' out)" 6 || return 1
    hasnt "no value of Test Debug" "$(cat out)" 01020304 || return 1
    has "unit 9 is asked" "$(cat trace)" "fake GET_INFO unit 9 sel 1" || return 1
    has "length too" "$(cat trace)" "fake GET_LEN unit 9 sel 1" || return 1
    expect "no value request to units 2, 6, 9" \
        "$(grep -cE '^fake GET_(CUR|MIN|MAX|RES|DEF) unit (2|6|9) ' trace)" 0 || return 1
    expect "no value request to info 12, 13" \
        "$(grep -cE "^fake GET_(CUR|MIN|MAX|RES|DEF) unit $INFO sel (12|13)\$" trace)" 0 || return 1
    has "other registers are still read" "$(cat trace)" "fake GET_CUR unit $VIDEOPIPE sel 5" || return 1
    has "and shown" "$(cat out)" "cur=01  min=00  max=ff"
}

t_dump_bounds_checks_descriptors() {
    # nin = 0xff in the Test Debug unit: its pin list and bmControls would be far outside the descriptor
    grep -q 'c8ec8d116010303' "$BRIOCTL_FAKE" || { echo "# fixture has no Test Debug unit"; return 1; }
    sed 's/c8ec8d116010303/c8ec8d116ff0303/' "$BRIOCTL_FAKE" > bad && mv bad "$BRIOCTL_FAKE"
    out=$("$BIN" dump 2>&1); rc=$?
    expect "status" "$rc" 0 || return 1
    has "unit 9 is reported" "$out" "extension unit 9" || return 1
    has "and cut off" "$out" "descriptor cut off" || return 1
    has "the others still are listed" "$out" "extension unit $VIDEOPIPE" || return 1
    # the configuration descriptor ends in the middle of a unit
    cp "$FIXTURE" "$BRIOCTL_FAKE"
    sed '/^descriptor/ s/.\{40\}$//' "$BRIOCTL_FAKE" > short && mv short "$BRIOCTL_FAKE"
    "$BIN" dump > /dev/null 2>&1; rc=$?
    expect "short descriptor status" "$rc" 0 || return 1
    "$BIN" > /dev/null 2>&1
}

t_bad_snapshot_line() {
    printf '# x\nreg 1 2 cur zz\n' > bad.snap
    out=$(BRIOCTL_FAKE=$PWD/bad.snap "$BIN" 2>&1); rc=$?
    expect "status" "$rc" 1 || return 1
    has "the whole line" "$out" "bad snapshot line: reg 1 2 cur zz"
}

t_fake_save_failure() {
    mkdir camera.snap.tmp  # fopen of the temporary file fails
    out=$("$BIN" zoom 130 2>&1); rc=$?
    expect "status" "$rc" 1 || return 1
    has "message" "$out" "camera.snap.tmp"
}

t_snapshot_nothing_answers() {
    grep -v '^reg ' "$BRIOCTL_FAKE" > bare && mv bare "$BRIOCTL_FAKE"
    out=$("$BIN" snapshot 2>&1 > /dev/null); rc=$?
    expect "status" "$rc" 1 || return 1
    has "message" "$out" "no register" || return 1
    "$BIN" snapshot "$PWD/none.snap" > /dev/null 2>&1; rc=$?
    expect "status with a file" "$rc" 1 || return 1
    [ ! -e none.snap ] || { echo "# an empty snapshot was left behind"; return 1; }
}

# --- watch: the apply that runs when the camera connects and when video starts (hidden --test-reapply) -------------

t_reapply_prints_only_changes() {
    printf 'zoom 130\nfov 65\nbrightness 128\nmic on\nmicgain 0.2785\n' > settings
    out=$("$BIN" --test-reapply "$PWD/settings" 2>&1); rc=$?
    expect "status" "$rc" 0 || return 1
    has "zoom is printed" "$out" "zoom 130" || return 1
    has "fov is printed" "$out" "fov 65" || return 1
    has "summary" "$out" "applied (2 changed)" || return 1
    hasnt "brightness is already 128" "$out" brightness || return 1
    hasnt "mic is already on" "$out" "mic on" || return 1
    hasnt "micgain is already there" "$out" micgain || return 1
    printf 'micgain 0.5\n' > settings
    out=$("$BIN" --test-reapply "$PWD/settings" 2>&1)
    has "a micgain change is printed" "$out" "micgain 0.5000" || return 1
    out=$("$BIN" --test-reapply "$PWD/settings" 2>&1)
    has "nothing left to change" "$out" "applied (0 changed)" || return 1
    hasnt "and nothing printed" "$out" "micgain 0.5"
}

t_reapply_never_changes_mic_in_video() {
    printf 'mic off\nzoom 130\n' > settings
    BRIOCTL_FAKE_TRACE=1 "$BIN" --test-reapply "$PWD/settings" video > out 2> trace; rc=$?
    expect "status" "$rc" 0 || return 1
    has "video start is logged" "$(cat out)" "video started" || return 1
    has "zoom is applied" "$(cat out)" "zoom 130" || return 1
    has "mic is reported" "$(cat out)" "mic: not changed while video is on" || return 1
    expect "only zoom is written" "$(grep -o 'unit [0-9]* sel [0-9]*' trace | tr '\n' ' ')" \
        "unit $CT sel 11 " || return 1
    expect "mic is still on" "$("$BIN" get mic)" on || return 1
    printf 'mic on\nzoom 140\n' > settings  # the camera already has this mic value
    "$BIN" --test-reapply "$PWD/settings" video > out 2>&1
    hasnt "no report for an equal mic" "$(cat out)" "mic:" || return 1
    # when the camera has just connected there is no video: mic is applied, last
    printf 'mic off\nzoom 150\n' > settings
    BRIOCTL_FAKE_TRACE=1 "$BIN" --test-reapply "$PWD/settings" > out 2> trace || return 1
    expect "connect writes mic last" "$(grep -o 'unit [0-9]* sel [0-9]*' trace | tr '\n' ' ')" \
        "unit $CT sel 11 unit $PERIPHERAL sel 16 " || return 1
    expect "mic is off" "$("$BIN" get mic)" off
}

t_reapply_skips_framing_at_the_desk() {
    edit_reg "$INFO" 14 cur 01  # Show Mode is active: the camera is tilted and shows the desk
    printf 'fov 65\nzoom 130\npan 5\ntilt 5\nbrightness 100\nmic on\n' > settings
    BRIOCTL_FAKE_TRACE=1 "$BIN" --test-reapply "$PWD/settings" > out 2> trace; rc=$?
    expect "status" "$rc" 0 || return 1
    expect "only brightness is written" "$(grep -o 'unit [0-9]* sel [0-9]*' trace | tr '\n' ' ')" \
        "unit $PU sel 2 " || return 1
    has "one line about the skipped ones" "$(cat out)" "left to the firmware: fov zoom pan tilt" || return 1
    expect "that line is there once" "$(grep -c 'left to the firmware' out)" 1 || return 1
    printf 'fov 65\nzoom 130\n' > settings
    BRIOCTL_FAKE_TRACE=1 "$BIN" --test-reapply "$PWD/settings" video > out 2> trace || return 1
    expect "video start at the desk writes nothing" "$(setcurs trace)" 0 || return 1
    has "and says so" "$(cat out)" "left to the firmware: fov zoom" || return 1
    # a manual apply is not changed
    BRIOCTL_FAKE_TRACE=1 "$BIN" apply "$PWD/settings" > /dev/null 2> trace || return 1
    expect "apply still writes framing" "$(setcurs trace)" 2 || return 1
    edit_reg "$INFO" 14 cur 00  # back from the desk
    printf 'zoom 160\n' > settings
    "$BIN" --test-reapply "$PWD/settings" > out 2>&1 || return 1
    has "framing is applied again" "$(cat out)" "zoom 160"
}

t_video_start_after_unplug() {
    printf 'zoom 130\nmic off\n' > settings
    out=$(BRIOCTL_FAKE_ABSENT=1 BRIOCTL_FAKE_TRACE=1 "$BIN" --test-reapply "$PWD/settings" video 2>&1); rc=$?
    expect "status" "$rc" 0 || return 1
    expect "nothing is logged or written" "$out" "" || return 1
    expect "zoom unchanged" "$("$BIN" get zoom)" 115
}

t_needs_a_snapshot() {
    out=$(env -u BRIOCTL_FAKE "$BIN" 2>&1); rc=$?
    expect "status" "$rc" 1 || return 1
    has "message" "$out" "BRIOCTL_FAKE is not set"
}

# --- cameras: list, choice, --camera ------------------------------------------------------------------------------

# three_cameras: a generic camera, the MX Brio and another generic camera, with serials GENERIC0001, BRIOSERIAL1 and
# GENERIC0002, at locations 0x100000, 0x200000 and 0x300000
three_cameras() {
    sed 's/^serial .*/serial GENERIC0001/' generic.snap > g1.snap
    sed 's/^serial .*/serial BRIOSERIAL1/' camera.snap > brio.snap
    sed 's/^serial .*/serial GENERIC0002/' generic.snap > g2.snap
    BRIOCTL_FAKE=$PWD/g1.snap:$PWD/brio.snap:$PWD/g2.snap
    export BRIOCTL_FAKE
}

which_camera() {  # which_camera ARGS...: the device line of the snapshot of the camera brioctl chose
    "$BIN" "$@" snapshot 2>&1 | grep '^device'
}

t_list() {
    three_cameras
    out=$("$BIN" list); rc=$?
    expect "status" "$rc" 0 || return 1
    matches "header" "$out" '^# +id +name +model +support +serial +location$' || return 1
    matches "generic row" "$out" '^1 +1234:5678 +Generic UVC +- +standard +GENERIC0001 +0x100000$' || return 1
    matches "mx brio row" "$out" '^2 +046d:0944 +MX Brio +MX Brio +full +BRIOSERIAL1 +0x200000$' || return 1
    matches "third row" "$out" '^3 +1234:5678 +Generic UVC +- +standard +GENERIC0002 +0x300000$' || return 1
    want='{"cameras":[{"index":1,"vid":"1234","pid":"5678","name":"Generic UVC","model":null,"support":"standard",'
    want="$want"'"serial":"GENERIC0001","location":"0x100000"},{"index":2,"vid":"046d","pid":"0944","name":"MX Brio",'
    want="$want"'"model":"MX Brio","support":"full","serial":"BRIOSERIAL1","location":"0x200000"},{"index":3,'
    want="$want"'"vid":"1234","pid":"5678","name":"Generic UVC","model":null,"support":"standard","serial":"GENERIC0002",'
    want="$want"'"location":"0x300000"}]}'
    expect "json" "$("$BIN" list --json)" "$want" || return 1
    BRIOCTL_FAKE=$PWD/brio500.snap
    has "experimental" "$("$BIN" list)" "046d:0943  Brio 500" || return 1
    has "experimental level" "$("$BIN" list)" "experimental" || return 1
    BRIOCTL_FAKE=:
    expect "no camera" "$("$BIN" list)" "no UVC camera found" || return 1
    expect "no camera, json" "$("$BIN" list --json)" '{"cameras":[]}' || return 1
    "$BIN" list extra > /dev/null 2>&1; rc=$?
    expect "list takes only --json" "$rc" 2
}

t_default_camera() {
    # one camera: that one
    expect "one camera" "$(which_camera)" "device 046d 0944" || return 1
    three_cameras
    # several, one of them known to brioctl: that one
    expect "the only known camera" "$(which_camera)" "device 046d 0944" || return 1
    # several, none known: exit 2 and the list
    BRIOCTL_FAKE=$PWD/g1.snap:$PWD/g2.snap
    out=$("$BIN" 2>&1 > /dev/null); rc=$?
    expect "status" "$rc" 2 || return 1
    has "message" "$out" "several cameras: choose one with --camera" || return 1
    has "list" "$out" "GENERIC0002" || return 1
    "$BIN" get brightness > /dev/null 2>&1; rc=$?
    expect "get needs the choice too" "$rc" 2 || return 1
    # two known cameras: also a choice
    BRIOCTL_FAKE=$PWD/camera.snap:$PWD/brio500.snap
    "$BIN" > /dev/null 2>&1; rc=$?
    expect "two known cameras" "$rc" 2 || return 1
    BRIOCTL_FAKE=:
    out=$("$BIN" 2>&1); rc=$?
    expect "no camera status" "$rc" 1 || return 1
    has "no camera message" "$out" "no UVC camera found"
}

t_camera_option() {
    three_cameras
    for id in 1 GENERIC0001 0x100000 0X100000; do
        expect "--camera $id" "$(which_camera --camera "$id")" "device 1234 5678" || return 1
    done
    expect "by index" "$(which_camera --camera 2)" "device 046d 0944" || return 1
    expect "by serial" "$(which_camera --camera BRIOSERIAL1)" "device 046d 0944" || return 1
    expect "serial in any case" "$(which_camera --camera briOserial1)" "device 046d 0944" || return 1
    expect "by location" "$(which_camera --camera 0x200000)" "device 046d 0944" || return 1
    expect "--camera=ID" "$(which_camera --camera=0x300000)" "device 1234 5678" || return 1
    # the option can stand after the command too, and every command takes it
    expect "after the command" "$("$BIN" snapshot --camera 2 2>&1 | grep '^device')" "device 046d 0944" || return 1
    expect "get" "$("$BIN" --camera 2 get zoom)" 115 || return 1
    "$BIN" --camera 2 zoom 130 > /dev/null || return 1
    expect "set went to camera 2" "$("$BIN" --camera 2 get zoom)" 130 || return 1
    expect "and not to camera 1" "$("$BIN" --camera 1 get zoom)" 115 || return 1
    "$BIN" --camera 2 save "$PWD/s" > /dev/null || return 1
    has "save" "$(cat s)" "zoom 130" || return 1
    printf 'zoom 140\n' > z
    "$BIN" --camera 1 apply "$PWD/z" > /dev/null || return 1
    expect "apply to camera 1" "$("$BIN" --camera 1 get zoom)" 140 || return 1
    expect "camera 2 untouched" "$("$BIN" --camera 2 get zoom)" 130 || return 1
    has "dump" "$("$BIN" --camera 2 dump)" "extension unit 10" || return 1
    hasnt "dump of the generic camera" "$("$BIN" --camera 1 dump)" "extension unit" || return 1
    "$BIN" --camera 2 > /dev/null || return 1
    "$BIN" --camera 2 --json > /dev/null || return 1
    "$BIN" --camera 2 defaults > /dev/null || return 1
    # errors
    out=$("$BIN" --camera 9 2>&1); rc=$?
    expect "no such index" "$rc" 2 || return 1
    has "message" "$out" "no camera matches 9" || return 1
    has "list" "$out" "BRIOSERIAL1" || return 1
    "$BIN" --camera 0x400000 > /dev/null 2>&1; rc=$?
    expect "no such location" "$rc" 2 || return 1
    "$BIN" --camera 0x > /dev/null 2>&1; rc=$?
    expect "bad location" "$rc" 2 || return 1
    "$BIN" --camera > /dev/null 2>&1; rc=$?
    expect "missing id" "$rc" 2 || return 1
    sed 's/^serial .*/serial BRIOSERIAL1/' generic.snap > dup.snap
    BRIOCTL_FAKE=$PWD/brio.snap:$PWD/dup.snap
    out=$("$BIN" --camera BRIOSERIAL1 2>&1); rc=$?
    expect "same serial twice" "$rc" 2 || return 1
    has "same serial message" "$out" "matches several cameras"
}

t_snapshot_device_lines() {
    "$BIN" snapshot > out.snap || return 1
    has "device" "$(cat out.snap)" "device 046d 0944" || return 1
    has "name" "$(cat out.snap)" "name MX Brio" || return 1
    has "serial is masked" "$(cat out.snap)" "serial 000000000000" || return 1
    sed 's/^serial .*/serial REALSERIAL1/;s/^name .*/name Some Camera Name/;s/^device .*/device 1234 abcd/' camera.snap > other.snap
    out=$(BRIOCTL_FAKE=$PWD/other.snap "$BIN" snapshot) || return 1
    has "other device" "$out" "device 1234 abcd" || return 1
    has "name with spaces" "$out" "name Some Camera Name" || return 1
    has "same length mask" "$out" "serial 00000000000" || return 1
    hasnt "real serial" "$out" REALSERIAL1 || return 1
    # a snapshot from before 1.1 has none of these lines: it is an MX Brio
    grep -v '^\(device\|name\|serial\) ' camera.snap > old.snap
    out=$(BRIOCTL_FAKE=$PWD/old.snap "$BIN" list) || return 1
    matches "old snapshot" "$out" '^1 +046d:0944 +MX Brio +MX Brio +full +- +0x100000$' || return 1
    out=$(BRIOCTL_FAKE=$PWD/old.snap "$BIN" snapshot) || return 1
    has "old snapshot gets a device line" "$out" "device 046d 0944" || return 1
    has "and a name" "$out" "name MX Brio" || return 1
    BRIOCTL_FAKE=$PWD/old.snap "$BIN" zoom 130 > /dev/null || return 1
    hasnt "the file stays as it was" "$(cat old.snap)" "device" || return 1
    printf 'device 046d\n' > bad.snap
    BRIOCTL_FAKE=$PWD/bad.snap "$BIN" list > /dev/null 2>&1; rc=$?
    expect "bad device line" "$rc" 1
}

t_camera_survives_writes() {
    three_cameras
    "$BIN" --camera 1 brightness 100 > /dev/null || return 1
    has "device line kept" "$(cat g1.snap)" "device 1234 5678" || return 1
    has "name kept" "$(cat g1.snap)" "name Generic UVC" || return 1
    has "serial kept" "$(cat g1.snap)" "serial GENERIC0001" || return 1
    expect "listed the same" "$("$BIN" list --json | grep -c GENERIC0001)" 1
}

# --- cameras other than the MX Brio -----------------------------------------------------------------------------------

t_generic_camera() {
    export BRIOCTL_FAKE=$PWD/generic.snap
    out=$("$BIN" 2>&1); rc=$?
    expect "status" "$rc" 0 || return 1
    has "name" "$out" "Generic UVC  1234:5678" || return 1
    has "support level" "$out" "standard UVC controls only" || return 1
    for name in zoom pan tilt ae exposure brightness backlight flicker wb focus; do
        matches "$name line" "$out" "^  $name +[^ ]+ +default " || return 1
    done
    for name in fov showmode hdr warmth tint vibrance expcomp mic smooth micgain roll iris hue hueauto gamma privacy; do
        noline "$name is not there" "$out" "$name" || return 1
    done
    hasnt "no Logitech group" "$out" "mapped from Logi Tune" || return 1
    hasnt "no status" "$out" "Status (read-only)" || return 1
    hasnt "no microphone section" "$out" "Microphone" || return 1
    has "the camera's own range" "$out" "3-2047" || return 1
    # the Logitech controls are not here, and nothing is written to an extension unit
    for name in fov showmode warmth tint mic smooth; do
        out=$(BRIOCTL_FAKE_TRACE=1 "$BIN" $name 1 2>&1); rc=$?
        expect "$name status" "$rc" 1 || return 1
        has "$name message" "$out" "control not found on this camera" || return 1
        hasnt "$name write" "$out" "fake SET_CUR" || return 1
    done
    out=$("$BIN" get fov 2>&1); rc=$?
    expect "get fov status" "$rc" 1 || return 1
    has "get fov message" "$out" "control not found on this camera" || return 1
    "$BIN" get micgain > /dev/null 2>&1; rc=$?
    expect "get micgain status" "$rc" 1 || return 1
    "$BIN" micgain 0.5 > /dev/null 2>&1; rc=$?
    expect "micgain status" "$rc" 1 || return 1
    out=$(BRIOCTL_FAKE_TRACE=1 "$BIN" factory-reset --yes 2>&1); rc=$?
    expect "factory-reset status" "$rc" 1 || return 1
    has "factory-reset message" "$out" "only for the MX Brio" || return 1
    hasnt "no reset written" "$out" "fake SET_CUR" || return 1
    # standard controls work
    expect "brightness" "$("$BIN" brightness 100)" "brightness 100" || return 1
    expect "read back" "$("$BIN" get brightness)" 100 || return 1
    hasnt "dump has no extension units" "$("$BIN" dump)" "extension unit"
}

t_hdr_or_backlight() {
    # the MX Brio calls it hdr (on/off); both names work
    expect "hdr" "$("$BIN" hdr off)" "hdr off" || return 1
    expect "backlight on the MX Brio" "$("$BIN" get backlight)" off || return 1
    expect "backlight sets it" "$("$BIN" backlight on)" "hdr on" || return 1
    expect "get hdr" "$("$BIN" get hdr)" on || return 1
    matches "show says hdr" "$("$BIN" 2>&1)" "^  hdr +on +default on +HDR" || return 1
    noline "show has no backlight" "$("$BIN" 2>&1)" backlight || return 1
    # a camera without HDR has a numeric backlight compensation
    export BRIOCTL_FAKE=$PWD/generic.snap
    matches "show says backlight" "$("$BIN" 2>&1)" "^  backlight +1 +default 1 +0-1 +backlight compensation" || return 1
    expect "backlight" "$("$BIN" backlight 0)" "backlight 0" || return 1
    expect "hdr on a generic camera" "$("$BIN" hdr 1)" "backlight 1" || return 1
    expect "get hdr" "$("$BIN" get hdr)" 1 || return 1
    "$BIN" save "$PWD/s" > /dev/null || return 1
    has "saved as backlight" "$(cat s)" "backlight 1" || return 1
    noline "not as hdr" "$(cat s)" hdr
}

t_experimental_camera() {
    export BRIOCTL_FAKE=$PWD/brio500.snap
    out=$("$BIN" 2>&1); rc=$?
    expect "status" "$rc" 0 || return 1
    has "name" "$out" "Brio 500  046d:0943" || return 1
    has "the one-line notice" "$out" \
        "experimental support: reported by other projects, not tested with brioctl; please report with 'brioctl snapshot'" || return 1
    expect "the notice is one line" "$(printf '%s\n' "$out" | grep -c 'experimental support')" 1 || return 1
    for name in fov showmode hdr zoom brightness; do
        matches "$name line" "$out" "^  $name +[^ ]+ +default " || return 1
    done
    for name in tint vibrance warmth expcomp mic smooth micgain backlight; do
        noline "$name is not there" "$out" "$name" || return 1
    done
    hasnt "no status" "$out" "Status (read-only)" || return 1
    # only the field of view and Show Mode are written, with values from the table
    BRIOCTL_FAKE_TRACE=1 "$BIN" fov 65 > out 2> trace || return 1
    expect "fov output" "$(cat out)" "fov 65" || return 1
    expect "fov 65 is the value 2 of Videopipe 5" "$(grep '^fake SET_CUR' trace)" \
        "fake SET_CUR unit $VIDEOPIPE sel 5 02" || return 1
    BRIOCTL_FAKE_TRACE=1 "$BIN" fov 90 showmode off 2> trace > /dev/null || return 1
    expect "fov 90 and Show Mode off" "$(grep -o 'unit [0-9]* sel [0-9]* [0-9a-f]*' trace | tr '\n' ' ')" \
        "unit $VIDEOPIPE sel 5 00 unit $VIDEOPIPE sel 13 00 " || return 1
    # the register says 0-255: only the table counts
    for bad in 3 255 100 -1; do
        out=$("$BIN" fov $bad 2>&1); rc=$?
        expect "fov $bad status" "$rc" 1 || return 1
        has "fov $bad message" "$out" "bad value" || return 1
    done
    for name in tint warmth vibrance expcomp mic smooth; do
        out=$(BRIOCTL_FAKE_TRACE=1 "$BIN" $name 1 2>&1); rc=$?
        expect "$name status" "$rc" 1 || return 1
        has "$name message" "$out" "control not found on this camera" || return 1
        hasnt "$name write" "$out" "fake SET_CUR" || return 1
    done
    "$BIN" micgain 0.5 > /dev/null 2>&1; rc=$?
    expect "micgain status" "$rc" 1 || return 1
    "$BIN" factory-reset --yes > /dev/null 2>&1; rc=$?
    expect "factory-reset status" "$rc" 1 || return 1
    # hdr, as for the MX Brio
    expect "hdr" "$("$BIN" hdr off)" "hdr off" || return 1
    # a snapshot has no Logitech-only registers and no microphone
    "$BIN" snapshot > out.snap || return 1
    has "device line" "$(cat out.snap)" "device 046d 0943" || return 1
    noline "no Peripheral registers" "$(grep '^reg' out.snap | sed 's/^reg //')" "$PERIPHERAL" || return 1
    noline "no micgain" "$(cat out.snap)" micgain
}

t_logitech_models() {
    # which models get what: hdr is the name on the 4 models of the table that have it, fov on all of them
    for row in "0944 hdr" "0943 hdr" "085e hdr" "086b hdr" "0946 backlight" "0919 backlight"; do
        set -- $row
        sed "s/^device .*/device 046d $1/" camera.snap > model.snap
        out=$(BRIOCTL_FAKE=$PWD/model.snap "$BIN" 2>&1) || return 1
        matches "$1 has fov" "$out" "^  fov +" || return 1
        matches "$1 calls it $2" "$out" "^  $2 +" || return 1
    done
    for pid in 0943 0944; do
        sed "s/^device .*/device 046d $pid/" camera.snap > model.snap
        matches "$pid has Show Mode" "$(BRIOCTL_FAKE=$PWD/model.snap "$BIN" 2>&1)" "^  showmode +" || return 1
    done
    for pid in 085e 0946 0919 086b; do
        sed "s/^device .*/device 046d $pid/" camera.snap > model.snap
        noline "$pid has no Show Mode" "$(BRIOCTL_FAKE=$PWD/model.snap "$BIN" 2>&1)" showmode || return 1
    done
    # an unknown Logitech camera, and another vendor's camera that has Logitech's units: standard controls only
    for dev in "046d 0999" "1234 5678"; do
        sed "s/^device .*/device $dev/" camera.snap > model.snap
        out=$(BRIOCTL_FAKE=$PWD/model.snap "$BIN" 2>&1) || return 1
        has "$dev is standard" "$out" "standard UVC controls only" || return 1
        noline "$dev has no fov" "$out" fov || return 1
        out=$(BRIOCTL_FAKE=$PWD/model.snap BRIOCTL_FAKE_TRACE=1 "$BIN" fov 65 showmode off warmth 60 mic off zoom 120 2>&1)
        expect "$dev: only the standard control is written" \
            "$(printf '%s\n' "$out" | grep -o 'SET_CUR unit [0-9]* sel [0-9]*')" "SET_CUR unit $CT sel 11" || return 1
        has "$dev is listed as standard" "$(BRIOCTL_FAKE=$PWD/model.snap "$BIN" list)" standard || return 1
    done
}

t_xu_needs_the_set_bit() {
    edit_reg "$VIDEOPIPE" 5 info 01  # readable only
    out=$(BRIOCTL_FAKE_TRACE=1 "$BIN" fov 65 2>&1); rc=$?
    expect "status" "$rc" 1 || return 1
    has "message" "$out" "does not allow writing" || return 1
    hasnt "no write" "$out" "fake SET_CUR" || return 1
    sed "s/^\(reg $VIDEOPIPE 13 \)info 03 /\1/" camera.snap > no-info.snap  # GET_INFO does not answer
    cp no-info.snap "$BRIOCTL_FAKE"
    out=$(BRIOCTL_FAKE_TRACE=1 "$BIN" showmode off 2>&1); rc=$?
    expect "no GET_INFO status" "$rc" 1 || return 1
    hasnt "no write without GET_INFO" "$out" "fake SET_CUR" || return 1
    # a standard control that says it is read-only is not written either
    cp "$FIXTURE" "$BRIOCTL_FAKE"
    edit_reg "$PU" 2 info 01
    out=$(BRIOCTL_FAKE_TRACE=1 "$BIN" brightness 100 2>&1); rc=$?
    expect "read-only status" "$rc" 1 || return 1
    hasnt "no write" "$out" "fake SET_CUR"
}

t_dump_unknown_extension_unit() {
    # the Videopipe unit with a GUID brioctl does not know: nobody knows what reading its registers does
    sed 's/1502e44934f4fe47b1580e885023e51b/1502e44934f4fe47b1580e885023e51c/' camera.snap > other-guid.snap
    cmp -s camera.snap other-guid.snap && { echo "# GUID not found in the descriptor"; return 1; }
    BRIOCTL_FAKE=$PWD/other-guid.snap BRIOCTL_FAKE_TRACE=2 "$BIN" dump > out 2> trace || return 1
    has "unit is listed" "$(cat out)" "extension unit $VIDEOPIPE  49e40215-f434-47fe-b158-0e885023e51c  unknown" || return 1
    expect "no value request to it" "$(grep -cE "^fake GET_(CUR|MIN|MAX|RES|DEF) unit $VIDEOPIPE " trace)" 0 || return 1
    has "but asked what it is" "$(cat trace)" "fake GET_INFO unit $VIDEOPIPE sel 5"
}

t_standard_controls() {
    export BRIOCTL_FAKE=$PWD/extra.snap
    out=$("$BIN" 2>&1) || return 1
    for name in iris roll privacy hue hueauto gamma; do
        matches "$name line" "$out" "^  $name +[^ ]+ +default " || return 1
    done
    matches "signed range" "$out" "^  hue +0 +default 0 +-1000\.\.1000 " || return 1
    matches "brightness is signed" "$out" "^  brightness +0 +default 0 +-64\.\.64 " || return 1
    has "flicker choices" "$out" "anti-flicker, mains frequency in Hz: 50, 60, off, auto" || return 1
    has "ae choices" "$out" "auto exposure: manual, auto" || return 1
    # signed values go out as 16-bit two's complement
    BRIOCTL_FAKE_TRACE=1 "$BIN" hue -10 roll -90 brightness -30 gamma 150 iris 300 > out 2> trace || return 1
    has "hue" "$(cat trace)" "SET_CUR unit $PU sel 6 f6ff" || return 1
    has "roll" "$(cat trace)" "SET_CUR unit $CT sel 15 a6ff" || return 1
    has "brightness" "$(cat trace)" "SET_CUR unit $PU sel 2 e2ff" || return 1
    has "gamma" "$(cat trace)" "SET_CUR unit $PU sel 9 9600" || return 1
    has "iris" "$(cat trace)" "SET_CUR unit $CT sel 9 2c01" || return 1
    expect "hue" "$("$BIN" get hue)" -10 || return 1
    expect "roll" "$("$BIN" get roll)" -90 || return 1
    expect "brightness" "$("$BIN" get brightness)" -30 || return 1
    out=$("$BIN" hue 2000 2>&1); rc=$?
    expect "hue out of range" "$rc" 1 || return 1
    has "range in the message" "$out" "out of range (-1000..1000)" || return 1
    "$BIN" brightness 100 > /dev/null 2>&1; rc=$?
    expect "brightness out of range" "$rc" 1 || return 1
    expect "hueauto" "$("$BIN" hueauto on)" "hueauto on" || return 1
    # privacy is the camera's own shutter state here: it says it cannot be set
    out=$(BRIOCTL_FAKE_TRACE=1 "$BIN" privacy on 2>&1); rc=$?
    expect "privacy status" "$rc" 1 || return 1
    has "privacy message" "$out" "does not allow writing" || return 1
    hasnt "privacy not written" "$out" "fake SET_CUR" || return 1
    # the exposure modes this camera lists (manual, auto = 2) and the flicker values of its range
    BRIOCTL_FAKE_TRACE=1 "$BIN" ae manual > /dev/null 2> trace || return 1
    has "ae manual" "$(cat trace)" "SET_CUR unit $CT sel 2 01" || return 1
    BRIOCTL_FAKE_TRACE=1 "$BIN" ae auto > /dev/null 2> trace || return 1
    has "ae auto is mode 2 here" "$(cat trace)" "SET_CUR unit $CT sel 2 02" || return 1
    "$BIN" ae shutter > /dev/null 2>&1; rc=$?
    expect "a mode the camera does not list" "$rc" 1 || return 1
    BRIOCTL_FAKE_TRACE=1 "$BIN" flicker auto > /dev/null 2> trace || return 1
    has "flicker auto" "$(cat trace)" "SET_CUR unit $PU sel 5 03" || return 1
    expect "flicker off" "$("$BIN" flicker off)" "flicker off" || return 1
    # save and apply round trip
    "$BIN" save "$PWD/s" > /dev/null || return 1
    has "saved hue" "$(cat s)" "hue -10" || return 1
    has "saved flicker" "$(cat s)" "flicker off" || return 1
    "$BIN" hue 5 flicker 50 > /dev/null || return 1
    "$BIN" apply "$PWD/s" > /dev/null || return 1
    expect "applied hue" "$("$BIN" get hue)" -10 || return 1
    # the MX Brio has none of these, and its exposure mode is 8
    export BRIOCTL_FAKE=$PWD/camera.snap
    "$BIN" hue 5 > /dev/null 2>&1; rc=$?
    expect "hue on the MX Brio" "$rc" 1 || return 1
    "$BIN" flicker off > /dev/null 2>&1; rc=$?
    expect "flicker off on the MX Brio" "$rc" 1 || return 1
    BRIOCTL_FAKE_TRACE=1 "$BIN" ae manual ae auto > /dev/null 2> trace || return 1
    has "ae auto is mode 8 on the MX Brio" "$(cat trace)" "SET_CUR unit $CT sel 2 08"
}

t_defaults_any_camera() {
    export BRIOCTL_FAKE=$PWD/generic.snap
    "$BIN" brightness 100 contrast 90 > /dev/null || return 1
    BRIOCTL_FAKE_TRACE=1 "$BIN" defaults > out 2> trace; rc=$?
    expect "status" "$rc" 0 || return 1
    # zoom 115 and flicker 50 were not the defaults either; exposure, gain, wb and focus are driven by auto modes
    expect "what was written" "$(grep -o 'unit [0-9]* sel [0-9]*' trace | sort | tr '\n' ' ')" \
        "unit $CT sel 11 unit $PU sel 2 unit $PU sel 3 unit $PU sel 5 " || return 1
    expect "brightness" "$("$BIN" get brightness)" 128 || return 1
    expect "flicker" "$("$BIN" get flicker)" 60 || return 1
    # the experimental model: the field of view too, but not Show Mode
    export BRIOCTL_FAKE=$PWD/brio500.snap
    "$BIN" fov 65 showmode off > /dev/null || return 1
    "$BIN" defaults > out || return 1
    has "fov default" "$(cat out)" "fov 90" || return 1
    hasnt "showmode untouched" "$(cat out)" showmode || return 1
    expect "showmode" "$("$BIN" get showmode)" off
}

t_save_names_the_camera() {
    "$BIN" save "$PWD/s" > /dev/null || return 1
    expect "first line" "$(sed -n 1p s | cut -c1-17)" "# brioctl setting" || return 1
    expect "camera line" "$(sed -n 2p s)" "# camera 046d:0944 000000000000" || return 1
    # no warning on the same model
    out=$("$BIN" apply "$PWD/s" 2>&1); rc=$?
    expect "same model status" "$rc" 0 || return 1
    hasnt "no warning" "$out" warning || return 1
    # another model: a warning, not a failure
    printf '# camera 046d:0944 ABC\nzoom 140\nbrightness 100\n' > other
    export BRIOCTL_FAKE=$PWD/generic.snap
    out=$("$BIN" apply "$PWD/other" 2>&1); rc=$?
    expect "status" "$rc" 0 || return 1
    has "warning" "$out" \
        "warning: these settings were saved from camera 046d:0944, this is 1234:5678 (Generic UVC)" || return 1
    expect "the settings that fit are applied" "$("$BIN" get zoom)" 140 || return 1
    "$BIN" save "$PWD/g" > /dev/null || return 1
    expect "generic camera line" "$(sed -n 2p g)" "# camera 1234:5678 000000000000" || return 1
    printf '# camera 1234:5678\nzoom 150\n' > noserial
    out=$("$BIN" apply "$PWD/noserial" 2>&1) || return 1
    hasnt "no serial in the line is fine" "$out" warning || return 1
    # a file without the line (saved by 1.0) and a preset: nothing to warn about
    printf 'zoom 160\n' > old
    out=$("$BIN" apply "$PWD/old" 2>&1) || return 1
    hasnt "old file" "$out" warning || return 1
    out=$("$BIN" apply warmer 2>&1)
    hasnt "preset" "$out" "saved from"
}

t_other_snapshots_round_trip() {
    export BRIOCTL_FAKE=$PWD/generic.snap
    "$BIN" snapshot > out.snap || return 1
    grep -v '^#' generic.snap | sort > want
    grep -v '^#' out.snap | sort > got
    cmp -s want got || { echo "# snapshot of the generic camera differs from the fixture"; diff want got | head -5; return 1; }
    BRIOCTL_FAKE=$PWD/extra.snap "$BIN" snapshot > out.snap || return 1
    grep -v '^#' extra.snap | sort > want
    grep -v '^#' out.snap | sort > got
    cmp -s want got || { echo "# snapshot of the extra camera differs from the fixture"; diff want got | head -5; return 1; }
    BRIOCTL_FAKE=$PWD/brio500.snap "$BIN" snapshot > out.snap || return 1
    has "device line" "$(cat out.snap)" "device 046d 0943" || return 1
    has "header" "$(head -1 out.snap)" "firmware 1.1.394"
}

t_fixtures_are_generated() {
    command -v python3 > /dev/null 2>&1 || { echo "# python3 not available"; return 77; }
    mkdir fx && cp "$HERE/make-fixtures.py" "$HERE/mxbrio-1.1.394.snap" fx/ || return 1
    python3 -I fx/make-fixtures.py > /dev/null || return 1
    for f in generic-uvc generic-uvc-extra brio500-sim; do
        cmp -s "fx/$f.snap" "$HERE/$f.snap" || { echo "# $f.snap is not what make-fixtures.py writes (make fixtures)"; return 1; }
    done
    # the generic camera really has no extension unit and a consistent descriptor
    python3 -I - generic.snap <<'EOF'
import sys
line = [l for l in open(sys.argv[1]) if l.startswith("descriptor ")][0].split()[1]
d = bytes.fromhex(line)
assert d[2] | d[3] << 8 == len(d), "wTotalLength"
i, vc, total, header = 0, False, 0, None
while i < len(d):
    n = d[i]
    if d[i + 1] == 4:
        vc = d[i + 5] == 14 and d[i + 6] == 1
    elif vc and d[i + 1] == 0x24:
        total += n
        assert d[i + 2] != 6, "an extension unit is left"
        if d[i + 2] == 1:
            header = d[i + 5] | d[i + 6] << 8
    i += n
assert header == total, (header, total)
EOF
}

# --- --json for the GUI ----------------------------------------------------------------------------------------------

t_json_contract() {
    python3 -I -c pass >/dev/null 2>&1 || { echo "# python3 not available"; return 77; }
    "$BIN" --json > out.json || return 1
    python3 -I - out.json <<'EOF' || return 1
import json, sys
d = json.load(open(sys.argv[1]))
dev = d["device"]
want = {"vid": "046d", "pid": "0944", "model": "MX Brio", "support": "full", "index": 1, "location": "0x100000"}
assert all(dev[k] == v for k, v in want.items()), dev
s = d["settings"]
assert {v["group"] for v in s.values()} == {"Logitech", "Framing", "Exposure and image", "Found in the firmware"}
for name, v in s.items():
    assert v["kind"] in ("choice", "bool", "number"), (name, v)
    assert isinstance(v["writable"], bool) and isinstance(v["help"], str) and v["help"], (name, v)
    assert ("choices" in v) == (v["kind"] == "choice"), (name, v)
    assert all((k in v) == (v["kind"] == "number") for k in ("min", "max", "step")), (name, v)
# a number: the camera's range and step, scaled like the value
z = s["zoom"]
assert (z["kind"], z["min"], z["max"], z["step"], z["group"], z["writable"]) == ("number", 100, 400, 1, "Framing", True), z
assert (s["pan"]["min"], s["pan"]["max"], s["pan"]["step"]) == (-20, 20, 1), s["pan"]
assert (s["exposure"]["min"], s["exposure"]["max"]) == (3, 2047), s["exposure"]
assert (s["warmth"]["min"], s["warmth"]["max"], s["warmth"]["group"]) == (0, 100, "Logitech"), s["warmth"]
# a choice: the names it accepts
f = s["fov"]
assert (f["kind"], f["choices"], f["group"], f["writable"]) == ("choice", ["90", "78", "65"], "Logitech", True), f
assert f["help"] == "field of view in degrees: 90, 78, 65", f["help"]
assert s["ae"]["choices"] == ["auto", "manual"] and s["flicker"]["choices"] == ["50", "60"], (s["ae"], s["flicker"])
assert s["priority"]["choices"] == ["fps", "exposure"], s["priority"]
# a bool
b = s["showmode"]
assert (b["kind"], b["value"], b["writable"]) == ("bool", "on", True) and "choices" not in b, b
assert s["awb"]["kind"] == "bool" and s["hdr"]["kind"] == "bool" and s["mic"]["kind"] == "bool"
# not writable now: driven by an auto mode
for name in ("exposure", "gain", "wb", "focus"):
    assert s[name]["auto"] is True and s[name]["writable"] is False, (name, s[name])
assert s["brightness"]["auto"] is False and s["brightness"]["writable"] is True
EOF
}

t_json_other_cameras() {
    python3 -I -c pass >/dev/null 2>&1 || { echo "# python3 not available"; return 77; }
    BRIOCTL_FAKE=$PWD/generic.snap "$BIN" --json > generic.json || return 1
    BRIOCTL_FAKE=$PWD/brio500.snap "$BIN" --json > brio500.json || return 1
    BRIOCTL_FAKE=$PWD/extra.snap "$BIN" --json > extra.json || return 1
    python3 -I - generic.json brio500.json extra.json <<'EOF' || return 1
import json, sys
g, b, x = (json.load(open(f)) for f in sys.argv[1:4])
dev = g["device"]
assert (dev["vid"], dev["pid"], dev["model"], dev["support"], dev["name"], dev["index"]) == \
    ("1234", "5678", None, "standard", "Generic UVC", 1), dev
assert dev["firmware"] is None and dev["colour"] is None and dev["serial"] == "000000000000", dev
assert g["micgain"] is None and g["status"]["video"] is None and g["status"]["led"] is None
s = g["settings"]
assert not {"fov", "showmode", "hdr", "warmth", "tint", "vibrance", "expcomp", "mic", "smooth"} & set(s), sorted(s)
assert {v["group"] for v in s.values()} == {"Framing", "Exposure and image"}
assert s["backlight"]["kind"] == "number" and (s["backlight"]["min"], s["backlight"]["max"]) == (0, 1), s["backlight"]
dev = b["device"]
assert (dev["vid"], dev["pid"], dev["model"], dev["support"]) == ("046d", "0943", "Brio 500", "experimental"), dev
s = b["settings"]
assert {"fov", "showmode", "hdr"} <= set(s) and not {"tint", "warmth", "vibrance", "expcomp", "mic", "smooth", "backlight"} & set(s)
assert b["micgain"] is None
s = x["settings"]
assert (s["roll"]["min"], s["roll"]["max"]) == (-180, 180), s["roll"]
assert (s["brightness"]["min"], s["brightness"]["max"]) == (-64, 64), s["brightness"]
assert s["ae"]["choices"] == ["manual", "auto"] and s["flicker"]["choices"] == ["50", "60", "off", "auto"], s
assert s["privacy"]["kind"] == "bool" and s["privacy"]["writable"] is False, s["privacy"]
assert s["hueauto"]["kind"] == "bool" and s["hue"]["kind"] == "number" and s["gamma"]["min"] == 100
EOF
}

t_json_errors_are_text() {
    three_cameras
    BRIOCTL_FAKE=$PWD/generic.snap:$PWD/extra.snap
    out=$("$BIN" --json 2>/dev/null); rc=$?
    expect "several cameras status" "$rc" 2 || return 1
    expect "nothing on stdout" "$out" "" || return 1
    has "text on stderr" "$("$BIN" --json 2>&1 > /dev/null)" "several cameras: choose one with --camera" || return 1
    out=$("$BIN" --camera 9 --json 2>/dev/null); rc=$?
    expect "bad camera status" "$rc" 2 || return 1
    expect "bad camera stdout" "$out" "" || return 1
    BRIOCTL_FAKE=: out=$("$BIN" --json 2>/dev/null); rc=$?
    expect "no camera status" "$rc" 1 || return 1
    expect "no camera stdout" "$out" "" || return 1
    has "no camera stderr" "$(BRIOCTL_FAKE=: "$BIN" --json 2>&1)" "no UVC camera found"
}

t_profiles_json() {
    want='{"presets":[{"name":"neutral","settings":{"warmth":"50","saturation":"128"}},'
    want="$want"'{"name":"warmer","settings":{"warmth":"60"}},{"name":"cooler","settings":{"warmth":"40"}},'
    want="$want"'{"name":"bw","settings":{"saturation":"0"}},{"name":"standard","settings":{"priority":"exposure"}},'
    want="$want"'{"name":"streaming","settings":{"priority":"fps"}},{"name":"colorboost","settings":{"saturation":"255"}}],'
    expect "no saved files" "$("$BIN" profiles --json)" "$want\"saved\":[],\"dir\":\"$HOME/.config/brioctl\"}" || return 1
    "$BIN" save > /dev/null || return 1
    "$BIN" save meeting > /dev/null || return 1
    expect "saved files, sorted" "$("$BIN" profiles --json)" \
        "$want\"saved\":[\"meeting\",\"settings\"],\"dir\":\"$HOME/.config/brioctl\"}" || return 1
    # names are escaped
    : > "$HOME/.config/brioctl/we\"ird"
    : > "$HOME/.config/brioctl/caf$(printf '\303\251')"
    : > "$HOME/.config/brioctl/.hidden"
    out=$("$BIN" profiles --json)
    has "quote escaped" "$out" 'we\"ird' || return 1
    has "utf-8 as a \u escape" "$out" 'caf\u00e9' || return 1
    hasnt "no dot files" "$out" hidden || return 1
    if python3 -I -c pass >/dev/null 2>&1; then
        printf '%s\n' "$out" | python3 -I -c '
import json, os, sys
d = json.load(sys.stdin)
assert d["dir"] == os.path.expanduser("~/.config/brioctl") and d["dir"].startswith("/"), d["dir"]
assert d["saved"] == sorted(d["saved"]) and "café" in d["saved"] and "meeting" in d["saved"], d["saved"]
assert d["presets"][1] == {"name": "warmer", "settings": {"warmth": "60"}}
' || return 1
    fi
    # the text form is still there
    out=$("$BIN" profiles)
    has "presets" "$out" "warmer     warmth 60" || return 1
    has "saved" "$out" "  meeting" || return 1
    "$BIN" profiles extra > /dev/null 2>&1; rc=$?
    expect "bad argument" "$rc" 2 || return 1
    # profiles needs no camera
    BRIOCTL_FAKE=: "$BIN" profiles --json > /dev/null
}

# --- run -----------------------------------------------------------------------------------------------------------

N=0
FAILED=0

run() {  # run NAME FUNCTION
    N=$((N + 1))
    dir=$ROOT/$N
    if ! { mkdir -p "$dir/home" && cp "$FIXTURE" "$dir/camera.snap" && cp "$GENERIC" "$dir/generic.snap" &&
        cp "$EXTRA" "$dir/extra.snap" && cp "$BRIO500" "$dir/brio500.snap"; }; then
        echo "not ok $N - $1 (cannot set up)"
        FAILED=$((FAILED + 1))
        return
    fi
    (
        cd "$dir" || exit 1
        HOME=$dir/home BRIOCTL_FAKE=$dir/camera.snap
        export HOME BRIOCTL_FAKE
        unset BRIOCTL_FAKE_TRACE
        "$2"
    ) > "$dir/log" 2>&1
    rc=$?
    case $rc in
    0) echo "ok $N - $1" ;;
    77) echo "ok $N - $1 # SKIP $(sed -n 's/^# //p' "$dir/log" | head -1)" ;;
    *)
        echo "not ok $N - $1"
        sed 's/^/    /' "$dir/log"
        FAILED=$((FAILED + 1))
        ;;
    esac
}

run "show prints firmware, masked serial and the controls" t_show
run "--json is valid JSON with device, status, settings, micgain" t_json
run "fov 65 is written and read back by a later process" t_set_and_get
run "bad values are refused (fov 70, zoom 500)" t_rejects_bad_values
run "a control driven by an auto mode is refused" t_refuses_auto_controls
run "tilt 5 then pan 10 keeps tilt (read-modify-write)" t_read_modify_write
run "extension unit with another length is not written" t_xu_length_check
run "save leaves out auto-driven and out-of-range values" t_save_skips_unusable_values
run "apply writes mic last" t_apply_puts_mic_last
run "setting the current value sends no SET_CUR" t_skips_equal_values
run "apply colorboost sets saturation 255" t_preset
run "--version and version print brioctl VERSION" t_version
run "dump exits 0 and lists the units" t_dump
run "snapshot of the fake equals the fixture" t_snapshot_round_trip
run "snapshot never reads the factory reset register" t_snapshot_never_reads_factory_reset
run "snapshot masks the serial number" t_snapshot_masks_serial
run "get prints one value; unknown or unreadable exits 1" t_get
run "micgain is stored in the snapshot" t_micgain_persists
run "without BRIOCTL_FAKE the fake build refuses to run" t_needs_a_snapshot
run "pan -10 works and the same negative value is not written again" t_negative_pan
run "micgain refuses nan, inf, hex floats and out-of-range values" t_micgain_rejects_bad_values
run "micgain equal to the current volume is not written" t_micgain_skips_equal
run "a micgain that is not a number is null, unreadable, not saved" t_micgain_not_a_number
run "--json is valid without the stats and app registers" t_json_without_stats_and_app
run "dump does not read service registers" t_dump_leaves_service_registers
run "dump stays inside a damaged configuration descriptor" t_dump_bounds_checks_descriptors
run "a bad snapshot line is reported whole" t_bad_snapshot_line
run "a fake camera that cannot be saved exits 1" t_fake_save_failure
run "snapshot exits 1 when no register answers" t_snapshot_nothing_answers
run "watch connect: only real changes are printed" t_reapply_prints_only_changes
run "watch video start: mic is left alone" t_reapply_never_changes_mic_in_video
run "watch at the desk: fov, zoom, pan, tilt are skipped" t_reapply_skips_framing_at_the_desk
run "watch video start after unplugging does nothing" t_video_start_after_unplug
run "list shows every camera, as a table and as JSON" t_list
run "without --camera: the only camera, or the only known one, else exit 2" t_default_camera
run "--camera takes an index, a serial number or a location, for every command" t_camera_option
run "snapshot writes the device, name and masked serial; old snapshots are MX Brios" t_snapshot_device_lines
run "writes keep the device lines of a fake camera" t_camera_survives_writes
run "a generic camera: standard controls only, backlight, no Logitech writes" t_generic_camera
run "hdr and backlight are one control with two names" t_hdr_or_backlight
run "an experimental model gets the field of view, Show Mode and hdr only" t_experimental_camera
run "models: fov, Show Mode, hdr or backlight as the table says; unknown ones get none" t_logitech_models
run "extension unit writes need the SET bit" t_xu_needs_the_set_bit
run "dump does not read the registers of an unknown extension unit" t_dump_unknown_extension_unit
run "hue, gamma, iris, roll, privacy, signed ranges, exposure modes of another camera" t_standard_controls
run "defaults works for any camera" t_defaults_any_camera
run "save names the camera and apply warns about another model" t_save_names_the_camera
run "snapshots of the other fixtures equal the fixtures" t_other_snapshots_round_trip
run "the fixtures are what make-fixtures.py writes" t_fixtures_are_generated
run "--json: group, writable, kind, min, max, step, choices and help for the GUI" t_json_contract
run "--json of a generic, an experimental and another camera" t_json_other_cameras
run "errors with --json are text on stderr and a non-zero exit" t_json_errors_are_text
run "profiles --json lists presets, saved files and the directory" t_profiles_json

echo "1..$N"
if [ "$FAILED" -ne 0 ]; then
    echo "# $FAILED of $N failed"
    exit 1
fi
echo "# all $N passed"
