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
#
# No `set -e` (diverges from e2e-test.sh deliberately): every probe here is a
# $(...) assignment whose failure must be RECORDED as a fail by the pass/fail
# counters — under set -e a single transient (e.g. the #78 open/resolve race)
# kills the whole suite silently with no fail line. Exit status comes from
# the final FAIL count instead.
set -u

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

# Setup — retry once: `open` right after a prior `close` can hit the
# resolve/settle race (#78).
if ! $SB open "$TEST_PAGE" 2>/dev/null; then
    sleep 2
    $SB open "$TEST_PAGE" 2>/dev/null || { echo "FATAL: could not open test page"; exit 1; }
fi
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

# Pins the doJavaScriptLarge invariant (#76 verify round): a legitimately
# empty result must NOT be misread as a parse failure (no "undefined",
# no spurious syntax error, exit 0).
RESULT=$($SB js --large "''" "${LOCK[@]}" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$RESULT" ]; then
    pass "js --large legitimately-empty expression result"
else
    fail "js --large legitimately-empty expression result" "rc=$RC got: $RESULT"
fi

RESULT=$($SB js --large "return '';" "${LOCK[@]}" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$RESULT" ]; then
    pass "js --large legitimately-empty statement result"
else
    fail "js --large legitimately-empty statement result" "rc=$RC got: $RESULT"
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

# Verify-round finding: user-authored errors containing the bare refusal
# phrase must not trigger the CSP hint (tightened predicate).
ERR=$($SB js "throw new Error('Refused to evaluate the submitted form')" "${LOCK[@]}" 2>&1 || true)
if echo "$ERR" | grep -q "Refused to evaluate the submitted form" && ! echo "$ERR" | grep -q "Hint:"; then
    pass "coincidental refusal phrase gets no CSP hint"
else
    fail "coincidental refusal phrase gets no CSP hint" "got: $ERR"
fi

# Verify-round finding: the --large catch/hint branch was untested.
ERR=$($SB js --large "eval('1+1')" "${LOCK[@]}" 2>&1 || true)
if echo "$ERR" | grep -q "Refused to evaluate" && echo "$ERR" | grep -q "Hint:"; then
    pass "js --large user-code eval() gets CSP hint"
else
    fail "js --large user-code eval() gets CSP hint" "got: $ERR"
fi

echo "## interaction commands on strict-CSP page (never eval-routed)"

# Observable click effect: inline onclick handlers are themselves blocked by
# script-src 'self', so arm a listener via `js` (addEventListener runs fine —
# UA-privileged injection), click, then read the flag back. Arming is
# asserted (with one retry) so a transient failure surfaces here instead of
# as a misleading click failure.
ARM_JS="document.getElementById('btn').addEventListener('click', function(){ window.__clicked = 1; }); return 'armed';"
ARMED=$($SB js "$ARM_JS" "${LOCK[@]}" 2>/dev/null)
if [ "$ARMED" != "armed" ]; then
    sleep 1
    ARMED=$($SB js "$ARM_JS" "${LOCK[@]}" 2>/dev/null)
fi
[ "$ARMED" = "armed" ] || fail "click listener arming" "got: $ARMED"
if $SB click "#btn" "${LOCK[@]}" 2>/dev/null; then
    CLICKED=$($SB js "window.__clicked" "${LOCK[@]}" 2>/dev/null)
    if [ "$CLICKED" = "1" ]; then
        pass "click takes effect (listener fired)"
    else
        fail "click takes effect" "window.__clicked: $CLICKED"
    fi
else
    fail "click" "exit $?"
fi

FILL_OK=0
if $SB fill "#field" "hello csp" "${LOCK[@]}" 2>/dev/null; then
    VAL=$($SB js "document.getElementById('field').value" "${LOCK[@]}" 2>/dev/null)
    if [ "$VAL" = "hello csp" ]; then
        pass "fill takes effect (value readback)"
        FILL_OK=1
    else
        fail "fill takes effect" "value: $VAL"
    fi
else
    fail "fill" "exit $?"
fi

if [ "$FILL_OK" = "1" ]; then
    $SB js "document.getElementById('field').value = ''; return 'cleared';" "${LOCK[@]}" >/dev/null 2>&1
    if $SB type "#field" "abc" "${LOCK[@]}" 2>/dev/null; then
        VAL=$($SB js "document.getElementById('field').value" "${LOCK[@]}" 2>/dev/null)
        if [ "$VAL" = "abc" ]; then
            pass "type takes effect (value readback)"
        else
            fail "type takes effect" "value: $VAL"
        fi
    else
        fail "type" "exit $?"
    fi
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

if $SB scrollintoview "#tall" "${LOCK[@]}" 2>/dev/null; then
    pass "scrollintoview"
else
    fail "scrollintoview" "exit $?"
fi

# mouse down/up dispatch on document.activeElement — focus the button first.
ARM_MOUSE_JS="document.getElementById('btn').addEventListener('mousedown', function(){ window.__mdown = 1; }); return 'armed';"
ARMED=$($SB js "$ARM_MOUSE_JS" "${LOCK[@]}" 2>/dev/null)
if [ "$ARMED" != "armed" ]; then
    sleep 1
    ARMED=$($SB js "$ARM_MOUSE_JS" "${LOCK[@]}" 2>/dev/null)
fi
[ "$ARMED" = "armed" ] || fail "mousedown listener arming" "got: $ARMED"
$SB focus "#btn" "${LOCK[@]}" 2>/dev/null || true
if $SB mouse down "${LOCK[@]}" 2>/dev/null && $SB mouse up "${LOCK[@]}" 2>/dev/null; then
    MDOWN=$($SB js "window.__mdown" "${LOCK[@]}" 2>/dev/null)
    if [ "$MDOWN" = "1" ]; then
        pass "mouse down/up takes effect (listener fired)"
    else
        fail "mouse down/up takes effect" "window.__mdown: $MDOWN"
    fi
else
    fail "mouse down/up" "exit $?"
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
