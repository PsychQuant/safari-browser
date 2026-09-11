#!/bin/bash
# e2e-dialog.sh — #126: a blocking dialog is announced on the FIRST line of
# stderr by every targeting command; read-only AppleScript commands still
# succeed; JavaScript refuses at once instead of waiting for the 30 s
# osascript timeout; and the daemon path behaves the same.
#
# Stages its own dialog: opens Tests/Fixtures/dialog-test.html in a new tab
# (URL carries a run nonce so every command below is locked to that tab),
# arms an alert through `js` behind a setTimeout, then exercises the
# commands. The delay is generous (6 s): one `js` invocation is four or five
# osascript round-trips (preset globals, run, read length, read result,
# cleanup — JsCommand.swift), and an alert that opens between two of them
# lands the rest on the 30 s timeout path. Only a dialog in OUR tab's window
# — as reported by the entry probe on the nonce-locked target — is ever
# dismissed, never anybody else's. (Ownership cannot use the alert's text:
# #127 — the probe reads the alert's title, not its body. Background-tab
# invisibility is #131.) If a dialog is already up anywhere in Safari the
# test skips: `dialog list` refuses to pick one of several, and the test could
# not tell whose it would be pressing.
#
# Safari renders a JavaScript alert only while its tab is the window's active
# tab; in a background tab the alert is pending and invisible (JavaScript is
# still frozen), so there is no dialog element for anyone to find. The test
# therefore focuses the fixture tab before arming and again before listing.
#
# Requires: Safari running; Accessibility granted to $SAFARI_BROWSER_BIN (the
# probe is an AX read). Skips (exit 77) otherwise.
#
# Usage: SAFARI_BROWSER_BIN=.build/debug/safari-browser Tests/e2e-dialog.sh
set -u

SB="${SAFARI_BROWSER_BIN:-$HOME/bin/safari-browser}"
# Isolate stateless checks from a caller's existing daemon namespace.
export SAFARI_BROWSER_NAME="fixture-no-daemon-$$"
unset SAFARI_BROWSER_DAEMON
FIXTURE="file://$(cd "$(dirname "$0")" && pwd)/Fixtures/dialog-test.html"
MARK="dlg$$"
URL="${FIXTURE}?${MARK}"
LOCK=(--url "$MARK")
NAME="dialog-$$"                 # daemon namespace for the parity step
DIALOG_TEXT="e2e dialog ${MARK}"
# A broken clock must fail before any Safari interaction or arithmetic.
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required for timing" >&2; exit 1; }
now_ms() {
    local value
    value=$(python3 -c 'import time; print(time.monotonic_ns() // 1000000)') || return 1
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$value"
}
now_ms >/dev/null || { echo "FAIL: timing command did not return an integer" >&2; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/sb-dialog.XXXXXX") || { echo "FAIL: could not create temporary directory" >&2; exit 1; }
FIXTURE_OPENED=0
PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "      $2"; }
skip() { SKIP=$((SKIP + 1)); echo "  ⊘ SKIP $1"; }

# Whole seconds are too coarse for a "under 3 s" bound.


# First button title in a `dialog list` listing: the line `  buttons: "A", "B"`.
dialog_button() { sed -nE 's/^ *buttons: "([^"]*)".*/\1/p' | head -1; }

owns_fixture_dialog() {
    [[ "$FIXTURE_OPENED" -eq 1 ]] || return 1
    local warning attempt
    # An AX timeout is deliberately unknown. Wait for positive ownership
    # evidence before the destructive step; never treat unknown as permission.
    for attempt in 1 2 3; do
        warning=$("$SB" get title "${LOCK[@]}" 2>&1 >/dev/null) || return 1
        [[ "$warning" == *"BLOCKING DIALOG"* ]] && return 0
        sleep 0.2
    done
    return 1
}

dismiss_fixture_dialog() {
    local button="$1"
    [[ -n "$button" ]] && owns_fixture_dialog || return 1
    "$SB" dialog dismiss --button "$button"
}

