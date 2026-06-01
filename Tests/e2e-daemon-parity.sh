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
# The ambiguousWindowMatch simulation (spec §10.2) requires two tabs whose
# URLs share a substring. We open two DISTINCT run-nonced fixture URLs
# (?<nonce>=A and ?<nonce>=B) — distinct so the human-emulation `open` can't
# focus-existing-collapse them into one tab (the bug that made this case flaky:
# re-opening the SAME url was a focus no-op, leaving a single tab and no
# ambiguity), sharing the nonce so `--url <nonce>` matches exactly both.
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

# Binary under test: override with SAFARI_BROWSER_BIN=.build/debug/safari-browser
# to exercise current source (the default ~/bin build can be weeks-stale).
SB="${SAFARI_BROWSER_BIN:-$HOME/bin/safari-browser}"
NAME="parity-$$"
FIXTURE="file://$(cd "$(dirname "$0")" && pwd)/Fixtures/test-page.html"

# Run-unique marker: makes the two duplicate tabs genuinely distinct URLs (so
# the human-emulation `open` can't focus-existing-collapse them) while sharing a
# substring that matches EXACTLY this run's tabs — immune to leftover fixture
# tabs from other runs perturbing the match count.
MARK="dpar$$"
URL_A="${FIXTURE}?${MARK}=A"
URL_B="${FIXTURE}?${MARK}=B"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "      $2"; }

cleanup() {
    SAFARI_BROWSER_NAME="$NAME" "$SB" daemon stop 2>/dev/null || true
    # Close exactly this run's tabs, matched by the run nonce. (The old
    # --url-endswith "test-page.html" never matched the ?<nonce>=A query suffix,
    # so it leaked a fixture tab every run — the accumulation that eventually
    # made even a clean run start out ambiguous.) Loop: each close removes one.
    local n=0
    while "$SB" close --url "$MARK" --first-match >/dev/null 2>&1; do
        n=$((n + 1)); [ "$n" -gt 20 ] && break
    done
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

# Setup: open tab A in its own window — single tab is enough for cases 1-4.
# Case 5 adds tab B (a distinct nonced URL) in the same window so that
# `--url <nonce>` then matches two tabs.
"$SB" open "$URL_A" --new-window > /dev/null 2>&1
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
#
# Retry-on-mismatch: the daemon/stateless contract is about *same-state*
# equivalence, but a live Safari can change between the two captures (a title
# repaint, a tab finishing load, a sibling run's cleanup tab-closes still
# settling) — a false negative. A REAL parity bug diverges on every attempt
# (deterministic); a race resolves once the state holds still for one pair. So
# we retry and pass on first agreement, only reporting the last divergence.
compare_parity() {
    local name="$1"; shift
    local stateless_out stateless_exit daemon_out daemon_exit attempt

    for attempt in 1 2 3 4 5; do
        # Stateless — never touch the env; daemon would auto-route if the socket
        # existed under $NAME, so we switch to a throwaway namespace to
        # guarantee the socket doesn't exist.
        stateless_out=$(SAFARI_BROWSER_NAME="no-such-$$" "$SB" "$@" 2>/dev/null)
        stateless_exit=$?

        # Daemon mode opts in via the SAFARI_BROWSER_DAEMON=1 env var (the
        # supported signal — `--daemon` was never declared as an
        # ArgumentParser flag and would error at parse time).
        daemon_out=$(SAFARI_BROWSER_DAEMON=1 SAFARI_BROWSER_NAME="$NAME" "$SB" "$@" 2>/dev/null)
        daemon_exit=$?

        if [[ "$stateless_exit" == "$daemon_exit" && "$stateless_out" == "$daemon_out" ]]; then
            pass "$name  (exit=$stateless_exit, ${#stateless_out} bytes)"
            return 0
        fi
        sleep 0.4  # let live state settle, then re-capture both modes
    done

    # Divergence persisted across retries → a genuine daemon/stateless bug.
    if [[ "$stateless_exit" != "$daemon_exit" ]]; then
        fail "$name" "exit code diverges (persisted): stateless=$stateless_exit daemon=$daemon_exit"
    else
        fail "$name" "stdout diverges (persisted)"
        diff <(echo "$stateless_out") <(echo "$daemon_out") | head -20 | sed 's/^/      /'
    fi
    return 1
}

# 1. documents
compare_parity "documents" documents

# 2. get url (default target)
compare_parity "get url (default)" get url

# 3. get title (default target)
compare_parity "get title (default)" get title

# 4. --url hit — the run nonce matches exactly tab A right now (tab B isn't
# open yet), so it's an unambiguous single-tab hit regardless of any leftover
# test-page tabs from other runs.
compare_parity "get url --url <nonce> (unique)" get url --url "$MARK"

# 5. Ambiguous --url — add tab B (a distinct nonced URL → a genuine second tab,
# never a focus-existing no-op) so `--url <nonce>` now matches BOTH tabs. Both
# modes must exit non-zero with ambiguousWindowMatch.
"$SB" open --new-tab "$URL_B" > /dev/null 2>&1

# Wait until BOTH nonced tabs are actually registered before probing. Under
# load the new tab can take a moment to appear; probing too early would see
# one tab and (correctly) NOT report ambiguity — a false negative. Poll the
# precondition deterministically instead of a fixed sleep.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ "$("$SB" documents 2>/dev/null | grep -c "$MARK")" -ge 2 ]] && break
    sleep 0.5
done

# Retry the probe (same rationale as compare_parity): both modes must agree on
# a non-zero exit with a multi-match stderr. A real divergence persists; a
# transient (tab still settling) resolves on retry.
amb_ok=""
for attempt in 1 2 3 4 5; do
    ambiguous_stateless_err=$(SAFARI_BROWSER_NAME="no-such-$$" "$SB" get url --url "$MARK" 2>&1 >/dev/null)
    ambiguous_stateless_exit=$?
    ambiguous_daemon_err=$(SAFARI_BROWSER_DAEMON=1 SAFARI_BROWSER_NAME="$NAME" "$SB" get url --url "$MARK" 2>&1 >/dev/null)
    ambiguous_daemon_exit=$?
    if [[ "$ambiguous_stateless_exit" != "0" && "$ambiguous_daemon_exit" != "0" \
          && "$ambiguous_stateless_exit" == "$ambiguous_daemon_exit" ]] \
       && echo "$ambiguous_stateless_err" | grep -qiE "ambiguous|multiple.*match" \
       && echo "$ambiguous_daemon_err"    | grep -qiE "ambiguous|multiple.*match"; then
        amb_ok=1
        break
    fi
    sleep 0.4
done

if [[ -n "$amb_ok" ]]; then
    pass "ambiguousWindowMatch  (both modes fail-closed with multi-match stderr)"
else
    fail "ambiguousWindowMatch" "stateless_exit=$ambiguous_stateless_exit daemon_exit=$ambiguous_daemon_exit (after retries)"
    echo "      stateless stderr: ${ambiguous_stateless_err:0:200}"
    echo "      daemon stderr: ${ambiguous_daemon_err:0:200}"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
rm -f /tmp/parity-daemon-start
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
