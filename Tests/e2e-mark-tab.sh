#!/bin/bash
# e2e-mark-tab.sh — task 9.3 live-Safari integration test for the
# --mark-tab opt-in. Exercised behaviors:
#   - Bare `--mark-tab` wraps the title before, restores it after
#     (byte-identical to the original).
#   - `--mark-tab-persist` survives the invocation boundary; next
#     `tab is-marked` returns 0.
#   - `tab unmark` cleanly removes a persisted marker.
#   - `--mark-tab` works inside `exec` daemon-routed scripts (Section 7
#     of tab-ownership-marker v2 envelope).
#
# Skips with exit 77 (automake convention) when Safari isn't running
# or the binary isn't installed.

set -u
SB="${SB:-$HOME/bin/safari-browser}"
FIXTURE="$(cd "$(dirname "$0")/.." && pwd)/Tests/Fixtures/test-page.html"
FIXTURE_URL="file://${FIXTURE}"

passed=0
failed=0

pass() { passed=$((passed + 1)); echo "  ✓ $1"; }
fail() {
    failed=$((failed + 1))
    echo "  ✗ $1"
    if [[ -n "${2:-}" ]]; then echo "      $2"; fi
}

cleanup() {
    "$SB" tab unmark --url "test-page.html" 2>/dev/null || true
    "$SB" close --url-endswith "test-page.html" --first-match 2>/dev/null || true
}
trap cleanup EXIT

echo "=== safari-browser --mark-tab e2e ==="
echo "Fixture: $FIXTURE_URL"
echo ""

# Preflight
if ! pgrep -x Safari > /dev/null; then
    echo "  SKIP: Safari is not running. Start Safari and retry."
    exit 77
fi
if [[ ! -x "$SB" ]]; then
    echo "  SKIP: $SB not installed. Run 'make install' first."
    exit 77
fi

# Setup
"$SB" open "$FIXTURE_URL" > /dev/null 2>&1
sleep 1

# Capture the original title before any marker work.
ORIG_TITLE=$("$SB" get title --url "test-page.html" 2>/dev/null)
if [[ -z "$ORIG_TITLE" ]]; then
    echo "  SKIP: cannot read fixture title (Safari permission issue?)"
    exit 77
fi

# 1. Bare --mark-tab wraps then restores byte-identical title.
"$SB" click "body" --url "test-page.html" --mark-tab > /dev/null 2>&1 || true
RESTORED_TITLE=$("$SB" get title --url "test-page.html" 2>/dev/null)
if [[ "$RESTORED_TITLE" == "$ORIG_TITLE" ]]; then
    pass "bare --mark-tab restores byte-identical title"
else
    fail "bare --mark-tab restored title differs" \
         "expected: '$ORIG_TITLE'  got: '$RESTORED_TITLE'"
fi

# 2. tab is-marked returns 1 (unmarked) after ephemeral cleanup.
"$SB" tab is-marked --url "test-page.html" > /dev/null 2>&1
unmarked_exit=$?
if [[ "$unmarked_exit" == "1" ]]; then
    pass "tab is-marked returns 1 after ephemeral cleanup"
else
    fail "tab is-marked exit unexpected" "got $unmarked_exit (expected 1)"
fi

# 3. --mark-tab-persist survives the invocation boundary.
"$SB" click "body" --url "test-page.html" --mark-tab-persist > /dev/null 2>&1 || true
"$SB" tab is-marked --url "test-page.html" > /dev/null 2>&1
marked_exit=$?
if [[ "$marked_exit" == "0" ]]; then
    pass "--mark-tab-persist leaves marker (is-marked=0)"
else
    fail "--mark-tab-persist marker not detected" "got $marked_exit"
fi

# 4. tab unmark clears the persisted marker.
"$SB" tab unmark --url "test-page.html" > /dev/null 2>&1
"$SB" tab is-marked --url "test-page.html" > /dev/null 2>&1
post_unmark_exit=$?
if [[ "$post_unmark_exit" == "1" ]]; then
    pass "tab unmark clears persisted marker (is-marked=1)"
else
    fail "tab unmark did not clear marker" "got $post_unmark_exit"
fi

# 5. --mark-tab works inside daemon-routed `exec` (Section 7 envelope).
NAMESPACE="mt-$$"
if "$SB" daemon start --name "$NAMESPACE" > /dev/null 2>&1; then
    SCRIPT_FILE=$(mktemp -t exec-mt.XXXXXX.json)
    cat > "$SCRIPT_FILE" <<EOF
[{"cmd":"get url"},{"cmd":"get title"}]
EOF
    SAFARI_BROWSER_DAEMON=1 SAFARI_BROWSER_NAME="$NAMESPACE" \
        "$SB" exec --script "$SCRIPT_FILE" --url "test-page.html" --mark-tab > /dev/null 2>&1
    RESTORED_AFTER_EXEC=$("$SB" get title --url "test-page.html" 2>/dev/null)
    if [[ "$RESTORED_AFTER_EXEC" == "$ORIG_TITLE" ]]; then
        pass "daemon-routed exec --mark-tab restores title"
    else
        fail "daemon-routed exec --mark-tab restore failed" \
             "expected: '$ORIG_TITLE'  got: '$RESTORED_AFTER_EXEC'"
    fi
    "$SB" daemon stop --name "$NAMESPACE" > /dev/null 2>&1 || true
    rm -f "$SCRIPT_FILE"
else
    echo "  SKIP: daemon start failed for $NAMESPACE (test 5)"
fi

echo ""
echo "=== Results: $passed passed, $failed failed ==="
[[ "$failed" -eq 0 ]] && exit 0 || exit 1
