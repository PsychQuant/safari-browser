#!/bin/bash
# E2E tests for safari-browser
# Requires: Safari running, binary installed at ~/bin/safari-browser
#
# Binary under test: override with SAFARI_BROWSER_BIN=.build/debug/safari-browser
# to exercise current source (the default ~/bin build can be weeks-stale and
# predate the feature under test).
set -e

SB="${SAFARI_BROWSER_BIN:-$HOME/bin/safari-browser}"
TEST_PAGE="file://$(cd "$(dirname "$0")" && pwd)/Fixtures/test-page.html"
PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1: $2"; }
skip() { SKIP=$((SKIP + 1)); echo "  ⊘ SKIP $1"; }

# A window pixel-capture failure means the CONTROLLING process (the one
# spawning safari-browser) lacks macOS Screen Recording permission — which is
# absent in headless / CI / background-job contexts and is environment, not
# code (the installed binary fails identically there). Such an assertion is
# skipped, not failed. Grant Screen Recording to the controlling terminal to
# exercise real pixel capture.
is_capture_denied() {
    echo "$1" | grep -qiE "could not create image|screen recording|not authorized|kCGError|CGWindowList|operation not permitted"
}

echo "=== safari-browser E2E Tests ==="
echo "Test page: $TEST_PAGE"
echo ""

# Setup: open test page
$SB open "$TEST_PAGE" 2>/dev/null
sleep 2

# 1. Navigation
echo "## Navigation"
URL=$($SB get url 2>/dev/null)
if echo "$URL" | grep -q "test-page.html"; then
    pass "open + get url"
else
    fail "open + get url" "got: $URL"
fi

# 2. JavaScript execution
echo "## JavaScript"
RESULT=$($SB js "1 + 1" 2>/dev/null)
if echo "$RESULT" | grep -q "2"; then
    pass "js returns value"
else
    fail "js returns value" "got: $RESULT"
fi

TITLE=$($SB js "document.title" 2>/dev/null)
if echo "$TITLE" | grep -q "Safari Browser Test Page"; then
    pass "js returns document.title"
else
    fail "js returns document.title" "got: $TITLE"
fi

# 3. Snapshot
echo "## Snapshot"
SNAP=$($SB snapshot 2>/dev/null)
if echo "$SNAP" | grep -q "@e1"; then
    pass "snapshot finds elements"
else
    fail "snapshot finds elements" "got: $SNAP"
fi

# 4. Get info
echo "## Get Info"
GTITLE=$($SB get title 2>/dev/null)
if echo "$GTITLE" | grep -q "Safari Browser Test Page"; then
    pass "get title"
else
    fail "get title" "got: $GTITLE"
fi

GTEXT=$($SB get text "h1" 2>/dev/null)
if [ -n "$GTEXT" ]; then
    pass "get text h1"
else
    fail "get text h1" "empty result"
fi

# 5. Wait
echo "## Wait"
START=$(date +%s%N)
$SB wait 500 2>/dev/null
END=$(date +%s%N)
ELAPSED=$(( (END - START) / 1000000 ))
if [ "$ELAPSED" -gt 400 ]; then
    pass "wait 500ms (took ${ELAPSED}ms)"
else
    fail "wait 500ms" "only ${ELAPSED}ms"
fi

# 6. Error handling
echo "## Error Handling"
if ! $SB click ".nonexistent-xyz-12345" 2>/dev/null; then
    pass "click nonexistent → error"
else
    fail "click nonexistent" "should have failed"
fi

if ! $SB click "@e99" 2>/dev/null; then
    pass "click invalid ref → error"
else
    fail "click invalid ref" "should have failed"
fi

# 7. Element interaction (fill + get value)
echo "## Element Interaction"
$SB open "$TEST_PAGE" 2>/dev/null
sleep 1
$SB fill "input#name" "TestUser" 2>/dev/null
VAL=$($SB get value "input#name" 2>/dev/null)
if echo "$VAL" | grep -q "TestUser"; then
    pass "fill + get value"
else
    fail "fill + get value" "got: $VAL"
fi

# 8. URL matching pipeline (#33 + #34)
echo "## URL Matching Pipeline"

# Open the test page in a second tab (deliberate duplicate) to create
# a multi-match scenario for --first-match and --url-endswith.
$SB open "$TEST_PAGE" --new-tab 2>/dev/null
sleep 1

