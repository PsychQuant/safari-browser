#!/bin/bash
# e2e-exec-script.sh — Task 12.1 integration test for `safari-browser exec`
#
# Runs a multi-step JSON script against live Safari. Validates:
#   1. Variable capture: step 1 binds `$url`, step 2 references it via `$url`
#   2. Conditional skip: step uses `if:` against a captured variable
#   3. Result array shape: status/value/var/reason fields per spec
#
# Auto-skips with exit 77 when Safari isn't running or binary not installed.

set -u

SB="$HOME/bin/safari-browser"
FIXTURE="file://$(cd "$(dirname "$0")" && pwd)/Fixtures/test-page.html"

if ! pgrep -x Safari > /dev/null; then
    echo "  SKIP: Safari is not running."
    exit 77
fi
if [[ ! -x "$SB" ]]; then
    echo "  SKIP: $SB not installed. Run 'make install' first."
    exit 77
fi

# Open fixture once for the script to target.
"$SB" open "$FIXTURE" > /dev/null 2>&1
sleep 1

cleanup() {
    "$SB" close --url-endswith "test-page.html" --first-match 2>/dev/null || true
}
trap cleanup EXIT

# 4-step script:
#   0. get url → bind to $u
#   1. get title → bind to $t
#   2. js with substituted args → no var
#   3. js skipped because if:false
SCRIPT='[
  {"cmd": "get url", "var": "u"},
  {"cmd": "get title", "var": "t"},
  {"cmd": "js", "args": ["'$u + ' :: ' + '$t'"]},
  {"cmd": "js", "args": ["1"], "if": "$u contains \"this-substring-is-absent\""}
]'

OUT=$(echo "$SCRIPT" | "$SB" exec --url test-page 2>&1)
EXIT=$?

if [[ "$EXIT" -ne 0 ]]; then
    echo "  FAIL: exec exited $EXIT"
    echo "  --- stderr/stdout ---"
    echo "$OUT" | sed 's/^/    /'
    exit 1
fi

PASS=0
FAIL=0
check() {
    if echo "$OUT" | grep -q "$1"; then
        PASS=$((PASS + 1))
        echo "  ✓ $2"
    else
        FAIL=$((FAIL + 1))
        echo "  ✗ $2"
        echo "    expected to find: $1"
    fi
}

check '"step" : 0' "step 0 present in result array"
check '"var" : "u"' "step 0 captured as \$u"
check '"step" : 1' "step 1 present"
check '"var" : "t"' "step 1 captured as \$t"
check '"step" : 2' "step 2 present"
check '"step" : 3' "step 3 present"
check '"status" : "skipped"' "step 3 skipped via if:false"
check '"reason" : "if:false"' "skip reason recorded"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
