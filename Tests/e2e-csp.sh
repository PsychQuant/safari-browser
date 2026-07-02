#!/bin/bash
# E2E tests for #76: js + interaction commands on a strict-CSP page
# (script-src without 'unsafe-eval').
#
# What this pins down:
#   - `js` is eval-free — expressions and statement bodies both run on
#     pages whose CSP refuses page-context eval() (facebook.com, claude.ai).
#   - User code that itself calls eval() gets the actionable CSP hint.
#   - Interaction commands (click / scroll / press) keep working — they
#     were never CSP-affected (inline injection, no eval).
#
# Requires: Safari running, binary at ~/bin/safari-browser
# Override binary: SAFARI_BROWSER_BIN=.build/debug/safari-browser
set -e

SB="${SAFARI_BROWSER_BIN:-$HOME/bin/safari-browser}"
TEST_PAGE="file://$(cd "$(dirname "$0")" && pwd)/Fixtures/csp-strict-page.html"
LOCK=(--url csp-strict-page)
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1: $2"; }

echo "=== safari-browser CSP E2E Tests (#76) ==="
echo "Test page: $TEST_PAGE"
echo ""

# Setup
$SB open "$TEST_PAGE" 2>/dev/null
sleep 2

echo "## js on strict-CSP page"

RESULT=$($SB js "1 + 1" "${LOCK[@]}" 2>/dev/null)
if [ "$RESULT" = "2" ]; then
    pass "js expression"
else
    fail "js expression" "got: $RESULT"
fi

RESULT=$($SB js "1+1 // trailing comment" "${LOCK[@]}" 2>/dev/null)
if [ "$RESULT" = "2" ]; then
    pass "js expression with trailing comment"
else
    fail "js expression with trailing comment" "got: $RESULT"
fi

RESULT=$($SB js "var a = 2; return a + 3;" "${LOCK[@]}" 2>/dev/null)
if [ "$RESULT" = "5" ]; then
    pass "js statement body with return"
else
    fail "js statement body with return" "got: $RESULT"
fi

RESULT=$($SB js "document.title" "${LOCK[@]}" 2>/dev/null)
if [ "$RESULT" = "CSP Strict Test Page" ]; then
    pass "js DOM read"
else
    fail "js DOM read" "got: $RESULT"
fi

RESULT=$($SB js --large "document.title" "${LOCK[@]}" 2>/dev/null)
if [ "$RESULT" = "CSP Strict Test Page" ]; then
    pass "js --large expression"
else
    fail "js --large expression" "got: $RESULT"
fi

RESULT=$($SB js --large "var t = document.title; return t + '!';" "${LOCK[@]}" 2>/dev/null)
if [ "$RESULT" = "CSP Strict Test Page!" ]; then
    pass "js --large statement body with return"
else
    fail "js --large statement body with return" "got: $RESULT"
fi

echo "## error paths"

ERR=$($SB js "eval('1+1')" "${LOCK[@]}" 2>&1 || true)
if echo "$ERR" | grep -q "Refused to evaluate" && echo "$ERR" | grep -q "Hint:"; then
    pass "user-code eval() gets CSP hint"
else
    fail "user-code eval() gets CSP hint" "got: $ERR"
fi

ERR=$($SB js "1+" "${LOCK[@]}" 2>&1 || true)
if echo "$ERR" | grep -q "JavaScript syntax error"; then
    pass "genuine syntax error reported"
else
    fail "genuine syntax error reported" "got: $ERR"
fi

ERR=$($SB js "null.foo" "${LOCK[@]}" 2>&1 || true)
if echo "$ERR" | grep -q "JavaScript error" && ! echo "$ERR" | grep -q "Hint:"; then
    pass "runtime error has no spurious CSP hint"
else
    fail "runtime error has no spurious CSP hint" "got: $ERR"
fi

echo "## interaction commands on strict-CSP page (never eval-routed)"

if $SB click "#btn" "${LOCK[@]}" 2>/dev/null; then
    pass "click"
else
    fail "click" "exit $?"
fi

if $SB scroll down 400 "${LOCK[@]}" 2>/dev/null; then
    SCROLLY=$($SB js "window.scrollY" "${LOCK[@]}" 2>/dev/null)
    if [ "$SCROLLY" = "400" ]; then
        pass "scroll down takes effect (scrollY=$SCROLLY)"
    else
        fail "scroll down takes effect" "scrollY: $SCROLLY"
    fi
else
    fail "scroll down" "exit $?"
fi

if $SB press PageUp "${LOCK[@]}" 2>/dev/null; then
    pass "press"
else
    fail "press" "exit $?"
fi

# Teardown
$SB close "${LOCK[@]}" 2>/dev/null || true

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
