#!/bin/sh
# Offline tests for brioctl: the same source built with -DBRIOCTL_FAKE, so it talks to a camera that is read from a
# snapshot file (tests/mxbrio-1.1.394.snap, taken from a real MX Brio with `brioctl snapshot`) instead of USB.
# Every test gets its own copy of the snapshot (camera.snap) and of the other fixtures (generic.snap, extra.snap,
# brio500.snap: see make-fixtures.py) and its own HOME. `import optionsplus` reads optionsplus.db, a copy of
# tests/optionsplus-sample.db (the settings database of Logi Options+ 2.9.994631 with a made-up serial number and ids;
# optionsplus-sample.json is the document in it). Run it with `make test`.
set -u

HERE=$(cd "$(dirname "$0")" && pwd) || exit 1
BIN=${BIN:-$HERE/brioctl-fake}
FIXTURE=$HERE/mxbrio-1.1.394.snap
GENERIC=$HERE/generic-uvc.snap EXTRA=$HERE/generic-uvc-extra.snap BRIO500=$HERE/brio500-sim.snap
OPLUS=$HERE/optionsplus-sample.db OPLUS_JSON=$HERE/optionsplus-sample.json
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/brioctl-test.XXXXXX") || exit 1
trap 'rm -rf "$ROOT"' EXIT
trap 'exit 1' HUP INT TERM

[ -x "$BIN" ] || { echo "Bail out! $BIN is not built (make test builds it)"; exit 1; }
for f in "$FIXTURE" "$GENERIC" "$EXTRA" "$BRIO500" "$OPLUS" "$OPLUS_JSON"; do
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

# drop_field UNIT SEL KEY: remove one field (min, max, ...) of a register in this test's snapshot: the camera does not
# answer that request
drop_field() {
    awk -v u="$1" -v s="$2" -v k="$3" '
        $1 == "reg" && $2 == u && $3 == s {
            out = $1 " " $2 " " $3
            for (i = 4; i <= NF; i++) { if ($i == k) { i++; continue } out = out " " $i }
            print out
            next
        }
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
    want="$want"'"vid":"1234","pid":"5678","name":"Generic UVC","model":null,"support":"standard",'
    want="$want"'"serial":"GENERIC0002","location":"0x300000"}]}'
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
    sed 's/^serial .*/serial REALSERIAL1/;s/^name .*/name Some Camera Name/;s/^device .*/device 1234 abcd/' \
        camera.snap > other.snap
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
    has "the one-line notice" "$out" "experimental support: reported by other projects, not tested with brioctl; \
please report with 'brioctl snapshot'" || return 1
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
    for bad in 3 255 100; do
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
        out=$(BRIOCTL_FAKE=$PWD/model.snap BRIOCTL_FAKE_TRACE=1 "$BIN" \
            fov 65 showmode off warmth 60 mic off zoom 120 2>&1)
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
    has "unit is listed" "$(cat out)" \
        "extension unit $VIDEOPIPE  49e40215-f434-47fe-b158-0e885023e51c  unknown" || return 1
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
    expect "showmode" "$("$BIN" get showmode)" off || return 1
    # the usage line names what defaults leaves alone (explicitOnly: privacy; and the two whose GET_DEF is wrong)
    has "usage says what defaults skips" "$("$BIN" --help)" "camera defaults, except mic, showmode and privacy"
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
    cmp -s want got || { echo "# snapshot of the generic camera differs"; diff want got | head -5; return 1; }
    BRIOCTL_FAKE=$PWD/extra.snap "$BIN" snapshot > out.snap || return 1
    grep -v '^#' extra.snap | sort > want
    grep -v '^#' out.snap | sort > got
    cmp -s want got || { echo "# snapshot of the extra camera differs"; diff want got | head -5; return 1; }
    BRIOCTL_FAKE=$PWD/brio500.snap "$BIN" snapshot > out.snap || return 1
    has "device line" "$(cat out.snap)" "device 046d 0943" || return 1
    has "header" "$(head -1 out.snap)" "firmware 1.1.394"
}

