#!/bin/bash
# E2E tests for #79: identity-anchored target resolution.
#
# Reproduces the #79 live incident deterministically: a multi-round-trip
# `js --url` command runs while Safari's window z-order churns underneath
# it. Pre-#79 the frozen positional ref (`tab T of window N`) followed the
# z-order and dispatched JS into whatever tab moved into that position
# (cross-tab injection / silent wrong result). Post-#79 the ref is
# `tab T of window id W` — immune to z-order — plus an in-script URL guard
# and a bounded re-resolve retry.
#
# Non-interference: the z-order churn raises ONLY the two windows this
# suite opens itself (addressed by their stable window ids), never the
# user's own windows.
#
# Requires: Safari running, binary at ~/bin/safari-browser
# Override binary: SAFARI_BROWSER_BIN=.build/debug/safari-browser
set -u

SB="${SAFARI_BROWSER_BIN:-$HOME/bin/safari-browser}"
FIXDIR="$(cd "$(dirname "$0")" && pwd)/Fixtures"
PAGE_A="file://$FIXDIR/test-page.html"          # title: Safari Browser Test Page
PAGE_B="file://$FIXDIR/csp-strict-page.html"    # title: CSP Strict Test Page
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1: $2"; }

# Close EVERY tab matching a fixture URL — stale tabs from earlier runs
# make --url multi-match fail-closed refuse (correctly) and poison every
# assertion. --first-match closes one candidate per iteration. Patterns
# are the FULL fixture paths (verify finding: a bare "test-page" substring
# could match an unrelated user tab — non-interference requires precision).
close_all() {
    local pattern="$1"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        $SB close --url "$pattern" --first-match 2>/dev/null || return 0
        sleep 0.3
    done
}
cleanup() {
    close_all "Tests/Fixtures/test-page.html"
    close_all "Tests/Fixtures/csp-strict-page.html"
}
trap cleanup EXIT

echo "=== safari-browser target-identity E2E Tests (#79) ==="
echo ""

# Look up the stable id of OUR window by its fixture URL — immune to
# z-order/timing (a `window 1` read can race the window animation and
# return the wrong window's id).
window_id_for() {
    osascript -e "tell application \"Safari\"
        repeat with w in windows
            repeat with t in tabs of w
                if URL of t contains \"$1\" then return id of w
            end repeat
        end repeat
        return \"\"
    end tell"
}

# Pre-clean stale fixture tabs from earlier runs, then open two dedicated
# windows so z-order churn never touches user windows.
cleanup
$SB open --new-window "$PAGE_A" 2>/dev/null || { echo "FATAL: cannot open window A"; exit 1; }
sleep 2
$SB open --new-window "$PAGE_B" 2>/dev/null || { echo "FATAL: cannot open window B"; exit 1; }
sleep 2
WID_A=$(window_id_for "Tests/Fixtures/test-page.html")
WID_B=$(window_id_for "Tests/Fixtures/csp-strict-page.html")
if [ -z "$WID_A" ] || [ -z "$WID_B" ] || [ "$WID_A" = "$WID_B" ]; then
    echo "FATAL: expected two distinct test windows, got A='$WID_A' B='$WID_B'"
    exit 1
fi
echo "test windows: A=id $WID_A (test-page), B=id $WID_B (csp-strict-page)"

# Raise one of OUR two windows every 300ms, alternating — lands mid-protocol
# for the ~6-round-trip js command. Addressed by window id: user windows are
# never touched.
churn() {
    for i in 1 2 3 4 5 6 7 8; do
        if [ $((i % 2)) -eq 0 ]; then W=$WID_A; else W=$WID_B; fi
        osascript -e "tell application \"Safari\" to set index of (window id $W) to 1" >/dev/null 2>&1
        sleep 0.3
    done
}

echo "## baseline (no churn)"
T=$($SB js "document.title" --url test-page 2>&1)
if [ "$T" = "Safari Browser Test Page" ]; then
    pass "js resolves target by URL"
else
    fail "js resolves target by URL" "got: $T"
fi

echo "## multi-roundtrip js under z-order churn (the #79 incident)"
churn & CHURN_PID=$!
T=$($SB js "var t = document.title; return t;" --url test-page 2>&1)
wait $CHURN_PID
if [ "$T" = "Safari Browser Test Page" ]; then
    pass "js statement body hits the ORIGINAL tab despite z-order churn"
else
    fail "js statement body hits the ORIGINAL tab despite z-order churn" "got: $T"
fi

churn & CHURN_PID=$!
T=$($SB js --large "document.title" --url csp-strict-page 2>&1)
wait $CHURN_PID
if [ "$T" = "CSP Strict Test Page" ]; then
    pass "js --large chunked read hits the ORIGINAL tab despite z-order churn"
else
    fail "js --large chunked read hits the ORIGINAL tab despite z-order churn" "got: $T"
fi

echo "## cross-target discrimination under churn"
churn & CHURN_PID=$!
TA=$($SB js "document.title" --url test-page 2>&1)
TB=$($SB js "document.title" --url csp-strict-page 2>&1)
wait $CHURN_PID
if [ "$TA" = "Safari Browser Test Page" ] && [ "$TB" = "CSP Strict Test Page" ]; then
    pass "two interleaved targets each get their own tab's result"
else
    fail "two interleaved targets each get their own tab's result" "A: $TA / B: $TB"
fi

echo "## dangle → bounded retry (#78 smoke)"
# Close and reopen window B, then target it immediately without settling —
# pre-#79 this raced -1719 (resolve-then-execute gap). The built-in bounded
# retry must absorb the transient: NO manual second attempt (verify finding:
# an escape-hatch retry here would mask a broken auto-retry). A failure on
# the first invocation is a test failure.
$SB close --url csp-strict-page 2>/dev/null
$SB open "$PAGE_B" 2>/dev/null
R=$($SB js "1+1" --url csp-strict-page 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ "$R" = "2" ]; then
    pass "open → immediate js on --url target (auto-retry, no manual fallback)"
else
    fail "open → immediate js on --url target (auto-retry, no manual fallback)" "rc=$RC got: $R"
fi

echo "## missing-target fail-closed: no silent wrong-tab result"
# Scope note (verify finding): this exercises the RESOLUTION-miss path
# (target gone before resolve), not the mid-command guard trip — the
# latter needs sub-roundtrip timing injection and is pinned by unit tests
# on urlGuardClause / isTargetDangleError instead.
$SB close --url csp-strict-page 2>/dev/null
ERR=$($SB js "document.title" --url csp-strict-page 2>&1); RC=$?
if [ "$RC" -ne 0 ] && ! echo "$ERR" | grep -q "Safari Browser Test Page"; then
    pass "missing target errors instead of answering from another tab"
else
    fail "missing target errors instead of answering from another tab" "rc=$RC got: $ERR"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