cleanup() {
    [[ "$FIXTURE_OPENED" -eq 1 ]] || { rm -rf "$TMP"; return; }
    SAFARI_BROWSER_NAME="$NAME" "$SB" daemon stop >/dev/null 2>&1 || true
    local button n=0
    if owns_fixture_dialog; then
        button=$("$SB" dialog list 2>/dev/null | dialog_button)
        dismiss_fixture_dialog "$button" >/dev/null 2>&1 || true
    fi
    while "$SB" close "${LOCK[@]}" --first-match >/dev/null 2>&1; do
        n=$((n + 1)); [ "$n" -gt 5 ] && break
    done
    rm -rf "$TMP"
}
trap cleanup EXIT

echo "=== safari-browser blocking-dialog e2e (#126) ==="
echo "Fixture: $URL"
echo ""

# ── Preflight ────────────────────────────────────────────────────────────
if ! pgrep -x Safari >/dev/null; then
    echo "  SKIP: Safari is not running. Start Safari and retry."
    exit 77
fi
if [[ ! -x "$SB" ]]; then
    echo "  SKIP: $SB is not executable. Run 'make build-debug' or 'make install'."
    exit 77
fi
SESSION_CHECK="${DIALOG_TEST_SESSION_CHECK:-$TMP/session-check}"
if [[ -z "${DIALOG_TEST_SESSION_CHECK:-}" ]]; then
    clang "$(dirname "$0")/Fixtures/session-lock.c" -framework CoreGraphics -framework CoreFoundation -o "$SESSION_CHECK" || {
        echo "FAIL: cannot build GUI-session preflight" >&2; exit 1;
    }
fi
"$SESSION_CHECK"
SESSION_STATUS=$?
case "$SESSION_STATUS" in
    0) ;;
    77) echo "SKIP: GUI session is locked or unavailable; unlock before running Safari e2e."; exit 77 ;;
    *) echo "FAIL: GUI-session preflight failed ($SESSION_STATUS)" >&2; exit 1 ;;
esac

PRE=$("$SB" dialog list 2>&1)
PRE_EXIT=$?
if [[ "$PRE_EXIT" -ne 0 ]]; then
    if [[ "$PRE" == *"Accessibility"* || "$PRE" == *"windows are showing a dialog"* ]]; then
        echo "SKIP: dialog inspection unavailable or multiple dialogs present: $PRE"
        exit 77
    fi
    echo "FAIL: dialog list exited $PRE_EXIT: $PRE" >&2
    exit 1
fi
if [[ "$PRE" == "blocking dialog present"* ]]; then
    echo "SKIP: a dialog already exists; this test only dismisses its own."
    exit 77
fi
if [[ "$PRE" != "no blocking dialog found" ]]; then
    echo "FAIL: unexpected dialog list output: $PRE" >&2
    exit 1
fi

# ── Setup ────────────────────────────────────────────────────────────────
"$SB" open "$URL" >/dev/null 2>&1 || exit 1
FIXTURE_OPENED=1
sleep 2
GOT=$("$SB" get url "${LOCK[@]}" 2>/dev/null)
if echo "$GOT" | grep -q "$MARK"; then
    pass "fixture open, locked by nonce"
else
    fail "fixture open" "got: $GOT"
    exit 1
fi

echo "## Before the dialog"
ERR=$("$SB" get title "${LOCK[@]}" 2>&1 >/dev/null)
if echo "$ERR" | grep -q "BLOCKING DIALOG"; then
    fail "no warning while nothing is in the way" "$ERR"
else
    pass "no warning while nothing is in the way"
fi

echo "## Arm"
"$SB" tab focus "${LOCK[@]}" >/dev/null 2>&1 || true
VIS=$("$SB" js "${LOCK[@]}" "document.visibilityState" 2>/dev/null)
if [[ "$VIS" == *visible* ]]; then
    pass "fixture tab is the visible tab of its window (an alert in a background tab is never rendered)"
else
    fail "fixture tab is visible" "visibilityState=$VIS — tab focus did not take; aborting before arming an invisible alert"
    exit 1
