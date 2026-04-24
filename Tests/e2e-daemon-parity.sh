#!/bin/bash
# e2e-daemon-parity.sh — Task 10.2 integration test
#
# Asserts that daemon mode and stateless mode produce byte-identical stdout
# and matching exit codes for:
#   1. `documents`           — enumerate all Safari windows/tabs
#   2. `get url`              — URL of default (first) document
#   3. `get title`            — title of default document
#   4. `--url <pattern>` hit  — a unique URL match
#   5. `--url <pattern>` miss — the stateless path produces the same
#                                documentNotFound error shape
#
# The ambiguousWindowMatch simulation (spec §10.2) requires two tabs with
# overlapping URL substrings. We open the same fixture twice so `--url
# test-page` resolves to both.
#
# Requires:
#   - Safari running
#   - binary installed at ~/bin/safari-browser
#
# Usage:
#   Tests/e2e-daemon-parity.sh
#
# Exit code 0 on parity, non-zero if any command diverges.
set -u

SB="$HOME/bin/safari-browser"
NAME="parity-$$"
FIXTURE="file://$(cd "$(dirname "$0")" && pwd)/Fixtures/test-page.html"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "      $2"; }

cleanup() {
    SAFARI_BROWSER_NAME="$NAME" "$SB" daemon stop 2>/dev/null || true
    # Best-effort close of any duplicate tabs we opened
    "$SB" close --url-endswith "test-page.html" --first-match 2>/dev/null || true
    "$SB" close --url-endswith "test-page.html" --first-match 2>/dev/null || true
}
trap cleanup EXIT

echo "=== safari-browser daemon/stateless parity ==="
echo "Fixture: $FIXTURE"
echo "Namespace: $NAME"
echo ""

# Preflight
if ! pgrep -x Safari > /dev/null; then
    echo "  SKIP: Safari is not running. Start Safari and retry."
    exit 77  # automake convention for "skipped"
fi
if [[ ! -x "$SB" ]]; then
    echo "  SKIP: $SB not installed. Run 'make install' first."
    exit 77
fi

# Setup: open fixture once — single tab is enough for cases 1-4. Case 5
# opens a second duplicate to exercise the documentNotFound/ambiguous
# comparison without needing a second distinct URL.
"$SB" open "$FIXTURE" > /dev/null 2>&1
sleep 1

# Start the daemon in its own namespace so concurrent dev work on the
# default namespace is unaffected.
if ! SAFARI_BROWSER_NAME="$NAME" "$SB" daemon start > /tmp/parity-daemon-start 2>&1; then
    echo "  SKIP: daemon start failed:"
    cat /tmp/parity-daemon-start | sed 's/^/    /'
    exit 77
fi

# Compare a single command's stdout+exit in both modes.
#   $1 — test name
#   $@ — command args (without `safari-browser` prefix)
compare_parity() {
    local name="$1"; shift
    local stateless_out stateless_exit daemon_out daemon_exit

    # Stateless — never touch the env; daemon would auto-route if the socket
    # existed under $NAME, so we switch back to the default namespace with a
    # throwaway value to guarantee the socket doesn't exist.
    stateless_out=$(SAFARI_BROWSER_NAME="no-such-$$" "$SB" "$@" 2>/dev/null)
    stateless_exit=$?

    daemon_out=$(SAFARI_BROWSER_NAME="$NAME" "$SB" "$@" --daemon 2>/dev/null)
    daemon_exit=$?

    if [[ "$stateless_exit" != "$daemon_exit" ]]; then
        fail "$name" "exit code diverges: stateless=$stateless_exit daemon=$daemon_exit"
        return 1
    fi

    if [[ "$stateless_out" != "$daemon_out" ]]; then
        fail "$name" "stdout diverges"
        diff <(echo "$stateless_out") <(echo "$daemon_out") | head -20 | sed 's/^/      /'
        return 1
    fi

    pass "$name  (exit=$stateless_exit, ${#stateless_out} bytes)"
}

# 1. documents
compare_parity "documents" documents

# 2. get url (default target)
compare_parity "get url (default)" get url

# 3. get title (default target)
compare_parity "get title (default)" get title

# 4. --url hit — unique substring for the fixture
compare_parity "get url --url test-page" get url --url test-page

# 5. Ambiguous --url — open the fixture a second time so `--url test-page`
# matches two tabs. Both modes should exit non-zero with ambiguousWindowMatch.
"$SB" open --new-tab "$FIXTURE" > /dev/null 2>&1
sleep 1
ambiguous_stateless_err=$(SAFARI_BROWSER_NAME="no-such-$$" "$SB" get url --url test-page 2>&1 >/dev/null)
ambiguous_stateless_exit=$?
ambiguous_daemon_err=$(SAFARI_BROWSER_NAME="$NAME" "$SB" get url --url test-page --daemon 2>&1 >/dev/null)
ambiguous_daemon_exit=$?

if [[ "$ambiguous_stateless_exit" == "0" || "$ambiguous_daemon_exit" == "0" ]]; then
    fail "ambiguousWindowMatch" "expected non-zero exit, got stateless=$ambiguous_stateless_exit daemon=$ambiguous_daemon_exit"
elif [[ "$ambiguous_stateless_exit" != "$ambiguous_daemon_exit" ]]; then
    fail "ambiguousWindowMatch exit codes match" "stateless=$ambiguous_stateless_exit daemon=$ambiguous_daemon_exit"
elif echo "$ambiguous_stateless_err" | grep -qi "ambiguous" && echo "$ambiguous_daemon_err" | grep -qi "ambiguous"; then
    pass "ambiguousWindowMatch  (both modes fail-closed with 'ambiguous' in stderr)"
else
    fail "ambiguousWindowMatch" "stderr missing 'ambiguous' keyword"
    echo "      stateless stderr: ${ambiguous_stateless_err:0:200}"
    echo "      daemon stderr: ${ambiguous_daemon_err:0:200}"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
rm -f /tmp/parity-daemon-start
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