# 8a. --first-match recovers from multi-match (#33 plumb-through)
if $SB js "document.title" --url "test-page" --first-match > /tmp/sb-fm-out 2> /tmp/sb-fm-err; then
    if grep -q "warning: --first-match" /tmp/sb-fm-err; then
        pass "--first-match recovers multi-match + emits stderr warning"
    else
        fail "--first-match recovers multi-match" "no stderr warning: $(cat /tmp/sb-fm-err)"
    fi
else
    fail "--first-match recovers multi-match" "command failed: $(cat /tmp/sb-fm-err)"
fi

# 8b. --url alone (no --first-match) still fails closed on multi-match
if ! $SB js "document.title" --url "test-page" > /tmp/sb-fc-out 2> /tmp/sb-fc-err; then
    if grep -q "ambiguousWindowMatch\|Multiple Safari windows match" /tmp/sb-fc-err; then
        pass "multi-match fails closed without --first-match"
    else
        fail "multi-match fails closed without --first-match" "unexpected stderr: $(cat /tmp/sb-fc-err)"
    fi
else
    fail "multi-match fails closed without --first-match" "expected non-zero exit"
fi

# 8c. --url-endswith + --first-match (#34 precise matching for all matcher kinds)
if $SB js "document.title" --url-endswith "test-page.html" --first-match > /dev/null 2>&1; then
    pass "--url-endswith + --first-match works across matcher kinds"
else
    fail "--url-endswith + --first-match" "command failed"
fi

# 8d. Invalid regex rejected at validate time
if ! $SB js "1" --url-regex "[" > /dev/null 2> /tmp/sb-regex-err; then
    if grep -q "url-regex" /tmp/sb-regex-err; then
        pass "--url-regex invalid pattern rejected at validate time"
    else
        fail "--url-regex invalid pattern rejected" "error doesn't mention --url-regex: $(cat /tmp/sb-regex-err)"
    fi
else
    fail "--url-regex invalid pattern rejected" "expected non-zero exit"
fi

# 8e. Conflicting URL flags rejected
if ! $SB js "1" --url "x" --url-endswith "/y" > /dev/null 2> /tmp/sb-conflict-err; then
    if grep -q "mutually exclusive" /tmp/sb-conflict-err; then
        pass "conflicting URL flags rejected with 'mutually exclusive' error"
    else
        fail "conflicting URL flags rejected" "error doesn't say 'mutually exclusive': $(cat /tmp/sb-conflict-err)"
    fi
else
    fail "conflicting URL flags rejected" "expected non-zero exit"
fi

# 9. Screenshot (#44: --content-only constraint + no phantom file)
echo "## Screenshot"
SHOT=/tmp/sb-e2e-shot.png
rm -f "$SHOT"
SHOT_ERR=$($SB screenshot "$SHOT" 2>&1 >/dev/null || true)
if [ -s "$SHOT" ]; then
    pass "screenshot writes a non-empty PNG"
elif is_capture_denied "$SHOT_ERR"; then
    skip "screenshot pixel-capture — no Screen Recording permission ($SHOT_ERR)"
else
    fail "screenshot did not produce a file" "no $SHOT (stderr: $SHOT_ERR)"
fi

# #44: --content-only EITHER succeeds (front tab + AX permission) OR fails with
# the truthful constraint error AND leaves NO file behind (never a phantom
# un-cropped one — the old misleading 'may be the original' hint is gone).
CO=/tmp/sb-e2e-shot-content.png
rm -f "$CO"
CO_ERR=$($SB screenshot "$CO" --content-only 2>&1 >/dev/null || true)
if [ -s "$CO" ]; then
    pass "screenshot --content-only produced a cropped PNG (front tab + AX)"
elif [ -e "$CO" ]; then
    fail "#44: --content-only failed but left a phantom file at $CO" "$(ls -l "$CO" 2>/dev/null)"
elif echo "$CO_ERR" | grep -qE "front tab|Accessibility|--content-only|NO file"; then
    pass "#44: --content-only failure leaves NO file + states the real constraint"
elif is_capture_denied "$CO_ERR"; then
    skip "screenshot --content-only — no Screen Recording permission ($CO_ERR)"
else
    fail "#44: --content-only failed without the truthful constraint message" "$CO_ERR"
fi
rm -f "$SHOT" "$CO"

# Cleanup: close the duplicate tab to keep test state idempotent.
$SB close --url-endswith "test-page.html" --first-match 2>/dev/null || true

rm -f /tmp/sb-fm-out /tmp/sb-fm-err /tmp/sb-fc-out /tmp/sb-fc-err /tmp/sb-regex-err /tmp/sb-conflict-err

# Summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