fi
ARMED=$("$SB" js "${LOCK[@]}" "(setTimeout(function(){ alert('$DIALOG_TEXT'); }, 6000), 'armed')" 2>"$TMP/arm.err")
ARM_EXIT=$?
if [[ "$ARM_EXIT" -eq 0 && "$ARMED" == *armed* ]]; then
    pass "alert armed through js (js returned before it opened)"
else
    fail "alert armed" "exit=$ARM_EXIT stdout=$ARMED stderr=$(cat "$TMP/arm.err")"
    exit 1
fi
sleep 7

# ── 1. Read-only AppleScript command: succeeds, warns FIRST on stderr ────
echo "## Read-only command with the dialog up"
T0=$(now_ms) || { fail "timing failed"; exit 1; }
"$SB" get title "${LOCK[@]}" >"$TMP/title.out" 2>"$TMP/title.err"
TITLE_EXIT=$?
T1=$(now_ms) || { fail "timing failed"; exit 1; }
FIRST=$(head -1 "$TMP/title.err")
if [[ "$TITLE_EXIT" -eq 0 ]] && grep -q "Dialog Test Page" "$TMP/title.out"; then
    pass "get title still succeeds: exit 0, title on stdout"
else
    fail "get title still succeeds" "exit=$TITLE_EXIT stdout=$(cat "$TMP/title.out") stderr=$(cat "$TMP/title.err")"
fi
if [[ "$FIRST" == *"BLOCKING DIALOG"* ]]; then
    pass "stderr FIRST line names the dialog"
else
    fail "stderr first line names the dialog" "first line was: '$FIRST'"
fi
if [[ "$FIRST" == *'buttons: "'* ]]; then
    pass "warning names the dialog's buttons (message text itself is #127)"
else
    fail "warning names the dialog's buttons" "$FIRST"
fi
if [[ "$FIRST" == *"dialog list"* ]]; then
    pass "warning points at 'safari-browser dialog list'"
else
    fail "warning points at dialog list" "$FIRST"
fi
echo "      get title wall clock with the dialog up: $((T1 - T0)) ms"

# #135: assert the AX probe cost, excluding target resolution and process startup.
SAFARI_BROWSER_DIALOG_PROBE_DEBUG=1 "$SB" get title "${LOCK[@]}" >"$TMP/debug.out" 2>"$TMP/debug.err"
if python3 - "$TMP/debug.err" <<'BUDGET_PY'
import re, sys
values = [int(v) for v in re.findall(r'dialog probe: .*? (\d+) ms\b', open(sys.argv[1]).read())]
assert values, "debug did not report a timed probe"
assert sum(values) <= 200, f"command probe budget exceeded: {values}"
print(f"      AX probe measurements: {values} ms")
BUDGET_PY
then pass "command probes stay within 200 ms"
else fail "AX probe timing/budget"
fi
"$SB" tab focus "${LOCK[@]}" >"$TMP/focus.out" 2>"$TMP/focus.err"
if grep -q "BLOCKING DIALOG" "$TMP/focus.err"; then pass "native tab focus emits dialog warning"
else fail "native tab focus emits dialog warning"; fi

WINDOW=$("$SB" documents --json 2>/dev/null | python3 -c 'import json,sys; rows=[r for r in json.load(sys.stdin) if sys.argv[1] in r["url"]]; assert len(rows)==1; print(rows[0]["window"])' "$MARK")
if [[ "$WINDOW" =~ ^[1-9][0-9]*$ ]] && "$SB" tabs --window "$WINDOW" --json >"$TMP/tabs.json" 2>"$TMP/tabs.err" && grep -q "BLOCKING DIALOG" "$TMP/tabs.err" && python3 -c 'import json,sys; rows=json.load(open(sys.argv[1])); assert any(sys.argv[2] in r["url"] for r in rows)' "$TMP/tabs.json" "$MARK"; then
    pass "tabs --window warns and retains JSON output"
else fail "tabs --window warning and JSON output"; fi

