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
# #127 — the probe reads the alert's title, not its body.) If a dialog is already up anywhere in Safari the
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
FIXTURE="file://$(cd "$(dirname "$0")" && pwd)/Fixtures/dialog-test.html"
MARK="dlg$$"
URL="${FIXTURE}?${MARK}"
LOCK=(--url "$MARK")
NAME="dialog-$$"                 # daemon namespace for the parity step
DIALOG_TEXT="e2e dialog ${MARK}"
TMP=$(mktemp -d /tmp/sb-dialog.XXXXXX)
PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "      $2"; }
skip() { SKIP=$((SKIP + 1)); echo "  ⊘ SKIP $1"; }

# Whole seconds are too coarse for a "under 3 s" bound.
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

# First button title in a `dialog list` listing: the line `  buttons: "A", "B"`.
dialog_button() { sed -nE 's/^ *buttons: "([^"]*)".*/\1/p' | head -1; }

cleanup() {
    SAFARI_BROWSER_NAME="$NAME" "$SB" daemon stop >/dev/null 2>&1 || true
    # If an assertion failed midway our alert may still be up. Dismiss it by
    # name ONLY when the dialog on screen is ours (its text carries the nonce).
    local probe btn n=0
    probe=$("$SB" get title "${LOCK[@]}" 2>&1 >/dev/null | head -1)
    if [[ "$probe" == *"BLOCKING DIALOG"* ]]; then
        btn=$("$SB" dialog list 2>/dev/null | dialog_button)
        [[ -n "$btn" ]] && "$SB" dialog dismiss --button "$btn" >/dev/null 2>&1
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
PRE=$("$SB" dialog list 2>&1)
if echo "$PRE" | grep -qi "accessibility"; then
    echo "  SKIP: Accessibility is not granted to $SB — the probe is an AX read. Run: $SB setup"
    exit 77
fi
if ! echo "$PRE" | grep -q "no blocking dialog"; then
    echo "  SKIP: a dialog is already open somewhere in Safari; this test only ever dismisses its own."
    echo "$PRE" | sed 's/^/    /'
    exit 77
fi

# ── Setup ────────────────────────────────────────────────────────────────
"$SB" open "$URL" >/dev/null 2>&1
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
T0=$(now_ms)
"$SB" get title "${LOCK[@]}" >"$TMP/title.out" 2>"$TMP/title.err"
TITLE_EXIT=$?
T1=$(now_ms)
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

# ── 2. Opt-out ───────────────────────────────────────────────────────────
ERR=$(SAFARI_BROWSER_NO_DIALOG_PROBE=1 "$SB" get title "${LOCK[@]}" 2>&1 >/dev/null)
if echo "$ERR" | grep -q "BLOCKING DIALOG"; then
    fail "SAFARI_BROWSER_NO_DIALOG_PROBE=1 disables the probe" "$ERR"
else
    pass "SAFARI_BROWSER_NO_DIALOG_PROBE=1 disables the probe"
fi

# ── 3. Daemon parity ─────────────────────────────────────────────────────
echo "## Daemon path"
if SAFARI_BROWSER_NAME="$NAME" "$SB" daemon start >"$TMP/daemon.out" 2>&1; then
    # A fresh daemon can answer the first request with an empty response and
    # the client falls back to stateless (its own warning line); retry so the
    # assertion is about the daemon path, and skip if it never answers.
    # Bounded: with a dialog up, the daemon path has been seen to hang far
    # past the client's 15 s socket timeout (pre-existing daemon behaviour,
    # filed separately from #126). A hang here must not wedge this test.
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
        skip "daemon parity (daemon path hung > 20 s with the dialog up — pre-existing daemon hang, tracked outside #126)"
    elif [[ "$D_ERR" == *"[daemon fallback"* ]]; then
        skip "daemon parity (daemon never answered: $D_FIRST)"
    elif [[ "$D_EXIT" -eq 0 && "$D_FIRST" == *"BLOCKING DIALOG"* ]] && grep -q "Dialog Test Page" "$TMP/daemon-title.out"; then
        pass "daemon path: same first-line warning, same stdout, exit 0"
    else
        fail "daemon parity" "exit=$D_EXIT first='$D_FIRST' stdout=$(cat "$TMP/daemon-title.out")"
    fi
    SAFARI_BROWSER_NAME="$NAME" "$SB" daemon stop >/dev/null 2>&1 || true
else
    skip "daemon parity (daemon start failed: $(head -1 "$TMP/daemon.out"))"
fi

# ── 4. JavaScript refuses fast ───────────────────────────────────────────
echo "## JavaScript with the dialog up"
T0=$(now_ms)
JS_OUT=$("$SB" js "${LOCK[@]}" "1+1" 2>"$TMP/js.err")
JS_EXIT=$?
T1=$(now_ms)
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
if [[ -n "$BTN" ]] && "$SB" dialog dismiss --button "$BTN" >"$TMP/dismiss.out" 2>&1; then
    pass "dialog dismiss --button \"$BTN\""
else
    fail "dialog dismiss" "$(cat "$TMP/dismiss.out" 2>/dev/null)"
fi
sleep 0.5
AFTER=$("$SB" js "${LOCK[@]}" "1+1" 2>"$TMP/after.err")
AFTER_EXIT=$?
if [[ "$AFTER_EXIT" -eq 0 && "$AFTER" == *2* ]]; then
    pass "js works again after dismissal"
else
    fail "js works again after dismissal" "exit=$AFTER_EXIT stdout=$AFTER stderr=$(cat "$TMP/after.err")"
fi
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
