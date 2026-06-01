#!/bin/bash
# E2E tests for `tab focus` — switch the active tab by target (#45).
#
# Requires: Safari running. Drives a real window with two tabs and asserts
# the AppleScript `set current tab` actually fronts the resolved tab (the one
# runtime effect the unit layer can't confirm — pickNativeTarget resolution is
# unit-tested; the live tab switch is not).
#
# Usage:
#   make test-tab-focus
#   ./Tests/e2e-tab-focus.sh            # uses ~/bin/safari-browser
#   SAFARI_BROWSER_BIN=.build/debug/safari-browser ./Tests/e2e-tab-focus.sh
#
# Non-interference note: this opens a NEW Safari window for the test and closes
# its tabs at the end; it does not touch your existing windows' tab selection.
set -u

SB="${SAFARI_BROWSER_BIN:-$HOME/bin/safari-browser}"
FIXTURE="file://$(cd "$(dirname "$0")" && pwd)/Fixtures/test-page.html"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "      $2"; }

if [[ ! -x "$SB" ]]; then echo "SKIP: binary not found: $SB (run 'make install' or set SAFARI_BROWSER_BIN)"; exit 77; fi

echo "=== safari-browser \`tab focus\` E2E (#45) ==="
echo "Binary: $SB"
echo ""

URL_A="${FIXTURE}?tabfocus=AAA"
URL_B="${FIXTURE}?tabfocus=BBB"

# Open a fresh window with tab A, then add tab B in the SAME window.
# Distinct query strings → exact-match focus-existing won't collapse them,
# so we genuinely get two separate tabs.
"$SB" open "$URL_A" --new-window >/dev/null 2>&1; sleep 1.5
"$SB" open "$URL_B" --new-tab     >/dev/null 2>&1; sleep 1.5

# After opening B with --new-tab, B should be the current tab.
CUR=$("$SB" get url 2>/dev/null || true)
if [[ "$CUR" == *"tabfocus=BBB"* ]]; then
    pass "setup: tab B is current after --new-tab"
else
    echo "SKIP: setup did not land on tab B (got: $CUR) — window/tab state unexpected; aborting"
    exit 77
fi

echo "## tab focus --url switches the active tab (no navigation)"
"$SB" tab focus --url "tabfocus=AAA" >/dev/null 2>&1; sleep 1
CUR=$("$SB" get url 2>/dev/null || true)
if [[ "$CUR" == *"tabfocus=AAA"* ]]; then
    pass "tab focus --url 'tabfocus=AAA' makes A current"
else
    fail "tab focus did not switch to A" "current url: $CUR"
fi

# Switch back to B by URL — confirms it's a real switch, not a one-way fluke.
"$SB" tab focus --url "tabfocus=BBB" >/dev/null 2>&1; sleep 1
CUR=$("$SB" get url 2>/dev/null || true)
if [[ "$CUR" == *"tabfocus=BBB"* ]]; then
    pass "tab focus --url 'tabfocus=BBB' switches back to B"
else
    fail "tab focus did not switch back to B" "current url: $CUR"
fi

echo "## idempotent — focusing the already-current tab is a no-op (exit 0)"
"$SB" tab focus --url "tabfocus=BBB" >/dev/null 2>&1
RC=$?
if [[ "$RC" -eq 0 ]]; then
    pass "tab focus on already-current tab exits 0"
else
    fail "tab focus idempotent no-op should exit 0" "got exit $RC"
fi

echo "## state-preservation: no re-navigation (form/scroll survive)"
# Set a JS marker on tab A, switch away and back, confirm it survives — proving
# `set current tab` did NOT reload the tab (the whole point vs open --replace-tab).
"$SB" tab focus --url "tabfocus=AAA" >/dev/null 2>&1; sleep 1
"$SB" js "window.__sbTabFocusMarker = 'survived'" >/dev/null 2>&1
"$SB" tab focus --url "tabfocus=BBB" >/dev/null 2>&1; sleep 1
"$SB" tab focus --url "tabfocus=AAA" >/dev/null 2>&1; sleep 1
MARKER=$("$SB" js "window.__sbTabFocusMarker || 'LOST'" 2>/dev/null || true)
if [[ "$MARKER" == *"survived"* ]]; then
    pass "JS state survives tab focus round-trip (no reload)"
else
    fail "tab focus appears to have reloaded the tab (marker lost)" "got: $MARKER"
fi

# Cleanup: close the two test tabs we created in this window.
"$SB" tab focus --url "tabfocus=BBB" >/dev/null 2>&1; "$SB" close >/dev/null 2>&1
"$SB" tab focus --url "tabfocus=AAA" >/dev/null 2>&1; "$SB" close >/dev/null 2>&1

echo ""
echo "───────────────────────────────────────────────"
echo "tab focus E2E: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
