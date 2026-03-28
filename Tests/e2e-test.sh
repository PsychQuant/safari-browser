#!/bin/bash
# E2E tests for safari-browser
# Requires: Safari running, binary installed at ~/bin/safari-browser
set -e

SB="$HOME/bin/safari-browser"
TEST_PAGE="file://$(cd "$(dirname "$0")" && pwd)/Fixtures/test-page.html"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1: $2"; }

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

# Summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