t_fixtures_are_generated() {
    command -v python3 > /dev/null 2>&1 || { echo "# python3 not available"; return 77; }
    mkdir fx && cp "$HERE/make-fixtures.py" "$HERE/mxbrio-1.1.394.snap" fx/ || return 1
    python3 -I fx/make-fixtures.py > /dev/null || return 1
    for f in generic-uvc generic-uvc-extra brio500-sim; do
        cmp -s "fx/$f.snap" "$HERE/$f.snap" || { echo "# $f.snap is not what make-fixtures.py writes"; return 1; }
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
assert (z["kind"], z["min"], z["max"], z["step"]) == ("number", 100, 400, 1), z
assert (z["group"], z["writable"]) == ("Framing", True), z
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
assert {"fov", "showmode", "hdr"} <= set(s)
assert not {"tint", "warmth", "vibrance", "expcomp", "mic", "smooth", "backlight"} & set(s), sorted(s)
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
    want="$want"'{"name":"streaming","settings":{"priority":"fps"}},'
    want="$want"'{"name":"colorboost","settings":{"saturation":"255"}}],'
    expect "no saved files" "$("$BIN" profiles --json)" \
        "$want\"saved\":[],\"dir\":\"$HOME/.config/brioctl\"}" || return 1
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

# --- watch: which camera it follows, and CoreMediaIO ------------------------------------------------------------------

t_watch_target() {
    expect "one MX Brio" "$("$BIN" --test-watch-target)" \
        "046d:0944 serial=000000000000 uid=0x100000046d0944" || return 1
    three_cameras
    # several cameras, one known: the MX Brio, by its serial number
    expect "the known one" "$("$BIN" --test-watch-target)" \
        "046d:0944 serial=BRIOSERIAL1 uid=0x200000046d0944" || return 1
    # --camera: any camera, followed by its ids and serial number
    expect "a generic camera" "$("$BIN" --camera 3 --test-watch-target)" \
        "1234:5678 serial=GENERIC0002 uid=0x30000012345678" || return 1
    expect "by serial" "$("$BIN" --camera GENERIC0001 --test-watch-target)" \
        "1234:5678 serial=GENERIC0001 uid=0x10000012345678" || return 1
    # a camera that is not there: watch says so and waits, it does not fail (launchd would start it again at once)
    out=$("$BIN" --camera 9 --test-watch-target 2>&1); rc=$?
    expect "no such camera status" "$rc" 0 || return 1
    has "no such camera message" "$out" "camera 9 is not connected, waiting for it" || return 1
    has "no such camera, no target" "$out" "no target" || return 1
    out=$("$BIN" --camera NOSUCHSERIAL --test-watch-target 2>&1)
    has "no such serial" "$out" "camera NOSUCHSERIAL is not connected, waiting for it" || return 1
    # no camera known to brioctl: wait for one, say so; a FaceTime camera must not be taken
    BRIOCTL_FAKE=$PWD/generic.snap
    out=$("$BIN" --test-watch-target 2>&1); rc=$?
    expect "status" "$rc" 0 || return 1
    has "waits for a known camera" "$out" "no camera known to brioctl is connected, waiting for one" || return 1
    has "and follows nothing" "$out" "no target" || return 1
    hasnt "no uid" "$out" uid= || return 1
    expect "with --camera it follows the camera" "$("$BIN" --camera 1 --test-watch-target)" \
        "1234:5678 serial=000000000000 uid=0x10000012345678" || return 1
    BRIOCTL_FAKE=$PWD/g1.snap:$PWD/g2.snap
    out=$("$BIN" --test-watch-target 2>&1)
    has "two unknown cameras" "$out" "no camera known to brioctl is connected" || return 1
    has "two unknown cameras, no target" "$out" "no target" || return 1
    # nothing connected: the same, and --camera is not an error either
    BRIOCTL_FAKE=:
    out=$("$BIN" --test-watch-target 2>&1); rc=$?
    expect "no camera status" "$rc" 0 || return 1
    has "no camera message" "$out" "no camera known to brioctl is connected, waiting for one" || return 1
    has "no camera, no target" "$out" "no target" || return 1
    out=$("$BIN" --camera 1 --test-watch-target 2>&1); rc=$?
    expect "no camera, --camera status" "$rc" 0 || return 1
    has "no camera, --camera message" "$out" "camera 1 is not connected, waiting for it" || return 1
    # the single full camera wins over an experimental one
    BRIOCTL_FAKE=$PWD/camera.snap:$PWD/brio500.snap
    expect "full before experimental" "$("$BIN" --test-watch-target)" \
        "046d:0944 serial=000000000000 uid=0x100000046d0944" || return 1
    BRIOCTL_FAKE=$PWD/brio500.snap:$PWD/camera.snap
    expect "full before experimental, any order" "$("$BIN" --test-watch-target)" \
        "046d:0944 serial=000000000000 uid=0x200000046d0944" || return 1
    # no full camera: the single experimental one (a generic camera next to it is not considered)
    BRIOCTL_FAKE=$PWD/g1.snap:$PWD/brio500.snap
    expect "the experimental one" "$("$BIN" --test-watch-target)" \
        "046d:0943 serial=000000000000 uid=0x200000046d0943" || return 1
    # not clear: two full cameras, two experimental ones. Say so and wait, whatever else is connected.
    sed 's/^serial .*/serial BRIOSERIAL2/' camera.snap > brio2.snap
    BRIOCTL_FAKE=$PWD/camera.snap:$PWD/brio2.snap:$PWD/brio500.snap
    out=$("$BIN" --test-watch-target 2>&1); rc=$?
    expect "two full status" "$rc" 0 || return 1
    has "two full message" "$out" "several cameras with full support, waiting (choose one with --camera ID)" || return 1
    has "two full, no target" "$out" "no target" || return 1
    expect "--camera settles it" "$("$BIN" --camera BRIOSERIAL2 --test-watch-target)" \
        "046d:0944 serial=BRIOSERIAL2 uid=0x200000046d0944" || return 1
    cp brio500.snap b5b.snap
    BRIOCTL_FAKE=$PWD/brio500.snap:$PWD/b5b.snap
    out=$("$BIN" --test-watch-target 2>&1)
    has "two experimental message" "$out" "several cameras with experimental support, waiting" || return 1
    has "two experimental, no target" "$out" "no target" || return 1
    # the same serial twice does not name a camera either
    BRIOCTL_FAKE=$PWD/camera.snap:$PWD/camera.snap
    out=$("$BIN" --camera 000000000000 --test-watch-target 2>&1); rc=$?
    expect "same serial status" "$rc" 0 || return 1
    has "same serial message" "$out" "serial 000000000000 matches several cameras, waiting"
}

t_watch_applies_to_the_chosen_camera() {
    three_cameras
    printf 'zoom 150\nbrightness 90\n' > settings
    # camera 3 is chosen; when it comes back the cameras are in another order, its serial number finds it
    BRIOCTL_FAKE_AFTER=$PWD/g2.snap:$PWD/g1.snap:$PWD/brio.snap \
        "$BIN" --camera GENERIC0002 --test-reapply "$PWD/settings" > out || return 1
    has "applied" "$(cat out)" "applied (2 changed)" || return 1
    has "the chosen camera got it" "$(grep '^reg 1 11 ' g2.snap)" "cur 9600" || return 1
    has "the others did not" "$(grep '^reg 1 11 ' g1.snap)" "cur 7300" || return 1
    has "the MX Brio did not" "$(grep '^reg 1 11 ' brio.snap)" "cur 7300" || return 1
    # video start on the second MX Brio-like camera: only its own settings
    printf 'zoom 160\n' > settings
    "$BIN" --camera 2 --test-reapply "$PWD/settings" video > out || return 1
    has "video started" "$(cat out)" "video started" || return 1
    has "the MX Brio got it" "$(grep '^reg 1 11 ' brio.snap)" "cur a000" || return 1
    has "and nobody else" "$(grep '^reg 1 11 ' g1.snap)" "cur 7300" || return 1
    # a generic camera takes a settings file with Logitech lines: what fits is applied
    printf 'fov 65\nzoom 170\n' > settings
    "$BIN" --camera 1 --test-reapply "$PWD/settings" > out 2>&1 || return 1
    has "zoom applied" "$(cat out)" "zoom 170" || return 1
    has "no fov on it" "$(cat out)" "fov: control not found on this camera" || return 1
    has "log line" "$(cat out)" "could not apply all settings (1 changed)"
}

t_cmio_hook() {
    export BRIOCTL_FAKE=$PWD/generic.snap
    expect "no CoreMediaIO device for an unknown camera" "$("$BIN" --test-cmio)" "cmio none"
}

# --- import optionsplus --------------------------------------------------------------------------------------------------

# What import writes for the sample database, without the date line. The twenty settings are the ones in the camera
# snapshot (taken while Logi Options+ had set them), the comments say what is left out.
OPLUS_LINES='fov 78
showmode on
hdr on
warmth 62
tint 50
vibrance 128
expcomp 128
zoom 115
pan 0
tilt 0
priority exposure
ae auto
flicker 60
brightness 128
contrast 128
saturation 128
sharpness 128
awb on
af on
micgain 0.2785'
OPLUS_NOTES='# skipped: mic (Logi Options+ does not keep the camera microphone on or off; apply leaves it as it is)
# skipped: stopVideoOnAppFocusLoss (no brioctl equivalent)
# skipped: videoPreview (no brioctl equivalent)'

# oplus_python: skip the test (status 77) when there is no python3 to build database variants with
oplus_python() { python3 -I -c pass >/dev/null 2>&1 || { echo "# python3 not available"; return 77; }; }

# mkdb FILE 'PYTHON': a Logi Options+ settings database in the real two-table schema, made from the sample document
# after PYTHON has changed it. In PYTHON, d is the document, P its profile, card(KIND) the card of the camera for KIND
# (camera, crop, focus, global, microphone, video) and sel(KIND) the settings of the preset that card selects.
mkdb() {
    python3 -I - "$OPLUS_JSON" "$1" "$2" <<'EOF'
import json, os, sqlite3, sys
src, dst, code = sys.argv[1:4]
d = json.load(open(src))
P = d["profile-00000000-0000-0000-0000-000000000000"]
def card(kind):
    return [a["card"] for a in P["assignments"] if a["slotId"].endswith("_webcam_%s_settings" % kind)][0]
def sel(kind):
    g = card(kind)[kind + "SettingsGroup"]
    return [x for x in g[kind + "Presets"] if x["presetName"] == g["selectedPresetName"]][0][kind + "Settings"]
exec(code)
if os.path.exists(dst):
    os.remove(dst)
c = sqlite3.connect(dst)
c.executescript("""
CREATE TABLE data(_id INTEGER PRIMARY KEY,_date_created datetime default current_timestamp,file BLOB NOT NULL);
CREATE TABLE snapshots(_id INTEGER PRIMARY KEY,_date_created datetime default current_timestamp,uuid TEXT NOT NULL,label TEXT NOT NULL,file BLOB NOT NULL);
""")
c.execute("INSERT INTO data(file) VALUES (?)", (json.dumps(d, indent=2, sort_keys=True).encode(),))
c.commit()
c.close()
EOF
}

t_import_sample() {
    out=$("$BIN" import optionsplus optionsplus.db 2> err); rc=$?
    expect "status" "$rc" 0 || return 1
    expect "the twenty settings" "$(printf '%s\n' "$out" | grep -v '^#')" "$OPLUS_LINES" || return 1
    matches "date line" "$(printf '%s\n' "$out" | sed -n 1p)" \
        '^# imported from Logi Options\+ 2\.9\.994631 on [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$' || return 1
    expect "everything else" "$(printf '%s\n' "$out" | sed 1d)" "# camera 046d:0944
# MX Brio, profile PROFILE_NAME_DEFAULT
$OPLUS_LINES" || return 1
    # what is left out is said on stderr, and only there: the file has the settings
    expect "what is left out is said on stderr" "$(cat err)" "$OPLUS_NOTES" || return 1
    hasnt "no notice in the settings" "$out" "# skipped" || return 1
    both=$("$BIN" import optionsplus optionsplus.db 2>&1)
    expect "every notice once with both streams on one pipe" "$(printf '%s\n' "$both" | grep -c '^# skipped:')" 3 || return 1
    expect "the same text without the notices" "$(printf '%s\n' "$both" | grep -v '^# skipped:')" "$out" || return 1
    # no camera is needed, and --camera has nothing to choose
    out2=$(env -u BRIOCTL_FAKE "$BIN" --camera 3 import optionsplus optionsplus.db 2> /dev/null); rc=$?
    expect "without a camera status" "$rc" 0 || return 1
    expect "without a camera" "$(printf '%s\n' "$out2" | sed 1d)" "$(printf '%s\n' "$out" | sed 1d)"
}

t_import_default_path() {
    dir="$HOME/Library/Application Support/LogiOptionsPlus"
    out=$("$BIN" import optionsplus 2>&1); rc=$?
    expect "status without the app" "$rc" 1 || return 1
    expect "message" "$out" "Logi Options+ settings not found at $dir/settings.db" || return 1
    mkdir -p "$dir" && cp optionsplus.db "$dir/settings.db" || return 1
    out=$("$BIN" import optionsplus 2> /dev/null); rc=$?
    expect "status" "$rc" 0 || return 1
    expect "the settings" "$(printf '%s\n' "$out" | grep -v '^#')" "$OPLUS_LINES"
}

t_import_save() {
    out=$("$BIN" import optionsplus optionsplus.db --save fromapp 2> err); rc=$?
    expect "status" "$rc" 0 || return 1
    expect "stdout" "$out" "imported 20 settings to $HOME/.config/brioctl/fromapp" || return 1
    expect "what is left out is on stderr" "$(cat err)" "$OPLUS_NOTES" || return 1
    expect "the file" "$(sed 1d "$HOME/.config/brioctl/fromapp")" "$("$BIN" import optionsplus optionsplus.db 2> /dev/null | sed 1d)" || return 1
    hasnt "no notice in the file" "$(cat "$HOME/.config/brioctl/fromapp")" "# skipped" || return 1
    expect "every notice once with both streams on one pipe" \
        "$("$BIN" import optionsplus optionsplus.db --save again 2>&1 | grep -c '^# skipped:')" 3 || return 1
    has "profiles lists it" "$("$BIN" profiles)" "  fromapp" || return 1
    # --save=NAME with a path, and the DB after it
    out=$("$BIN" import optionsplus --save="$PWD/second" optionsplus.db 2> /dev/null); rc=$?
    expect "path status" "$rc" 0 || return 1
    expect "path stdout" "$out" "imported 20 settings to $PWD/second" || return 1
    expect "path file" "$(sed 1d second)" "$(sed 1d "$HOME/.config/brioctl/fromapp")" || return 1
    # the name of a built-in preset is refused, as for save, and nothing is written
    out=$("$BIN" import optionsplus optionsplus.db --save neutral 2>&1); rc=$?
    expect "preset status" "$rc" 1 || return 1
    has "preset message" "$out" "neutral is a built-in preset, choose another name" || return 1
    [ ! -e "$HOME/.config/brioctl/neutral" ] || { echo "# a file called neutral was written"; return 1; }
    # and nothing is written when the import fails
    "$BIN" import optionsplus nosuch.db --save never > /dev/null 2>&1; rc=$?
    expect "failure status" "$rc" 1 || return 1
    [ ! -e "$HOME/.config/brioctl/never" ] || { echo "# a file was written for a failed import"; return 1; }
}

t_import_output_applies() {
    "$BIN" import optionsplus optionsplus.db --save fromapp > /dev/null 2>&1 || return 1
    # change what the file sets, so that apply has something to write
    "$BIN" fov 65 zoom 200 warmth 40 tint 30 vibrance 100 expcomp 100 flicker 50 brightness 50 contrast 60 \
        saturation 70 sharpness 80 priority fps hdr off showmode off micgain 0.5 pan 5 af off awb off > /dev/null || return 1
    out=$(BRIOCTL_FAKE_TRACE=1 "$BIN" apply fromapp 2> trace); rc=$?
    expect "apply status" "$rc" 0 || return 1
    expect "apply prints the settings that were imported" "$out" "$OPLUS_LINES" || return 1
    expect "registers written" "$(sed -n 's/^fake SET_CUR //p' trace)" "unit $VIDEOPIPE sel 5 01
unit $VIDEOPIPE sel 13 01
unit $PU sel 1 0100
unit $VIDEOPIPE sel 21 3e
unit $VIDEOPIPE sel 18 32
unit $VIDEOPIPE sel 20 80
unit $VIDEOPIPE sel 19 80
unit $CT sel 11 7300
unit $CT sel 13 0000000000000000
unit $CT sel 3 01
unit $PU sel 5 02
unit $PU sel 2 8000
unit $PU sel 3 8000
unit $PU sel 7 8000
unit $PU sel 8 8000
unit $PU sel 11 01
unit $CT sel 8 01" || return 1
    has "mic volume" "$(cat trace)" "fake SET_MICGAIN 0.2785" || return 1
    # all of it is on the camera now
    got=$(for n in $(printf '%s\n' "$OPLUS_LINES" | cut -d' ' -f1); do echo "$n $("$BIN" get $n)"; done)
    expect "camera after apply" "$got" "$OPLUS_LINES" || return 1
    # there is no mic line in the file: the camera microphone is left as it was
    noline "no mic line" "$(cat "$HOME/.config/brioctl/fromapp")" mic
}

t_import_errors() {
    out=$("$BIN" import optionsplus "$PWD/nosuch.db" 2> err); rc=$?
    expect "missing status" "$rc" 1 || return 1
    expect "missing stdout" "$out" "" || return 1
    expect "missing message" "$(cat err)" "Logi Options+ settings not found at $PWD/nosuch.db" || return 1
    echo "just text" > notdb.db
    out=$("$BIN" import optionsplus notdb.db 2>&1); rc=$?
    expect "not a database status" "$rc" 1 || return 1
    has "not a database message" "$out" "notdb.db is not a SQLite database" || return 1
    mkdir adir
    "$BIN" import optionsplus adir > /dev/null 2>&1; rc=$?
    expect "directory status" "$rc" 1 || return 1
    for args in "" "logitune" "optionsplus --save" "optionsplus a b" "optionsplus --bogus" "optionsplus --save x --save y"; do
        "$BIN" import $args > /dev/null 2>&1; rc=$?
        expect "usage error for '$args'" "$rc" 2 || return 1
    done
    has "unknown source" "$("$BIN" import logitune 2>&1)" "unknown source logitune" || return 1
    has "usage lists import" "$("$BIN" --help)" "brioctl import optionsplus [DB] [--save NAME]"
}

t_import_no_camera() {
    oplus_python || return 77
    mkdb nocam.db 'd["ever_connected_devices"]["devices"] = []' || return 1
    out=$("$BIN" import optionsplus nocam.db --save x 2>&1); rc=$?
    expect "status" "$rc" 1 || return 1
    has "message" "$out" "no camera found in the Logi Options+ settings at nocam.db" || return 1
    [ ! -e "$HOME/.config/brioctl/x" ] || { echo "# a file was written"; return 1; }
    # only a headset (no CAMERA entry) is no camera either
    mkdb headset.db 'd["ever_connected_devices"]["devices"][0]["deviceType"] = "HEADSET"' || return 1
    "$BIN" import optionsplus headset.db > /dev/null 2>&1; rc=$?
    expect "headset status" "$rc" 1 || return 1
    # a camera the profile has no cards for gives nothing to import
    mkdb nocards.db 'P["assignments"] = []' || return 1
    out=$("$BIN" import optionsplus nocards.db 2>&1); rc=$?
    expect "no cards status" "$rc" 1 || return 1
    has "no cards message" "$out" "nothing to import from the Logi Options+ settings at nocards.db" || return 1
    mkdb noprofile.db 'd["profile_keys"] = []' || return 1
    has "no profile message" "$("$BIN" import optionsplus noprofile.db 2>&1)" "no profile found"
}

t_import_unexpected_schema() {
    oplus_python || return 77
    python3 -I - <<'EOF' || return 1
import sqlite3
for name, doc in (("nodata.db", None), ("empty.db", ""), ("notjson.db", b"not json at all"),
                  ("v3.db", b'{"schema_version": 3, "profile_keys": []}')):
    c = sqlite3.connect(name)
    if doc is None:
        c.execute("CREATE TABLE other(a)")
    else:
        c.execute("CREATE TABLE data(_id INTEGER PRIMARY KEY, file BLOB NOT NULL)")
        if doc:
            c.execute("INSERT INTO data(file) VALUES (?)", (doc,))
    c.commit()
EOF
    for f in nodata empty notjson v3; do
        out=$("$BIN" import optionsplus $f.db 2>&1); rc=$?
        expect "$f status" "$rc" 1 || return 1
        has "$f message" "$out" "$f.db: unexpected layout" || return 1
    done
    has "no data table" "$("$BIN" import optionsplus nodata.db 2>&1)" "no such table: data (schema_version unknown, brioctl knows 26)" || return 1
    has "no document" "$("$BIN" import optionsplus empty.db 2>&1)" "no settings document in the data table" || return 1
    has "not JSON" "$("$BIN" import optionsplus notjson.db 2>&1)" "the settings document is not JSON" || return 1
    has "schema version found" "$("$BIN" import optionsplus v3.db 2>&1)" "no list of devices (schema_version 3, brioctl knows 26)" || return 1
    # another schema version with the layout this knows: imported, with a warning
    mkdb v27.db 'd["schema_version"] = 27' || return 1
    out=$("$BIN" import optionsplus v27.db 2> err); rc=$?
    expect "schema 27 status" "$rc" 0 || return 1
    expect "schema 27 settings" "$(printf '%s\n' "$out" | grep -v '^#')" "$OPLUS_LINES" || return 1
    hasnt "schema 27 warning not in the file" "$out" "# check:" || return 1
    expect "schema 27 warning on stderr, once" "$(grep -c '^# check: Logi Options+ settings schema 27, brioctl was written for 26' err)" 1
}

t_import_leaves_the_database_alone() {
    mkdir ro && cp optionsplus.db ro/settings.db || return 1
    chmod 444 ro/settings.db && chmod 555 ro
    trap 'chmod -R u+w ro 2> /dev/null' EXIT
    before=$(ls -lAT ro; shasum -a 256 ro/settings.db; stat -f '%m %z' ro/settings.db)
    "$BIN" import optionsplus ro/settings.db > out 2> /dev/null; rc=$?
    expect "status" "$rc" 0 || return 1
    expect "settings" "$(grep -vc '^#' out)" 20 || return 1
    expect "database, its directory and times unchanged" "$(ls -lAT ro; shasum -a 256 ro/settings.db; stat -f '%m %z' ro/settings.db)" "$before" || return 1
    # the database of a running app: WAL mode, with a -wal file beside it. Nothing is created, changed or locked.
    oplus_python || return 77
    chmod u+w ro ro/settings.db
    python3 -I - <<'EOF' || return 1
import sqlite3
c = sqlite3.connect("ro/settings.db")
assert c.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
c.close()
assert open("ro/settings.db", "rb").read()[18:20] == b"\x02\x02"
EOF
    printf 'frames the app has not written to the database yet' > ro/settings.db-wal
    chmod 444 ro/settings.db ro/settings.db-wal && chmod 555 ro
    before=$(ls -lAT ro; shasum -a 256 ro/*; stat -f '%m %z' ro/*)
    "$BIN" import optionsplus ro/settings.db > out 2> err; rc=$?
    expect "WAL status" "$rc" 0 || return 1
    expect "WAL settings" "$(grep -v '^#' out)" "$OPLUS_LINES" || return 1
    has "the wal is mentioned" "$(cat err)" "settings.db-wal exists" || return 1
    expect "WAL: nothing created or changed" "$(ls -lAT ro; shasum -a 256 ro/*; stat -f '%m %z' ro/*)" "$before"
}

t_import_picks_the_camera() {
    oplus_python || return 77
    # a second camera, listed first, with cards of its own (its fov is 65): the MX Brio is still the one
    other='
import copy
dev = d["ever_connected_devices"]["devices"]
cam = copy.deepcopy(dev[0])
cam["udid"], cam["slotPrefix"] = "091d,11111111111111111111111111111111", "brio-705-091d"
extra = copy.deepcopy(P["assignments"])
for a in extra:
    a["slotId"] = a["slotId"].replace("brio-700-0944", "brio-705-091d")
    if a["slotId"].endswith("_crop_settings"):
        for pr in a["card"]["cropSettingsGroup"]["cropPresets"]:
            pr["cropSettings"]["fov"] = 65
P["assignments"] += extra
dev.insert(0, cam)
'
    mkdb two.db "$other" || return 1
    out=$("$BIN" import optionsplus two.db 2> /dev/null)
    has "MX Brio picked" "$out" "# MX Brio (of 2 cameras in the settings), profile PROFILE_NAME_DEFAULT" || return 1
    has "its camera line" "$out" "# camera 046d:0944" || return 1
    has "its fov" "$out" "fov 78" || return 1
    # no MX Brio: the first camera, and the header says so
    mkdb first.db "$other
dev.pop(1)
" || return 1
    out=$("$BIN" import optionsplus first.db 2> /dev/null)
    has "its camera line" "$out" "# camera 046d:091d" || return 1
    has "its fov" "$out" "fov 65" || return 1
    has "no MX Brio, one camera" "$out" "# Logitech 091d, profile PROFILE_NAME_DEFAULT" || return 1
    mkdb first2.db "$other
dev.pop(1)
dev.append(copy.deepcopy(dev[0]))
dev[1]['slotPrefix'] = 'brio-x'
" || return 1
    out=$("$BIN" import optionsplus first2.db 2> /dev/null)
    has "first picked" "$out" "# Logitech 091d (the first of 2 cameras in the settings, no MX Brio), profile PROFILE_NAME_DEFAULT" || return 1
    # the file names the model it was made for, so apply warns about another one
    "$BIN" import optionsplus first.db --save other > /dev/null 2>&1 || return 1
    has "apply warns about another model" "$("$BIN" apply other 2>&1)" "warning: these settings were saved from camera 046d:091d, this is 046d:0944"
}

t_import_profile_and_preset() {
    oplus_python || return 77
    # PROFILE_NAME_DEFAULT wins over an earlier profile; without it the first profile is used
    two='
import copy
q = copy.deepcopy(P)
q["name"] = "Work"
for a in q["assignments"]:
    if a["slotId"].endswith("_crop_settings"):
        for pr in a["card"]["cropSettingsGroup"]["cropPresets"]:
            pr["cropSettings"]["fov"] = 65
d["profile-1"] = q
d["profile_keys"].insert(0, "profile-1")
'
    mkdb prof.db "$two" || return 1
    out=$("$BIN" import optionsplus prof.db 2> /dev/null)
    has "default profile" "$out" "fov 78" || return 1
    has "its name" "$out" "profile PROFILE_NAME_DEFAULT" || return 1
    mkdb prof2.db "$two
P['name'] = 'Home'
" || return 1
    out=$("$BIN" import optionsplus prof2.db 2> /dev/null)
    has "first profile" "$out" "fov 65" || return 1
    has "its name" "$out" "profile Work" || return 1
    # the preset a card selects; if it names none, the user's own
    mkdb preset.db 'card("crop")["cropSettingsGroup"]["selectedPresetName"] = "MATISSE_PRESETS_CROP_DEFAULT"' || return 1
    out=$("$BIN" import optionsplus preset.db 2> /dev/null)
    has "selected preset" "$out" "fov 90" || return 1
    has "its zoom" "$out" "zoom 100" || return 1
    mkdb preset2.db 'card("crop")["cropSettingsGroup"]["selectedPresetName"] = "NO_SUCH_PRESET"' || return 1
    out=$("$BIN" import optionsplus preset2.db 2> /dev/null)
    has "user defined preset" "$out" "fov 78" || return 1
    has "its zoom" "$out" "zoom 115" || return 1
    mkdb preset3.db '
g = card("crop")["cropSettingsGroup"]
g["selectedPresetName"] = "NO_SUCH_PRESET"
for pr in g["cropPresets"]:
    pr.pop("userDefined", None)
' || return 1
    out=$("$BIN" import optionsplus preset3.db 2>&1)
    has "no preset" "$out" "# skipped: crop settings (none for this camera in the profile)" || return 1
    noline "no fov" "$out" fov
}

t_import_what_it_does_not_trust() {
    oplus_python || return 77
    mkdb odd.db '
sel("camera")["exposure"] = {"mode": "MANUAL", "value": 120}
sel("camera")["gain"] = {"mode": "MANUAL", "value": 300}
sel("video")["whiteBalance"] = {"mode": "MANUAL", "value": 4500}
sel("video").pop("vibrance")
sel("video").pop("tint")
sel("camera").pop("hdr")
sel("crop").pop("showMode")
sel("crop")["fov"] = 70
sel("crop")["zoom"] = {"mode": "MANUAL", "value": 500}
sel("crop")["pan"] = {"mode": "MANUAL", "value": 12}
sel("crop").pop("tilt")
sel("crop")["rightsight"]["enabled"] = True
sel("crop")["videoStabilization"] = True
sel("focus")["focus"] = {"mode": "MANUAL", "value": 40}
sel("microphone")["volume"]["gain"] = 1.5
sel("microphone")["noiseSuppression"] = True
card("global")["webcamGlobalSettings"]["antiFlicker"] = 0
' || return 1
    out=$("$BIN" import optionsplus odd.db 2> err); rc=$?
    expect "status" "$rc" 0 || return 1
    for n in ae exposure gain focus af fov zoom pan flicker vibrance tint hdr showmode micgain; do
        noline "no $n line" "$out" "$n" || return 1
    done
    has "tilt is at the centre" "$out" "tilt 0" || return 1
    has "manual white balance" "$out" "awb off
wb 4500" || return 1
    for s in "ae, exposure, gain (manual exposure" "af, focus (manual focus" "fov (70 has no equivalent)" \
        "zoom (500 is outside 100-400)" "pan (value 12 is in units brioctl does not know)" "flicker (0 has no equivalent)" \
        "vibrance (not in the Logi Options+ settings)" "micgain (no input volume between 0 and 1" \
        "rightsight (on in Logi Options+" "videoStabilization (no brioctl equivalent)" "noiseSuppression (no brioctl equivalent)"; do
        has "skipped $s" "$(cat err)" "# skipped: $s" || return 1
    done
    hasnt "an optional field that is not set is no news" "$(cat err)" "# skipped: tint" || return 1
    hasnt "hdr" "$(cat err)" "# skipped: hdr" || return 1
    hasnt "showmode" "$(cat err)" "# skipped: showmode" || return 1
    has "the warning is on stderr" "$(cat err)" "# check: wb is taken as kelvin" || return 1
    hasnt "no notice in the settings" "$out" "# skipped" || return 1
    hasnt "no warning in the settings" "$out" "# check:" || return 1
    # a white balance outside the camera's range is not half imported
    mkdb wb.db 'sel("video")["whiteBalance"] = {"mode": "MANUAL", "value": 9000}' || return 1
    out=$("$BIN" import optionsplus wb.db 2> err)
    noline "no awb" "$out" awb || return 1
    noline "no wb" "$out" wb || return 1
    has "why" "$(cat err)" "# skipped: awb, wb (manual white balance 9000 is outside 2800-7500)" || return 1
    # what is imported is still a settings file apply takes (the fake camera does not link awb to wb: allow wb now)
    "$BIN" import optionsplus odd.db --save odd > /dev/null 2>&1 || return 1
    edit_reg "$PU" 10 info 03
    "$BIN" apply odd > out 2> err; rc=$?
    expect "apply status" "$rc" 0 || return 1
    expect "camera white balance" "$("$BIN" get wb)" 4500 || return 1
    expect "camera awb" "$("$BIN" get awb)" off
}

t_import_text_from_the_file_is_harmless() {
    oplus_python || return 77
    mkdb evil.db '
sel("crop")["evil\nfov 999"] = 1
sel("video")["x\rmic off"] = 1
d["analytics_app_version"] = "2.9\nmic off"
P["name"] = "A\nmic off"
' || return 1
    out=$("$BIN" import optionsplus evil.db 2>&1); rc=$?
    expect "status" "$rc" 0 || return 1
    noline "no mic line" "$out" mic || return 1
    noline "no fov 999" "$out" "fov 999" || return 1
    bad=$(printf '%s\n' "$out" | grep -vE '^# |^[a-z]+ [-0-9.a-z]+$')
    expect "every line is a comment or a setting" "$bad" "" || return 1
    has "the key is shown cut down" "$out" "# skipped: evil?fov 999 (no brioctl equivalent)" || return 1
    has "the version and the profile too" "$out" "# imported from Logi Options+ 2.9?mic off on " || return 1
    has "the profile" "$out" ", profile A?mic off"
}

t_optionsplus_fixture_is_anonymous() {
    # nothing of an account or a person in the public fixtures
    for f in "$OPLUS" "$OPLUS_JSON"; do
        if LC_ALL=C grep -aiE 'token|refresh|access|eyJ|secret|password|passwd|e-?mail|bearer|cookie|session|[A-Za-z0-9._-]+@[A-Za-z0-9.-]+' "$f" > /dev/null; then
            echo "# $f has something that looks like account data"
            return 1
        fi
        ids=$(LC_ALL=C grep -aoE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "$f" | sort -u)
        expect "ids in $f" "$ids" "00000000-0000-0000-0000-000000000000" || return 1
        expect "serial in $f" "$(LC_ALL=C grep -ao 'serialNumber": "[^"]*"' "$f" | sort -u)" 'serialNumber": "XXXXXXXXXXXX"' || return 1
        hex=$(LC_ALL=C grep -aoE '[0-9a-fA-F]{20,}' "$f" | sort -u | tr -d '0')
        expect "long hex strings in $f" "$hex" "" || return 1
    done
    oplus_python || return 77
    python3 -I - "$OPLUS" "$OPLUS_JSON" <<'EOF'
import sqlite3, sys
c = sqlite3.connect("file:%s?mode=ro&immutable=1" % sys.argv[1], uri=True)
assert c.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
assert c.execute("PRAGMA freelist_count").fetchone()[0] == 0, "free pages can hold old data"
assert c.execute("SELECT count(*) FROM data").fetchone()[0] == 1
assert c.execute("SELECT count(*) FROM snapshots").fetchone()[0] == 0
assert c.execute("SELECT file FROM data").fetchone()[0] == open(sys.argv[2], "rb").read(), "the .db and the .json differ"
assert c.execute("SELECT _date_created FROM data").fetchone()[0] == "2000-01-01 00:00:00"
EOF
}

# --- review fixes: privacy, watch and other models, strict re-identification, numbers, decimals, bmControls ---------------

t_privacy_is_not_a_preference() {
    export BRIOCTL_FAKE=$PWD/extra.snap
    edit_reg "$CT" 17 info 03  # this camera lets the shutter be set
    # by hand it works
    expect "privacy on" "$("$BIN" privacy on)" "privacy on" || return 1
    expect "get privacy" "$("$BIN" get privacy)" on || return 1
    # save never writes it, whatever its state, and still saves the rest
    "$BIN" save "$PWD/s" > /dev/null || return 1
    noline "save leaves privacy out" "$(cat s)" privacy || return 1
    has "the rest is saved" "$(cat s)" "brightness " || return 1
    # defaults does not reset it
    BRIOCTL_FAKE_TRACE=1 "$BIN" defaults > /dev/null 2> trace
    [ "$(setcurs trace)" -gt 0 ] || { echo "# defaults wrote nothing at all"; return 1; }
    hasnt "defaults does not touch privacy" "$(grep SET_CUR trace)" "unit $CT sel 17" || return 1
    expect "privacy is still on" "$("$BIN" get privacy)" on || return 1
    # watch applies a file without it, whether the camera connected or video started, and says so
    printf 'privacy off\nzoom 130\n' > settings
    BRIOCTL_FAKE_TRACE=1 "$BIN" --test-reapply "$PWD/settings" > out 2> trace || return 1
    expect "connect writes zoom only" "$(grep -o 'unit [0-9]* sel [0-9]*' trace | tr '\n' ' ')" "unit $CT sel 11 " || return 1
    has "and says what it left" "$(cat out)" "not applied by watch, set by hand only: privacy" || return 1
    printf 'privacy off\nzoom 140\n' > settings
    BRIOCTL_FAKE_TRACE=1 "$BIN" --test-reapply "$PWD/settings" video > out 2> trace || return 1
    expect "video start writes zoom only" "$(grep -o 'unit [0-9]* sel [0-9]*' trace | tr '\n' ' ')" "unit $CT sel 11 " || return 1
    expect "privacy is still on after watch" "$("$BIN" get privacy)" on || return 1
    # a file somebody wrote with privacy in it is applied by apply, which is an explicit act
    "$BIN" apply "$PWD/settings" > /dev/null || return 1
    expect "apply sets it" "$("$BIN" get privacy)" off || return 1
    # a camera that does not allow writing it keeps saying so
    edit_reg "$CT" 17 info 01
    out=$("$BIN" privacy on 2>&1); rc=$?
    expect "read-only privacy status" "$rc" 1
}

t_watch_wont_apply_to_another_model() {
    printf '# camera 046d:0944 ABC\nzoom 140\nbrightness 100\n' > other
    export BRIOCTL_FAKE=$PWD/generic.snap
    BRIOCTL_FAKE_TRACE=1 "$BIN" --test-reapply "$PWD/other" > out 2> trace; rc=$?
    expect "status" "$rc" 0 || return 1
    has "the reason" "$(cat out)" \
        "settings were saved from 046d:0944; not applying them to 1234:5678 (save them from this camera)" || return 1
    expect "said once" "$(grep -c 'not applying them' out)" 1 || return 1
    hasnt "no apply line" "$(cat out)" "applied" || return 1
    expect "nothing written" "$(setcurs trace)" 0 || return 1
    expect "zoom unchanged" "$("$BIN" get zoom)" 115 || return 1
    # video start: nothing is applied, and the connect already said why
    "$BIN" --test-reapply "$PWD/other" video > out 2>&1 || return 1
    hasnt "not said again" "$(cat out)" "not applying" || return 1
    expect "still unchanged" "$("$BIN" get zoom)" 115 || return 1
    # by hand it stays a warning, and what fits is applied
    out=$("$BIN" apply "$PWD/other" 2>&1); rc=$?
    expect "apply status" "$rc" 0 || return 1
    has "apply warns" "$out" "warning: these settings were saved from camera 046d:0944, this is 1234:5678" || return 1
    expect "apply applies" "$("$BIN" get zoom)" 140 || return 1
    # the same ids with another serial number, no header, and a file for the MX Brio on an MX Brio are applied
    printf '# camera 1234:5678 SOMEBODYELSE\nzoom 150\n' > same
    "$BIN" --test-reapply "$PWD/same" > out 2>&1 || return 1
    has "same ids" "$(cat out)" "applied (1 changed)" || return 1
    printf 'zoom 160\n' > plain
    "$BIN" --test-reapply "$PWD/plain" > out 2>&1 || return 1
    has "no header" "$(cat out)" "applied (1 changed)" || return 1
    export BRIOCTL_FAKE=$PWD/camera.snap
    printf '# camera 046d:0944 ABC\nzoom 170\n' > mx
    "$BIN" --test-reapply "$PWD/mx" > out 2>&1 || return 1
    has "MX Brio file on an MX Brio" "$(cat out)" "applied (1 changed)" || return 1
    # and the other way round: a file from a generic camera on the MX Brio
    printf '# camera 1234:5678\nzoom 180\n' > gen
    "$BIN" --test-reapply "$PWD/gen" > out 2>&1 || return 1
    has "generic file on an MX Brio" "$(cat out)" \
        "settings were saved from 1234:5678; not applying them to 046d:0944" || return 1
    expect "zoom" "$("$BIN" get zoom)" 170
}

t_one_apply_per_video_start() {
    printf 'zoom 130\n' > settings
    export BRIOCTL_FAKE_SETTLE=0.05
    # SEQ: t = a video start is seen (by HID or by CoreMediaIO), w = time passes (the apply), l = a long time passes
    for seq in tw ttw tttw twtw twttw; do
        out=$("$BIN" --test-video-trigger "$PWD/settings" $seq 2>&1) || return 1
        expect "applies for $seq" "$(printf '%s\n' "$out" | grep -c 'video started')" 1 || return 1
    done
    out=$("$BIN" --test-video-trigger "$PWD/settings" w 2>&1) || return 1
    expect "nothing without a start" "$out" "" || return 1
    # the second source is only ignored for a moment after the apply: a start later on is a new one
    out=$("$BIN" --test-video-trigger "$PWD/settings" twltw 2>&1) || return 1
    expect "two starts, two applies" "$(printf '%s\n' "$out" | grep -c 'video started')" 2
}

t_camera_found_again_by_serial_or_place() {
    printf 'zoom 150\n' > settings
    # a serial number finds the camera on another port
    sed 's/^serial .*/serial SERIAL0001/' camera.snap > a.snap
    cp a.snap moved.snap
    printf 'location 0x500000\n' >> moved.snap
    BRIOCTL_FAKE=$PWD/a.snap BRIOCTL_FAKE_AFTER=$PWD/moved.snap "$BIN" --test-reapply "$PWD/settings" > out 2>&1
    has "found on the other port" "$(cat out)" "applied (1 changed)" || return 1
    has "and written there" "$(grep '^reg 1 11 ' moved.snap)" "cur 9600" || return 1
    has "its location is kept" "$(cat moved.snap)" "location 0x500000" || return 1
    # without one the place is all there is: another place is no camera
    grep -v '^serial ' camera.snap > b.snap
    cp b.snap away.snap
    printf 'location 0x500000\n' >> away.snap
    BRIOCTL_FAKE=$PWD/b.snap BRIOCTL_FAKE_AFTER=$PWD/away.snap "$BIN" --test-reapply "$PWD/settings" > out 2>&1
    has "not connected" "$(cat out)" "MX Brio is not connected" || return 1
    has "nothing applied" "$(cat out)" "could not apply all settings (0 changed)" || return 1
    has "nothing written" "$(grep '^reg 1 11 ' away.snap)" "cur 7300" || return 1
    cp b.snap same.snap
    BRIOCTL_FAKE=$PWD/b.snap BRIOCTL_FAKE_AFTER=$PWD/same.snap "$BIN" --test-reapply "$PWD/settings" > out 2>&1
    has "same place, same camera" "$(cat out)" "applied (1 changed)" || return 1
    # two cameras of one make without serial numbers: not "the first one"
    cp b.snap c.snap
    printf 'location 0x200000\n' >> c.snap
    cp b.snap d.snap
    printf 'location 0x300000\n' >> d.snap
    cp b.snap e.snap
    printf 'location 0x400000\n' >> e.snap
    BRIOCTL_FAKE=$PWD/b.snap:$PWD/c.snap BRIOCTL_FAKE_AFTER=$PWD/d.snap:$PWD/e.snap \
        "$BIN" --camera 2 --test-reapply "$PWD/settings" > out 2>&1
    has "neither is the second camera" "$(cat out)" "MX Brio is not connected" || return 1
    has "d untouched" "$(grep '^reg 1 11 ' d.snap)" "cur 7300" || return 1
    has "e untouched" "$(grep '^reg 1 11 ' e.snap)" "cur 7300" || return 1
    # the second one is found where it was
    BRIOCTL_FAKE=$PWD/b.snap:$PWD/c.snap BRIOCTL_FAKE_AFTER=$PWD/d.snap:$PWD/c.snap \
        "$BIN" --camera 2 --test-reapply "$PWD/settings" > out 2>&1
    has "the second one where it was" "$(cat out)" "applied (1 changed)" || return 1
    has "it got the write" "$(grep '^reg 1 11 ' c.snap)" "cur 9600" || return 1
    has "the first did not" "$(grep '^reg 1 11 ' b.snap)" "cur 7300"
}

t_numbers_need_a_known_range() {
    drop_field "$CT" 11 max  # zoom: GET_MAX does not answer
    BRIOCTL_FAKE_TRACE=1 "$BIN" zoom 130 > out 2> trace; rc=$?
    expect "no max status" "$rc" 1 || return 1
    has "no max message" "$(cat trace)" "zoom: range unknown, not writing" || return 1
    expect "no max, no write" "$(setcurs trace)" 0 || return 1
    cp "$FIXTURE" "$BRIOCTL_FAKE"
    drop_field "$CT" 11 min
    out=$("$BIN" zoom 130 2>&1); rc=$?
    expect "no min status" "$rc" 1 || return 1
    has "no min message" "$out" "range unknown, not writing" || return 1
    expect "zoom unchanged" "$("$BIN" get zoom)" 115 || return 1
    # a Logitech number, and pan and tilt (one control for two fields)
    cp "$FIXTURE" "$BRIOCTL_FAKE"
    drop_field "$VIDEOPIPE" 21 min
    drop_field "$CT" 13 max
    for cmd in "warmth 60" "pan 5" "tilt 5"; do
        out=$(BRIOCTL_FAKE_TRACE=1 "$BIN" $cmd 2>&1); rc=$?
        expect "$cmd status" "$rc" 1 || return 1
        has "$cmd message" "$out" "range unknown, not writing" || return 1
        hasnt "$cmd write" "$out" "fake SET_CUR" || return 1
    done
    # a named value does not need a range
    drop_field "$PU" 1 min
    drop_field "$PU" 1 max
    expect "hdr off without a range" "$("$BIN" hdr off)" "hdr off" || return 1
    # apply refuses it too, and save does not write what apply would refuse
    drop_field "$CT" 11 max
    printf 'zoom 130\nbrightness 100\n' > settings
    out=$("$BIN" apply "$PWD/settings" 2>&1); rc=$?
    expect "apply status" "$rc" 1 || return 1
    has "apply says why" "$out" "zoom: range unknown, not writing" || return 1
    expect "the rest is applied" "$("$BIN" get brightness)" 100 || return 1
    "$BIN" save "$PWD/s" > /dev/null || return 1
    noline "zoom is not saved" "$(cat s)" zoom || return 1
    noline "warmth is not saved" "$(cat s)" warmth || return 1
    noline "pan is not saved" "$(cat s)" pan || return 1
    has "named values still are" "$(cat s)" "hdr off" || return 1
    has "and numbers with a range" "$(cat s)" "brightness 100" || return 1
    "$BIN" defaults > /dev/null 2>&1
    expect "defaults leaves them alone too" "$("$BIN" get warmth)" 62
}

t_value_must_fit_the_control() {
    # ranges as wide as the field: 1 byte unsigned (warmth), 2 bytes unsigned (contrast), 2 bytes signed (brightness)
    edit_reg "$VIDEOPIPE" 21 max ff
    edit_reg "$PU" 3 max ffff
    edit_reg "$PU" 2 min 0080
    edit_reg "$PU" 2 max ff7f
    for cmd in "warmth 256" "contrast 65536" "brightness 32768" "brightness -32769"; do
        out=$(BRIOCTL_FAKE_TRACE=1 "$BIN" $cmd 2>&1); rc=$?
        expect "$cmd status" "$rc" 1 || return 1
        has "$cmd message" "$out" "out of range" || return 1
        hasnt "$cmd write" "$out" "fake SET_CUR" || return 1
    done
    BRIOCTL_FAKE_TRACE=1 "$BIN" warmth 255 contrast 65535 brightness -32768 > out 2> trace; rc=$?
    expect "the largest values status" "$rc" 0 || return 1
    has "warmth" "$(cat trace)" "SET_CUR unit $VIDEOPIPE sel 21 ff" || return 1
    has "contrast" "$(cat trace)" "SET_CUR unit $PU sel 3 ffff" || return 1
    has "brightness" "$(cat trace)" "SET_CUR unit $PU sel 2 0080" || return 1
    expect "brightness back" "$("$BIN" get brightness)" -32768 || return 1
    "$BIN" brightness 32767 > /dev/null || return 1
    expect "brightness top" "$("$BIN" get brightness)" 32767
}

t_numbers_that_overflow_are_refused() {
    for cmd in "pan 9999999999999999999999" "pan -9999999999999999999999" "pan 3000000000000000" \
        "pan 99999999999999999999" "tilt 9999999999999999999999" "zoom 9999999999999999999999" \
        "zoom 9223372036854775808" "zoom -9223372036854775809" "zoom 9223372036854775807" \
        "pan 9223372036854775807"; do
        out=$(BRIOCTL_FAKE_TRACE=1 "$BIN" $cmd 2>&1); rc=$?
        expect "$cmd status" "$rc" 1 || return 1
        hasnt "$cmd write" "$out" "fake SET_CUR" || return 1
    done
    has "overflow is a bad value" "$("$BIN" pan 9999999999999999999999 2>&1)" \
        "pan: bad value 9999999999999999999999" || return 1
    has "zoom overflow is a bad value too" "$("$BIN" zoom 9999999999999999999999 2>&1)" \
        "zoom: bad value 9999999999999999999999" || return 1
    has "a long that fits is out of range" "$("$BIN" zoom 9223372036854775807 2>&1)" "out of range (100-400)" || return 1
    expect "pan unchanged" "$("$BIN" get pan)" 0 || return 1
    expect "zoom unchanged" "$("$BIN" get zoom)" 115
}

t_decimal_degrees() {
    out=$(BRIOCTL_FAKE_TRACE=1 "$BIN" pan 1.99 2> trace); rc=$?
    expect "pan 1.99 status" "$rc" 0 || return 1
    expect "pan 1.99 output" "$out" "pan 1.99" || return 1
    has "7164 units, tilt kept" "$(cat trace)" "fake SET_CUR unit $CT sel 13 fc1b000000000000" || return 1
    expect "get pan" "$("$BIN" get pan)" 1.99 || return 1
    # what save writes, apply reads back
    "$BIN" tilt -3.5 > /dev/null || return 1
    "$BIN" save "$PWD/s" > /dev/null || return 1
    has "saved pan" "$(cat s)" "pan 1.99" || return 1
    has "saved tilt" "$(cat s)" "tilt -3.50" || return 1
    "$BIN" pan 5 tilt 0 > /dev/null || return 1
    "$BIN" apply "$PWD/s" > /dev/null || return 1
    expect "pan after apply" "$("$BIN" get pan)" 1.99 || return 1
    expect "tilt after apply" "$("$BIN" get tilt)" -3.50 || return 1
    # rounded to the nearest register unit (1/3600 degree)
    expect "below half a unit" "$("$BIN" pan 0.0001)" "pan 0" || return 1
    expect "above half a unit" "$("$BIN" pan 0.0002)" "pan 0.0003" || return 1
    expect "negative" "$("$BIN" pan -1.99)" "pan -1.99" || return 1
    expect "no leading digit" "$("$BIN" pan .5)" "pan 0.50" || return 1
    expect "whole degrees as before" "$("$BIN" pan 7)" "pan 7" || return 1
    # every register value reads back as itself: 7165 units is 1.99028 degrees
    edit_reg "$CT" 13 cur fd1b000000000000
    expect "a unit that needs four decimals" "$("$BIN" get pan)" 1.9903 || return 1
    "$BIN" save "$PWD/t" > /dev/null || return 1
    has "saved with four decimals" "$(cat t)" "pan 1.9903" || return 1
    "$BIN" pan 0 > /dev/null || return 1
    "$BIN" apply "$PWD/t" > /dev/null || return 1
    "$BIN" snapshot > out.snap || return 1
    has "the same register value" "$(grep "^reg $CT 13 " out.snap)" "cur fd1b000000000000" || return 1
    # the range is the camera's: -20 to 20 degrees
    expect "the top" "$("$BIN" pan 20)" "pan 20" || return 1
    out=$("$BIN" pan 20.0002 2>&1); rc=$?
    expect "just above the top" "$rc" 1 || return 1
    has "range in the message" "$out" "out of range (-20..20)" || return 1
    # not numbers, and not decimals for a control that has none
    for bad in abc 1.2.3 nan inf -inf 1e2 0x10 . - + -. --1 1,5 "1 2" ""; do
        "$BIN" pan "$bad" > /dev/null 2>&1; rc=$?
        expect "pan '$bad' status" "$rc" 1 || return 1
    done
    out=$("$BIN" zoom 120.5 2>&1); rc=$?
    expect "zoom 120.5 status" "$rc" 1 || return 1
    has "zoom 120.5 message" "$out" "zoom: bad value 120.5" || return 1
    # in --json too, as a number
    python3 -I -c pass >/dev/null 2>&1 || return 0
    "$BIN" pan 1.99 > /dev/null || return 1
    "$BIN" --json | python3 -I -c 'import json, sys; s = json.load(sys.stdin)["settings"]; assert s["pan"]["value"] == 1.99, s["pan"]'
}

t_hdr_and_backlight_both_ways() {
    # the MX Brio has hdr (on or off): 1 and 0 work under both names
    expect "backlight 0" "$("$BIN" backlight 0)" "hdr off" || return 1
    expect "backlight 1" "$("$BIN" backlight 1)" "hdr on" || return 1
    expect "hdr 0" "$("$BIN" hdr 0)" "hdr off" || return 1
    expect "hdr 1" "$("$BIN" hdr 1)" "hdr on" || return 1
    expect "backlight off" "$("$BIN" backlight off)" "hdr off" || return 1
    expect "backlight on" "$("$BIN" backlight on)" "hdr on" || return 1
    for v in 2 yes; do
        out=$("$BIN" backlight $v 2>&1); rc=$?
        expect "backlight $v status" "$rc" 1 || return 1
        has "backlight $v message" "$out" "bad value $v" || return 1
    done
    "$BIN" backlight -1 > /dev/null 2>&1; expect "backlight -1 is a relative value on a name control" "$?" 2 || return 1
    # a camera with a number: on and off are 1 and 0 under both names
    export BRIOCTL_FAKE=$PWD/generic.snap
    expect "hdr off" "$("$BIN" hdr off)" "backlight 0" || return 1
    expect "get" "$("$BIN" get backlight)" 0 || return 1
    expect "hdr on" "$("$BIN" hdr on)" "backlight 1" || return 1
    expect "backlight off" "$("$BIN" backlight off)" "backlight 0" || return 1
    expect "backlight on" "$("$BIN" backlight on)" "backlight 1" || return 1
    # a settings file from the MX Brio, with hdr in it, applies to the other camera
    "$BIN" backlight 0 > /dev/null || return 1
    printf '# camera 046d:0944 XYZ\nhdr on\n' > mx
    "$BIN" apply "$PWD/mx" > /dev/null 2>&1; rc=$?
    expect "apply status" "$rc" 0 || return 1
    expect "hdr on applied" "$("$BIN" get backlight)" 1 || return 1
    printf 'hdr off\n' > mx
    "$BIN" --test-reapply "$PWD/mx" > out 2>&1 || return 1
    expect "and by watch" "$("$BIN" get backlight)" 0 || return 1
    # the camera's range still counts
    edit_reg "$PU" 1 max 0000
    out=$("$BIN" hdr on 2>&1); rc=$?
    expect "above the range" "$rc" 1 || return 1
    has "above the range message" "$out" "out of range (0-0)" || return 1
    expect "inside the range" "$("$BIN" hdr off)" "backlight 0" || return 1
    "$BIN" backlight 2 > /dev/null 2>&1; rc=$?
    expect "a number outside" "$rc" 1
}

# bmcontrols_fixtures SNAPSHOT: a camera for every bit of the camera terminal and of the processing unit (UVC 1.5
# tables 3-6 and 3-8), declaring that bit and no other, as bit-ct-N.snap and bit-pu-N.snap; bits.txt has a line for
# each: the file, then the controls that bit gives (none where brioctl has no control). all.snap declares every bit.
bmcontrols_fixtures() {
    python3 -I - "$HERE/make-fixtures.py" "$1" <<'PY'
import importlib.util, sys
sys.dont_write_bytecode = True  # no __pycache__ next to the repository's make-fixtures.py
spec = importlib.util.spec_from_file_location("fixtures", sys.argv[1])
mf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mf)
lines = open(sys.argv[2]).read().splitlines()
desc = bytes.fromhex([l for l in lines if l.startswith("descriptor ")][0].split()[1])
CT = {1: "ae", 2: "priority", 3: "exposure", 5: "focus", 7: "iris", 9: "zoom", 11: "pan tilt", 13: "roll", 17: "af",
      18: "privacy"}
PU = {0: "brightness", 1: "contrast", 2: "hue", 3: "saturation", 4: "sharpness", 5: "gamma", 6: "wb", 8: "backlight",
      9: "gain", 10: "flicker", 11: "hueauto", 12: "awb"}

def write(name, d):
    out = ["descriptor " + d.hex() if l.startswith("descriptor ") else l for l in lines]
    open(name, "w").write("\n".join(out) + "\n")

bits = []
for unit, table, size in (("ct", CT, 22), ("pu", PU, 16)):  # the MX Brio's descriptor has 3 and 2 bytes of them
    for bit in range(size):
        ct, pu = ((bit,), ()) if unit == "ct" else ((), (bit,))
        name = "bit-%s-%d.snap" % (unit, bit)
        write(name, mf.declare(desc, ct_bits=ct, pu_bits=pu, only=True))
        bits.append("%s %s" % (name, " ".join(sorted(table.get(bit, "").split()))))
open("bits.txt", "w").write("\n".join(bits) + "\n")
write("all.snap", mf.declare(desc, ct_bits=range(22), pu_bits=range(16), only=True))
PY
}

t_bmcontrols_bit_by_bit() {
    python3 -I -c pass >/dev/null 2>&1 || { echo "# python3 not available"; return 77; }
    bmcontrols_fixtures extra.snap || return 1
    n=0
    while read -r file want; do
        got=$(BRIOCTL_FAKE=$PWD/$file "$BIN" 2>&1 | sed -n 's/^  \([a-z]*\) .*/\1/p' | sort | tr '\n' ' ' | sed 's/ $//')
        expect "$file declares" "$got" "$want" || return 1
        n=$((n + 1))
    done < bits.txt
    expect "cameras tried" "$n" 38 || return 1
    # every bit at once: 23 controls (pan and tilt share a bit; a camera that is not an MX Brio calls the HDR switch backlight)
    got=$(BRIOCTL_FAKE=$PWD/all.snap "$BIN" 2>&1 | sed -n 's/^  \([a-z]*\) .*/\1/p' | wc -l | tr -d ' ')
    expect "all bits" "$got" 23
}

t_camera_index_follows_location() {
    three_cameras
    printf 'location 0x300000\n' >> g1.snap
    printf 'location 0x100000\n' >> brio.snap
    printf 'location 0x200000\n' >> g2.snap
    # the order in the environment does not matter: the cameras are numbered by USB location
    for order in "g1 brio g2" "g2 g1 brio" "brio g2 g1"; do
        BRIOCTL_FAKE=
        for f in $order; do BRIOCTL_FAKE=$BRIOCTL_FAKE:$PWD/$f.snap; done
        BRIOCTL_FAKE=${BRIOCTL_FAKE#:}
        out=$("$BIN" list) || return 1
        matches "1 is the MX Brio ($order)" "$out" '^1 +046d:0944 +MX Brio .* BRIOSERIAL1 +0x100000$' || return 1
        matches "2 is the second ($order)" "$out" '^2 +1234:5678 .* GENERIC0002 +0x200000$' || return 1
        matches "3 is the third ($order)" "$out" '^3 +1234:5678 .* GENERIC0001 +0x300000$' || return 1
        got=$("$BIN" --camera 3 --json | python3 -I -c 'import json, sys; d = json.load(sys.stdin)["device"]; print(d["serial"], d["index"], d["location"])')
        expect "--camera 3 ($order)" "$got" "GENERIC0001 3 0x300000" || return 1
    done
    "$BIN" --camera 3 brightness 100 > /dev/null || return 1
    has "index 3 is the camera at 0x300000" "$(grep '^reg 3 2 ' g1.snap)" "cur 6400" || return 1
    has "and not the others" "$(grep '^reg 3 2 ' g2.snap)" "cur 8000" || return 1
    expect "by location" "$(which_camera --camera 0x200000)" "device 1234 5678" || return 1
    expect "by location, MX Brio" "$("$BIN" --camera 0x100000 get zoom)" 115 || return 1
    expect "watch follows the MX Brio by its place" "$("$BIN" --test-watch-target)" \
        "046d:0944 serial=BRIOSERIAL1 uid=0x100000046d0944"
}

t_json_serial_is_the_usb_serial() {
    python3 -I -c pass >/dev/null 2>&1 || { echo "# python3 not available"; return 77; }
    # the camera's own register says INFOSERIAL01, USB says USBSERIAL001: list and --camera use the USB one
    sed 's/^serial .*/serial USBSERIAL001/' camera.snap > usb.snap
    BRIOCTL_FAKE=$PWD/usb.snap
    edit_reg "$INFO" 7 cur 494e464f53455249414c3031
    has "the register" "$("$BIN" 2>&1)" "serial INFOSERIAL01" || return 1
    "$BIN" --json > out.json || return 1
    "$BIN" list --json > list.json || return 1
    python3 -I - out.json list.json <<'PY' || return 1
import json, sys
dev = json.load(open(sys.argv[1]))["device"]
listed = json.load(open(sys.argv[2]))["cameras"][0]
assert dev["serial"] == "USBSERIAL001" == listed["serial"], (dev["serial"], listed["serial"])
PY
    expect "--camera takes it" "$("$BIN" --camera USBSERIAL001 get zoom)" 115 || return 1
    # without a USB serial the register is the fallback; without both there is none
    grep -v '^serial ' usb.snap > nousb.snap
    BRIOCTL_FAKE=$PWD/nousb.snap
    "$BIN" --json | python3 -I -c 'import json, sys; assert json.load(sys.stdin)["device"]["serial"] == "INFOSERIAL01"' || return 1
    grep -v '^serial ' generic.snap > nogen.snap
    BRIOCTL_FAKE=$PWD/nogen.snap
    "$BIN" --json | python3 -I -c 'import json, sys; assert json.load(sys.stdin)["device"]["serial"] is None'
}

# --- run -----------------------------------------------------------------------------------------------------------

N=0
FAILED=0

t_describe_json() {
    python3 -I -c pass >/dev/null 2>&1 || { echo "# python3 not available"; return 77; }
    "$BIN" describe --json > out.json || return 1
    python3 -I - out.json <<'PY' || return 1
import json, sys
d = json.load(open(sys.argv[1]))
assert d["camera"]["model"] == "MX Brio" and "serial" not in d["camera"], d["camera"]
c = {x["name"]: x for x in d["controls"]}
keys = {"name", "group", "kind", "unit", "min", "max", "step", "choices", "default", "current", "auto", "writable",
        "meaning", "effect_on_image", "settle_seconds", "risky", "risk"}
for name, x in c.items():
    assert set(x) == keys, (name, sorted(set(x) ^ keys))
    assert x["meaning"], name
    assert isinstance(x["settle_seconds"], float) and x["settle_seconds"] > 0, name
assert [n for n, x in c.items() if x["risky"]] == ["mic"], [n for n, x in c.items() if x["risky"]]
assert c["mic"]["risk"] and c["fov"]["risk"] is None
assert c["zoom"]["settle_seconds"] == 3.5 and c["pan"]["settle_seconds"] == 3.5
assert c["warmth"]["settle_seconds"] == 1.0 and c["expcomp"]["settle_seconds"] == 1.0 and c["tint"]["settle_seconds"] == 1.0
assert c["fov"]["settle_seconds"] == 0.3 and c["mic"]["settle_seconds"] == 0.3
w = c["warmth"]
assert (w["kind"], w["min"], w["max"], w["step"], w["default"], w["current"]) == ("number", 0, 100, 1, 50, 62), w
assert w["meaning"] == "white balance warmth, 50 = neutral, higher = warmer"
assert c["fov"]["kind"] == "choice" and c["fov"]["choices"] == ["90", "78", "65"] and c["fov"]["current"] == "78"
assert c["hdr"]["kind"] == "bool" and c["hdr"]["choices"] == ["on", "off"] and c["hdr"]["effect_on_image"]
assert c["zoom"]["current"] == 115 and c["exposure"]["auto"] is True
assert c["micgain"]["current"] == 0.2785
PY
}

t_describe_text_and_errors() {
    out=$("$BIN" describe 2>&1); rc=$?
    expect "status" "$rc" 0 || return 1
    has "heading" "$out" "MX Brio" || return 1
    matches "warmth block" "$out" "^warmth  .*now 62, default 50" || return 1
    has "risk" "$out" "RISKY: the camera restarts" || return 1
    out=$("$BIN" describe nonsense 2>&1); rc=$?
    expect "bad argument status" "$rc" 2 || return 1
    # a camera that is not the MX Brio gets its own controls, with the same fields
    out=$("$BIN" --camera 1 describe --json 2>&1 < /dev/null) || return 1
    BRIOCTL_FAKE=$PWD/generic.snap "$BIN" describe --json > g.json || return 1
    python3 -I -c "
import json
d = json.load(open('g.json'))
assert d['controls'] and all(x['meaning'] and x['settle_seconds'] > 0 for x in d['controls'])
assert not any(x['name'] in ('warmth', 'fov', 'micgain') for x in d['controls'])
assert all(x['settle_seconds'] == 0.3 for x in d['controls'] if x['name'] in ('zoom', 'pan'))
" || return 1
}

t_describe_writes_nothing() {
    BRIOCTL_FAKE_TRACE=1 "$BIN" describe --json 2> trace > /dev/null || return 1
    expect "SET_CUR count" "$(setcurs trace)" 0
}

t_capture_stats_json() {
    python3 -I -c pass >/dev/null 2>&1 || { echo "# python3 not available"; return 77; }
    "$BIN" capture -o shot.jpg --stats --json > out.json 2> err; rc=$?
    expect "status" "$rc" 0 || return 1
    expect "stderr" "$(cat err)" "" || return 1
    [ "$(head -c 3 shot.jpg | od -An -tx1 | tr -d ' ')" = ffd8ff ] || { echo "# shot.jpg is not a JPEG"; return 1; }
    python3 -I - out.json <<'PY' || return 1
import json, sys
d = json.load(open(sys.argv[1]))
assert set(d) == {"files", "frames", "avg"} and d["files"] == ["shot.jpg"] and len(d["frames"]) == 1
keys = {"width", "height", "y_mean", "y_p5", "y_p95", "y_stddev", "clip_low_pct", "clip_high_pct", "saturation_mean",
        "rgb_mean", "wb_bias", "sharpness"}
f = d["frames"][0]
assert set(f) == keys and set(d["avg"]) == keys and set(f["rgb_mean"]) == {"r", "g", "b"}, f
assert (f["width"], f["height"]) == (640, 360)
assert 0 <= f["y_p5"] <= f["y_mean"] <= f["y_p95"] <= 255 and f["y_stddev"] > 0
assert 0 <= f["clip_low_pct"] <= 100 and 0 <= f["clip_high_pct"] <= 100 and 0 <= f["saturation_mean"] <= 1
assert abs(f["wb_bias"] - f["rgb_mean"]["r"] / f["rgb_mean"]["b"]) < 1e-3 and f["sharpness"] > 0
assert f == d["avg"]  # one frame: the average is the frame
PY
}

t_capture_text_and_naming() {
    out=$("$BIN" capture --stats 2>&1); rc=$?
    expect "status" "$rc" 0 || return 1
    has "default file" "$out" "capture.jpg" || return 1
    [ -s capture.jpg ] || { echo "# capture.jpg missing"; return 1; }
    for k in width height y_mean y_p5 y_p95 y_stddev clip_low_pct clip_high_pct saturation_mean rgb_mean wb_bias sharpness; do
        matches "$k line" "$out" "^  $k +[0-9r]" || return 1
    done
    out=$("$BIN" capture -o shots/x.jpg 2>&1); rc=$?
    expect "missing directory status" "$rc" 1 || return 1
    has "missing directory message" "$out" "cannot write shots/x.jpg" || return 1
    out=$("$BIN" capture --count 3 --interval 0 --wait 0 -o pic.jpeg --stats 2>&1); rc=$?
    expect "count status" "$rc" 0 || return 1
    for i in 1 2 3; do [ -s pic-$i.jpeg ] || { echo "# pic-$i.jpeg missing"; return 1; }; done
    [ ! -e pic.jpeg ] || { echo "# pic.jpeg should not exist with --count 3"; return 1; }
    has "frame 3" "$out" "frame 3" || return 1
    has "average" "$out" "average" || return 1
    "$BIN" capture --count 2 -o noext > /dev/null || return 1
    [ -s noext-1 ] && [ -s noext-2 ] || { echo "# noext-N missing"; return 1; }
    mkdir d.d && "$BIN" capture --count 2 -o d.d/a > /dev/null || return 1
    [ -s d.d/a-1 ] || { echo "# dot in directory name confused the extension"; return 1; }
}

t_capture_json_count_and_size() {
    python3 -I -c pass >/dev/null 2>&1 || { echo "# python3 not available"; return 77; }
    "$BIN" capture --count 3 --size 320x180 -o c.jpg --json > out.json || return 1
    python3 -I - out.json <<'PY' || return 1
import json, sys
d = json.load(open(sys.argv[1]))
assert d["files"] == ["c-1.jpg", "c-2.jpg", "c-3.jpg"], d["files"]
assert len(d["frames"]) == 3 and all((f["width"], f["height"]) == (320, 180) for f in d["frames"])
assert d["avg"]["y_mean"] == d["frames"][0]["y_mean"]
PY
}

t_capture_errors() {
    for bad in "--count 0" "--count 101" "--count x" "--interval -1" "--wait x" "--size 640" "--size 0x10" "--size 10x10x" \
        "--bogus" "-o" "--count"; do
        # shellcheck disable=SC2086
        out=$("$BIN" capture $bad 2>&1); rc=$?
        expect "capture $bad status" "$rc" 2 || return 1
    done
    [ ! -e capture.jpg ] || { echo "# a rejected command wrote capture.jpg"; return 1; }
    out=$(BRIOCTL_FAKE_CAPTURE_DENIED=1 "$BIN" capture 2>&1); rc=$?
    expect "denied status" "$rc" 3 || return 1
    has "denied message" "$out" "camera access is denied" || return 1
    [ ! -e capture.jpg ] || { echo "# denied capture wrote a file"; return 1; }
    out=$("$BIN" --camera 9 capture 2>&1); rc=$?
    expect "unknown camera status" "$rc" 2 || return 1
    has "unknown camera message" "$out" "no camera matches 9" || return 1
}

t_capture_touches_no_register() {
    BRIOCTL_FAKE_TRACE=1 "$BIN" capture --stats > /dev/null 2> trace || return 1
    expect "SET_CUR count" "$(setcurs trace)" 0
}

# --- relative values, --dry-run, undo, --save, install-skill -----------------------------------------------------------

t_relative_values() {
    expect "start" "$("$BIN" get expcomp)" 128 || return 1
    expect "expcomp +10" "$("$BIN" expcomp +10)" "expcomp 138" || return 1
    expect "warmth -5 zoom +25 mixed with absolute" "$("$BIN" warmth -5 tint 60 zoom +25 | tr '\n' ' ')" "warmth 57 tint 60 zoom 140 " || return 1
    expect "clamped at the top" "$("$BIN" expcomp +500)" "expcomp 255" || return 1
    expect "clamped at the bottom" "$("$BIN" expcomp -500)" "expcomp 0" || return 1
    expect "zoom -1000 stops at the camera minimum" "$("$BIN" zoom -1000)" "zoom 100" || return 1
    expect "no write when clamped to the same value" "$(BRIOCTL_FAKE_TRACE=1 "$BIN" zoom -5 2>&1 | grep -c 'fake SET_CUR')" 0 || return 1
    # signed controls keep -N as an absolute value; +-N subtracts
    expect "pan -10 is absolute" "$("$BIN" pan -10)" "pan -10" || return 1
    expect "pan +-5" "$("$BIN" pan +-5)" "pan -15" || return 1
    expect "pan +2.5" "$("$BIN" pan +2.5)" "pan -12.50" || return 1
    for bad in "expcomp +x" "expcomp ++5" "expcomp +" "expcomp -"; do
        out=$("$BIN" $bad 2>&1); rc=$?
        expect "$bad status" "$rc" 1 || return 1
        has "$bad message" "$out" "bad value" || return 1
    done
    expect "nothing changed by bad values" "$("$BIN" get expcomp)" 0 || return 1
}

t_relative_values_on_names_exit_2() {
    for bad in "hdr +1" "hdr -" "showmode +1" "flicker +10" "ae -1" "fov +1"; do
        out=$(BRIOCTL_FAKE_TRACE=1 "$BIN" $bad 2>&1); rc=$?
        expect "$bad status" "$rc" 2 || return 1
        has "$bad message" "$out" "this control takes names" || return 1
        hasnt "$bad write" "$out" "fake SET_CUR" || return 1
    done
    "$BIN" expcomp 100 hdr +1 > out 2> err; rc=$?
    expect "mixed status" "$rc" 2 || return 1
    expect "the valid part is still set" "$("$BIN" get expcomp)" 100 || return 1
}

t_fov_steps() {
    expect "start" "$("$BIN" get fov)" 78 || return 1
    expect "narrower" "$("$BIN" fov -)" "fov 65" || return 1
    expect "narrowest stays" "$("$BIN" fov -)" "fov 65" || return 1
    expect "wider" "$("$BIN" fov +)" "fov 78" || return 1
    expect "widest" "$("$BIN" fov + )" "fov 90" || return 1
    expect "widest stays" "$("$BIN" fov +)" "fov 90" || return 1
}

t_relative_not_from_a_file() {
    printf 'expcomp +10\nzoom 130\n' > rel
    out=$("$BIN" apply ./rel 2>&1); rc=$?
    expect "status" "$rc" 1 || return 1
    has "message" "$out" "only for the command line" || return 1
    expect "expcomp untouched" "$("$BIN" get expcomp)" 128 || return 1
    expect "the absolute line was applied" "$("$BIN" get zoom)" 130 || return 1
}

t_dry_run() {
    cp camera.snap before.snap
    out=$("$BIN" expcomp +10 warmth 62 fov 65 --dry-run); rc=$?
    expect "status" "$rc" 0 || return 1
    expect "text" "$out" "expcomp 128 -> 138
warmth 62 unchanged
fov 78 -> 65" || return 1
    expect "after the command works too" "$("$BIN" --dry-run expcomp +10)" "expcomp 128 -> 138" || return 1
    out=$("$BIN" --dry-run --json expcomp +10 warmth 62); rc=$?
    expect "json" "$out" '{"changes":[{"name":"expcomp","from":"128","to":"138","unchanged":false},{"name":"warmth","from":"62","to":"62","unchanged":true}]}' || return 1
    expect "json after" "$("$BIN" expcomp +10 --json --dry-run)" '{"changes":[{"name":"expcomp","from":"128","to":"138","unchanged":false}]}' || return 1
    cmp -s camera.snap before.snap || { echo "# the camera changed"; return 1; }
    [ ! -e "$HOME/.config/brioctl/undo" ] || { echo "# an undo file was written"; return 1; }
    BRIOCTL_FAKE_TRACE=1 "$BIN" --dry-run zoom 150 mic off 2> trace > /dev/null
    expect "no SET_CUR" "$(setcurs trace)" 0 || return 1
    # errors are still errors
    out=$("$BIN" --dry-run zoom 500 2>&1); rc=$?
    expect "bad value status" "$rc" 1 || return 1
    has "bad value" "$out" "out of range" || return 1
    out=$("$BIN" --dry-run hdr +1 2>&1); rc=$?
    expect "name control status" "$rc" 2 || return 1
    out=$("$BIN" --dry-run micgain 0.5 2>&1)
    has "micgain" "$out" "micgain" || return 1
}

t_dry_run_apply_and_defaults() {
    "$BIN" expcomp 200 warmth 70 > /dev/null || return 1
    "$BIN" save before > /dev/null || return 1
    "$BIN" expcomp 100 > /dev/null || return 1
    rm "$HOME/.config/brioctl/undo"
    cp camera.snap before.snap
    out=$("$BIN" apply before --dry-run) || return 1
    has "apply plan" "$out" "expcomp 100 -> 200" || return 1
    has "apply unchanged" "$out" "warmth 70 unchanged" || return 1
    out=$("$BIN" apply before --dry-run --json) || return 1
    has "apply json" "$out" '{"name":"expcomp","from":"100","to":"200","unchanged":false}' || return 1
    out=$("$BIN" defaults --dry-run) || return 1
    has "defaults plan" "$out" "warmth 70 -> 50" || return 1
    out=$("$BIN" defaults --dry-run --json) || return 1
    has "defaults json" "$out" '"name":"warmth","from":"70","to":"50"' || return 1
    cmp -s camera.snap before.snap || { echo "# the camera changed"; return 1; }
    [ ! -e "$HOME/.config/brioctl/undo" ] || { echo "# an undo file was written"; return 1; }
    for bad in watch factory-reset save snapshot capture; do
        "$BIN" $bad --dry-run > /dev/null 2>&1; rc=$?
        expect "$bad --dry-run status" "$rc" 2 || return 1
    done
    "$BIN" get expcomp --save > /dev/null 2>&1; expect "--save with get" "$?" 2 || return 1
    "$BIN" expcomp 1 --dry-run --save > /dev/null 2>&1; expect "--dry-run --save" "$?" 2 || return 1
}

t_undo() {
    out=$("$BIN" undo 2>&1); rc=$?
    expect "nothing to undo" "$rc" 1 || return 1
    has "message" "$out" "nothing to undo" || return 1
    "$BIN" expcomp +10 warmth -5 fov 65 > /dev/null || return 1
    f=$HOME/.config/brioctl/undo
    matches "header line" "$(sed -n 1p "$f")" '^# brioctl undo, [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}, brioctl expcomp \+10 warmth -5 fov 65$' || return 1
    matches "camera line" "$(sed -n 2p "$f")" '^# camera 046d:0944' || return 1
    expect "values, newest first" "$(sed 1,2d "$f" | tr '\n' ' ')" "fov 78 warmth 62 expcomp 128 " || return 1
    out=$("$BIN" undo --dry-run) || return 1
    expect "dry run" "$out" "fov 65 -> 78
warmth 57 -> 62
expcomp 138 -> 128" || return 1
    expect "dry run keeps the file" "$(sed 1,2d "$f" | tr '\n' ' ')" "fov 78 warmth 62 expcomp 128 " || return 1
    "$BIN" undo > /dev/null || return 1
    expect "expcomp back" "$("$BIN" get expcomp)" 128 || return 1
    expect "warmth back" "$("$BIN" get warmth)" 62 || return 1
    expect "fov back" "$("$BIN" get fov)" 78 || return 1
    matches "undo's own header" "$(sed -n 1p "$f")" ', brioctl undo$' || return 1
    "$BIN" undo > /dev/null || return 1   # undo of undo
    expect "redone" "$("$BIN" get expcomp)/$("$BIN" get warmth)/$("$BIN" get fov)" "138/57/65" || return 1
}

t_undo_records_only_changes() {
    "$BIN" expcomp 140 > /dev/null || return 1
    "$BIN" expcomp 150 warmth 62 tint 50 > /dev/null || return 1   # warmth and tint already have these values
    expect "only what changed" "$(sed 1,2d "$HOME/.config/brioctl/undo")" "expcomp 140" || return 1
    "$BIN" expcomp 150 > /dev/null   # nothing changes: the record stays
    expect "kept" "$(sed 1,2d "$HOME/.config/brioctl/undo")" "expcomp 140" || return 1
    "$BIN" get expcomp > /dev/null
    "$BIN" --dry-run expcomp 1 > /dev/null
    expect "reads and dry runs keep it" "$(sed 1,2d "$HOME/.config/brioctl/undo")" "expcomp 140" || return 1
    "$BIN" expcomp 999 > /dev/null 2>&1   # refused: nothing written, nothing recorded
    expect "refused" "$(sed 1,2d "$HOME/.config/brioctl/undo")" "expcomp 140" || return 1
}

t_undo_apply_defaults_and_mic_last() {
    "$BIN" expcomp 200 warmth 70 > /dev/null || return 1
    "$BIN" save mine > /dev/null || return 1
    "$BIN" defaults > /dev/null || return 1
    f=$HOME/.config/brioctl/undo
    matches "defaults header" "$(sed -n 1p "$f")" ', brioctl defaults$' || return 1
    has "defaults recorded" "$(cat "$f")" "warmth 70" || return 1
    "$BIN" undo > /dev/null || return 1
    expect "defaults undone" "$("$BIN" get expcomp)/$("$BIN" get warmth)" "200/70" || return 1
    "$BIN" apply neutral > /dev/null || return 1
    matches "apply header" "$(sed -n 1p "$f")" ', brioctl apply neutral$' || return 1
    "$BIN" undo > /dev/null || return 1
    expect "apply undone" "$("$BIN" get warmth)" 70 || return 1
    # mic goes last when restoring
    "$BIN" mic off expcomp 10 > /dev/null || return 1
    BRIOCTL_FAKE_TRACE=1 "$BIN" undo 2> trace > /dev/null || return 1
    expect "mic last" "$(grep -o 'sel [0-9]* [0-9a-f]*' trace | tail -1 | cut -d' ' -f2)" 16 || return 1
}

t_undo_after_factory_reset_restore() {
    "$BIN" expcomp 200 > /dev/null || return 1
    "$BIN" factory-reset --yes > /dev/null 2>&1; rc=$?
    [ -f "$HOME/.config/brioctl/before-reset" ] || return 1
    [ -f "$HOME/.config/brioctl/undo" ] || { echo "# the restore left no undo file (rc $rc)"; return 1; }
}

t_save_flag() {
    "$BIN" expcomp 140 > /dev/null || return 1
    [ ! -e "$HOME/.config/brioctl/settings" ] || { echo "# settings written without --save"; return 1; }
    out=$("$BIN" expcomp +10 --save) || return 1
    has "output" "$out" "expcomp 150" || return 1
    has "saved" "$out" "saved " || return 1
    has "file" "$(cat "$HOME/.config/brioctl/settings")" "expcomp 150" || return 1
    "$BIN" --save warmth 61 > /dev/null || return 1
    has "before the command" "$(cat "$HOME/.config/brioctl/settings")" "warmth 61" || return 1
    "$BIN" undo --save > /dev/null || return 1
    has "undo --save" "$(cat "$HOME/.config/brioctl/settings")" "warmth 62" || return 1
    "$BIN" apply neutral --save > /dev/null || return 1
    # a failed command saves nothing
    "$BIN" expcomp 140 > /dev/null; cp "$HOME/.config/brioctl/settings" kept
    "$BIN" expcomp 100 zoom 9999 --save > /dev/null 2>&1; rc=$?
    expect "failure status" "$rc" 1 || return 1
    cmp -s kept "$HOME/.config/brioctl/settings" || { echo "# a failed command saved"; return 1; }
}

t_install_skill() {
    mkdir -p "$HOME/.claude" bin
    cp "$BIN" bin/brioctl
    # nothing next to the binary: the copy built in
    out=$(bin/brioctl install-skill) || return 1
    has "claude" "$out" "claude: installed $HOME/.claude/skills/brioctl/SKILL.md (from the copy built into brioctl)" || return 1
    has "codex skipped" "$out" "codex: skipped" || return 1
    [ ! -e "$HOME/.codex" ] || { echo "# ~/.codex was created"; return 1; }
    cmp -s "$HERE/../skills/brioctl/SKILL.md" "$HOME/.claude/skills/brioctl/SKILL.md" || { echo "# built-in copy differs from the source"; return 1; }
    [ ! -L "$HOME/.claude/skills/brioctl/SKILL.md" ] || return 1
    # the Homebrew layout wins over the built-in copy
    mkdir -p share/brioctl/skills/brioctl
    echo "from share" > share/brioctl/skills/brioctl/SKILL.md
    out=$(bin/brioctl install-skill --claude) || return 1
    has "share" "$out" "(from " || return 1
    expect "share copy" "$(cat "$HOME/.claude/skills/brioctl/SKILL.md")" "from share" || return 1
    # a source tree: skills/brioctl/SKILL.md next to the binary
    mkdir -p bin/skills/brioctl
    echo "from tree" > bin/skills/brioctl/SKILL.md
    bin/brioctl install-skill --claude > /dev/null || return 1
    expect "tree copy" "$(cat "$HOME/.claude/skills/brioctl/SKILL.md")" "from tree" || return 1
    # --codex creates the directory; --all and no flag do both once both exist
    out=$(bin/brioctl install-skill --codex) || return 1
    has "codex" "$out" "codex: installed $HOME/.codex/skills/brioctl/SKILL.md" || return 1
    echo old > "$HOME/.claude/skills/brioctl/SKILL.md"
    out=$(bin/brioctl install-skill --all) || return 1
    has "all claude" "$out" "claude: installed" || return 1
    has "all codex" "$out" "codex: installed" || return 1
    expect "claude refreshed" "$(cat "$HOME/.claude/skills/brioctl/SKILL.md")" "from tree" || return 1
    # a link is replaced by a copy, the target is not written through
    echo keep > target
    rm "$HOME/.codex/skills/brioctl/SKILL.md"; ln -s "$PWD/target" "$HOME/.codex/skills/brioctl/SKILL.md"
    bin/brioctl install-skill --codex > /dev/null || return 1
    [ ! -L "$HOME/.codex/skills/brioctl/SKILL.md" ] || { echo "# still a link"; return 1; }
    expect "link target untouched" "$(cat target)" keep || return 1
    # uninstall
    out=$(bin/brioctl install-skill --uninstall) || return 1
    has "removed" "$out" "claude: removed" || return 1
    [ ! -e "$HOME/.claude/skills/brioctl" ] && [ ! -e "$HOME/.codex/skills/brioctl" ] || { echo "# not removed"; return 1; }
    out=$(bin/brioctl install-skill --uninstall --claude) || return 1
    has "not installed" "$out" "claude: not installed" || return 1
    bin/brioctl install-skill --bogus > /dev/null 2>&1; expect "bad flag" "$?" 2 || return 1
    # no camera is needed
    env -u BRIOCTL_FAKE bin/brioctl install-skill --claude > /dev/null || return 1
}

t_install_skill_without_agents() {
    out=$("$BIN" install-skill) || return 1
    has "claude" "$out" "claude: skipped" || return 1
    has "codex" "$out" "codex: skipped" || return 1
    [ ! -e "$HOME/.claude" ] && [ ! -e "$HOME/.codex" ] || { echo "# directories were created"; return 1; }
}

t_make_install_puts_the_skill_in_share() {
    [ -f "$HERE/../Makefile" ] || return 77
    make -n -C "$HERE/.." install PREFIX=/x > mk 2>&1 || return 77
    has "skill install" "$(cat mk)" "/x/share/brioctl/skills/brioctl/SKILL.md" || return 1
}


run() {  # run NAME FUNCTION
    N=$((N + 1))
    dir=$ROOT/$N
    if ! { mkdir -p "$dir/home" && cp "$FIXTURE" "$dir/camera.snap" && cp "$GENERIC" "$dir/generic.snap" &&
        cp "$EXTRA" "$dir/extra.snap" && cp "$BRIO500" "$dir/brio500.snap" && cp "$OPLUS" "$dir/optionsplus.db"; }; then
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
run "watch follows the one full camera, else the one experimental one, else waits (never exits)" t_watch_target
run "watch applies to the chosen camera, found again by its ids and serial" t_watch_applies_to_the_chosen_camera
run "the CoreMediaIO lookup finds nothing for an unknown camera" t_cmio_hook
run "privacy is not saved, not reset by defaults, not applied by watch; by hand it works" t_privacy_is_not_a_preference
run "watch does not apply a file saved from another model; apply only warns" t_watch_wont_apply_to_another_model
run "one video start gives one apply, whichever of HID and CoreMediaIO comes first" t_one_apply_per_video_start
run "a camera is found again by its serial number, or by its place if it has none" t_camera_found_again_by_serial_or_place
run "a number is written only with a range from the camera" t_numbers_need_a_known_range
run "a value outside the control's field is refused, signed or unsigned" t_value_must_fit_the_control
run "numbers that overflow are refused" t_numbers_that_overflow_are_refused
run "pan and tilt take decimals; save and apply round-trip every register value" t_decimal_degrees
run "hdr and backlight take on/off and 1/0 on every camera, within its range" t_hdr_and_backlight_both_ways
run "every bit of bmControls gives exactly its control" t_bmcontrols_bit_by_bit
run "cameras are numbered by USB location, not by the order they are given" t_camera_index_follows_location
run "--json device.serial is the USB serial that list and --camera use" t_json_serial_is_the_usb_serial
run "import optionsplus prints the twenty settings and what it leaves out, with no camera" t_import_sample
run "import optionsplus reads the default settings.db of Logi Options+" t_import_default_path
run "import optionsplus --save writes a settings file, refuses preset names, writes nothing on failure" t_import_save
run "an imported file applies: the registers written, the camera ends with the same values" t_import_output_applies
run "import optionsplus: missing or damaged database, bad arguments" t_import_errors
run "import optionsplus: no camera, no cards, no profile" t_import_no_camera
run "import optionsplus: unexpected layouts name the schema version; another version warns" t_import_unexpected_schema
run "import optionsplus opens the database read-only and immutable, also in WAL mode" t_import_leaves_the_database_alone
run "import optionsplus takes the MX Brio first, else the first camera" t_import_picks_the_camera
run "import optionsplus: the default profile, the selected preset, the user's own as fallback" t_import_profile_and_preset
run "import optionsplus skips manual exposure and focus, pan, RightSight and warns about wb" t_import_what_it_does_not_trust
run "import optionsplus: line breaks in the file's text make no lines in the output" t_import_text_from_the_file_is_harmless
run "the Logi Options+ fixtures hold no account data and the .db equals the .json" t_optionsplus_fixture_is_anonymous

run "describe --json: every control has meaning, settle_seconds and the full set of fields" t_describe_json
run "describe prints text, rejects bad arguments, also fits another camera" t_describe_text_and_errors
run "describe only reads" t_describe_writes_nothing
run "capture --stats --json: shape, ranges, a real JPEG" t_capture_stats_json
run "capture: text stats, default file, -N naming, write errors" t_capture_text_and_naming
run "capture --count --size --json" t_capture_json_count_and_size
run "capture: bad options exit 2, denied access exits 3, unknown camera" t_capture_errors
run "capture writes no camera register" t_capture_touches_no_register
run "relative values: +N and -N add to the current value, clamp, mix with absolute ones" t_relative_values
run "relative values on named controls exit 2 and write nothing" t_relative_values_on_names_exit_2
run "fov + and fov - step to the next wider or narrower angle" t_fov_steps
run "a settings file cannot hold a relative value" t_relative_not_from_a_file
run "--dry-run prints NAME old -> new, as JSON too, and changes nothing" t_dry_run
run "--dry-run with apply and defaults; refused for commands that cannot plan" t_dry_run_apply_and_defaults
run "undo puts back the replaced values and undoes itself" t_undo
run "undo records only real changes and keeps the record through reads and dry runs" t_undo_records_only_changes
run "undo covers defaults and apply, restores mic last" t_undo_apply_defaults_and_mic_last
run "factory-reset's restore leaves an undo file" t_undo_after_factory_reset_restore
run "--save runs save after set, apply and undo, and not after a failure" t_save_flag
run "install-skill copies from the tree, share or the built-in text; uninstall; links replaced" t_install_skill
run "install-skill without ~/.claude and ~/.codex creates nothing" t_install_skill_without_agents
run "make install puts the skill into share/brioctl/skills/brioctl" t_make_install_puts_the_skill_in_share

echo "1..$N"
if [ "$FAILED" -ne 0 ]; then
    echo "# $FAILED of $N failed"
    exit 1
fi
echo "# all $N passed"