# Default screenshot takes the capture resolver rather than the document path.
CURRENT_URL=$("$SB" get url 2>/dev/null)
if [[ "$CURRENT_URL" == *"$MARK"* ]]; then
    if "$SB" screenshot "$TMP/default-capture.png" >"$TMP/capture.out" 2>"$TMP/capture.err"; then
        if grep -q "BLOCKING DIALOG" "$TMP/capture.err" && [[ -s "$TMP/default-capture.png" ]]; then
            pass "default screenshot warns for its capture window"
        else fail "default screenshot warning"; fi
    elif grep -q "Screen Recording" "$TMP/capture.err"; then
        skip "default screenshot (Screen Recording not granted)"
    else fail "default screenshot capture" "$(cat "$TMP/capture.err")"; fi
else skip "default screenshot (fixture is not the front Safari tab)"; fi

# ── 2. Opt-out ───────────────────────────────────────────────────────────
ERR=$(SAFARI_BROWSER_NO_DIALOG_PROBE=1 "$SB" get title "${LOCK[@]}" 2>&1 >/dev/null)
if echo "$ERR" | grep -q "BLOCKING DIALOG"; then
    fail "SAFARI_BROWSER_NO_DIALOG_PROBE=1 disables the probe" "$ERR"
else
    pass "SAFARI_BROWSER_NO_DIALOG_PROBE=1 disables the probe"
fi

# #136: both exec paths must preserve warning stderr and result JSON.
check_exec_dialog() {
    local label="$1" namespace="$2"
    if python3 - "$SB" "$MARK" "$namespace" <<'EXEC_PY'
import json, os, subprocess, sys
binary, marker, namespace = sys.argv[1:]
env = dict(os.environ, SAFARI_BROWSER_NAME=namespace)
env.pop("SAFARI_BROWSER_DAEMON", None)
steps = [{"cmd":"get title"}, {"cmd":"js", "args":["1+1"], "onError":"continue"}]
try:
    r = subprocess.run([binary, "exec", "--url", marker], input=json.dumps(steps),
                       text=True, capture_output=True, env=env, timeout=20)
    assert r.returncode == 0, r.stderr
    rows = json.loads(r.stdout)
    assert rows[0]["status"] == "ok" and "Dialog Test Page" in rows[0]["value"], rows
    assert rows[1]["status"] == "error", rows
    assert "BLOCKING DIALOG" in r.stderr, r.stderr
    assert "[daemon fallback" not in r.stderr, r.stderr
except (AssertionError, ValueError, subprocess.TimeoutExpired) as error:
    print(f"exec dialog verification failed: {error}")
    raise SystemExit(1)
EXEC_PY
    then pass "$label: warning stderr and success/error JSON results"
    else fail "$label"
    fi
}
check_exec_dialog "stateless exec" "no-daemon-exec-$$"

# ── 3. Daemon parity ─────────────────────────────────────────────────────
echo "## Daemon path"
if SAFARI_BROWSER_NAME="$NAME" "$SB" daemon start >"$TMP/daemon.out" 2>&1; then
    # A fresh daemon can answer the first request with an empty response and
    # the client falls back to stateless (its own warning line); retry so the
    # assertion is about the daemon path, and skip if it never answers.
    # Bounded: with a dialog up, the daemon path has been seen to hang far
    # past the client's 15 s socket timeout (pre-existing daemon behaviour,
    # #130). A hang here must not wedge this test.
    D_EXIT=124
    for attempt in 1 2 3; do
        SAFARI_BROWSER_DAEMON=1 SAFARI_BROWSER_NAME="$NAME" "$SB" get title "${LOCK[@]}" \
            >"$TMP/daemon-title.out" 2>"$TMP/daemon-title.err" &
        D_PID=$!
        for _ in $(seq 1 40); do kill -0 "$D_PID" 2>/dev/null || break; sleep 0.5; done
        if kill -0 "$D_PID" 2>/dev/null; then
            kill "$D_PID" 2>/dev/null; wait "$D_PID" 2>/dev/null
            D_EXIT=124
            break
        fi
        wait "$D_PID"; D_EXIT=$?
        grep -q '\[daemon fallback' "$TMP/daemon-title.err" || break
        sleep 0.5
    done
    D_ERR=$(cat "$TMP/daemon-title.err")
    D_FIRST=$(echo "$D_ERR" | head -1)
    if [[ "$D_EXIT" -eq 124 ]]; then
        fail "daemon parity exceeded 20 s (#130 regression)"
    elif [[ "$D_ERR" == *"[daemon fallback"* ]]; then
        fail "daemon parity unexpectedly fell back: $D_FIRST"
    elif [[ "$D_EXIT" -eq 0 && "$D_FIRST" == *"BLOCKING DIALOG"* ]] && grep -q "Dialog Test Page" "$TMP/daemon-title.out"; then
        pass "daemon path: same first-line warning, same stdout, exit 0"
    else
        fail "daemon parity" "exit=$D_EXIT first='$D_FIRST' stdout=$(cat "$TMP/daemon-title.out")"
    fi
    check_exec_dialog "daemon exec request 1" "$NAME"
    check_exec_dialog "daemon exec request 2" "$NAME"
    SAFARI_BROWSER_NAME="$NAME" "$SB" daemon stop >/dev/null 2>&1 || true
else
    skip "daemon parity (daemon start failed: $(head -1 "$TMP/daemon.out"))"
fi

# ── 4. JavaScript refuses fast ───────────────────────────────────────────
echo "## JavaScript with the dialog up"
T0=$(now_ms) || { fail "timing failed"; exit 1; }
JS_OUT=$("$SB" js "${LOCK[@]}" "1+1" 2>"$TMP/js.err")
JS_EXIT=$?
T1=$(now_ms) || { fail "timing failed"; exit 1; }
JS_MS=$((T1 - T0))
if [[ "$JS_EXIT" -ne 0 ]]; then
    pass "js exits non-zero"
else
    fail "js exits non-zero" "exit=0 stdout=$JS_OUT"
fi
if [[ "$JS_MS" -lt 3000 ]]; then
    pass "js fails fast: ${JS_MS} ms (osascript's own timeout is 30 s)"
else
    fail "js fails fast" "took ${JS_MS} ms"
fi
if grep -qi "dialog" "$TMP/js.err"; then
    pass "js error names the dialog"
else
    fail "js error names the dialog" "$(cat "$TMP/js.err")"
fi

# ── 5. list → dismiss by name → back to normal ───────────────────────────
echo "## Recovery"
"$SB" tab focus "${LOCK[@]}" >/dev/null 2>&1 || true
LISTING=$("$SB" dialog list 2>&1)
BTN=$(echo "$LISTING" | dialog_button)
if [[ -n "$BTN" ]]; then
    pass "dialog list shows a dialog with a button (\"$BTN\")"
else
    fail "dialog list shows the dialog" "$LISTING"
fi
if [[ -n "$BTN" ]] && dismiss_fixture_dialog "$BTN" >"$TMP/dismiss.out" 2>&1; then
    pass "dialog dismiss --button \"$BTN\""
else
    fail "dialog dismiss" "$(cat "$TMP/dismiss.out" 2>/dev/null)"
fi
sleep 0.5
AFTER=$(SAFARI_BROWSER_DIALOG_PROBE_DEBUG=1 "$SB" js "${LOCK[@]}" "1+1" 2>"$TMP/after.err")
AFTER_EXIT=$?
if [[ "$AFTER_EXIT" -eq 0 && "$AFTER" == *2* ]]; then
    pass "js works again after dismissal"
else
    fail "js works again after dismissal" "exit=$AFTER_EXIT stdout=$AFTER stderr=$(cat "$TMP/after.err")"
fi
if python3 - "$TMP/after.err" <<'JS_BUDGET_PY'
import re,sys
values=[int(v) for v in re.findall(r'dialog probe: .*? (\d+) ms\b',open(sys.argv[1]).read())]
assert values and sum(values)<=200, f"JS command probe budget: {values}"
print(f"      JS command total probe cost: {sum(values)} ms ({values})")
JS_BUDGET_PY
then pass "JS command cumulative probe cost stays within 200 ms"
else fail "JS command cumulative probe budget"; fi
ERR=$("$SB" get title "${LOCK[@]}" 2>&1 >/dev/null)
if echo "$ERR" | grep -q "BLOCKING DIALOG"; then
    fail "no warning after dismissal" "$ERR"
else
    pass "no warning after dismissal"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
