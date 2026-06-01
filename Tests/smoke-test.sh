#!/bin/bash
# Smoke tests — exercise the REAL binary's CLI contract WITHOUT live Safari.
#
# Why this tier exists: ArgumentParser validates flags (and our custom main()
# appends the #69 glued-flag hint) BEFORE any AppleScript runs, so --help,
# argument parsing, and validation-error messages are fully testable with zero
# Safari interaction — fast, deterministic, and CI-safe. This is the middle of
# the pyramid between pure unit tests (`swift test`) and live-Safari e2e
# (`Tests/e2e-*.sh`).
#
# Usage:
#   make test-smoke          # builds, then runs
#   ./Tests/smoke-test.sh    # uses .build/debug/safari-browser (or $SAFARI_BROWSER_BIN)
#
# Exit 0 = all green, 1 = at least one failure.
set -u

SB="${SAFARI_BROWSER_BIN:-.build/debug/safari-browser}"
if [[ ! -x "$SB" ]]; then
    echo "✗ binary not found / not executable: $SB" >&2
    echo "  run 'swift build' first, or set SAFARI_BROWSER_BIN" >&2
    exit 1
fi

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "      $2"; }

# assert_contains "<label>" "<actual>" "<needle>"
assert_contains() {
    if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "expected to contain «$3», got: $(echo "$2" | head -3 | tr '\n' '⏎')"; fi
}
# assert_not_contains "<label>" "<actual>" "<needle>"
assert_not_contains() {
    if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1" "should NOT contain «$3»"; fi
}
# assert_exit "<label>" "<expected-code>" -- <cmd...>
assert_exit() {
    local label="$1" want="$2"; shift 3
    "$@" >/dev/null 2>&1; local got=$?
    if [[ "$got" == "$want" ]]; then pass "$label (exit $got)"; else fail "$label" "expected exit $want, got $got"; fi
}

echo "=== safari-browser SMOKE tests (CLI contract, no Safari) ==="
echo "Binary: $SB"
echo ""

# ─────────────────────────────────────────────────────────────────────
echo "## Help / discovery"
ROOT_HELP=$("$SB" --help 2>&1 || true)
assert_contains "root --help lists abstract" "$ROOT_HELP" "macOS native browser automation"
assert_contains "root --help lists 'snapshot'" "$ROOT_HELP" "snapshot"
assert_contains "root --help lists 'documents'" "$ROOT_HELP" "documents"
assert_contains "root --help lists 'tab'" "$ROOT_HELP" "tab"

# Per-command help reaches every top-level subcommand without Safari.
for cmd in open snapshot js get click fill type select hover scroll press \
           focus check dblclick upload find highlight screenshot save-image \
           pdf drag set is cookies storage mouse console errors tabs tab \
           documents wait back forward reload close daemon exec; do
    H=$("$SB" "$cmd" --help 2>&1)
    if [[ "$H" == *"USAGE"* || "$H" == *"OVERVIEW"* || "$H" == *"SUBCOMMANDS"* ]]; then
        pass "$cmd --help"
    else
        fail "$cmd --help" "no USAGE/OVERVIEW/SUBCOMMANDS block: $(echo "$H" | head -1)"
    fi
done

# #45: the new `tab focus` subcommand is registered + discoverable.
TAB_HELP=$("$SB" tab --help 2>&1)
assert_contains "tab --help lists 'focus' (#45)" "$TAB_HELP" "focus"
TF_HELP=$("$SB" tab focus --help 2>&1)
assert_contains "tab focus --help (#45)" "$TF_HELP" "preserves tab state"
echo ""

# ─────────────────────────────────────────────────────────────────────
echo "## --profile validation (#65/#63/#61/#55) — fails at parse, no Safari"
# Empty profile (#61)
OUT=$("$SB" click "#x" --profile "" 2>&1 || true)
assert_contains "--profile '' rejected" "$OUT" "non-empty"
# Oversized (#65)
LONG=$(printf 'a%.0s' {1..257})
OUT=$("$SB" click "#x" --profile "$LONG" 2>&1 || true)
assert_contains "--profile >256 chars rejected" "$OUT" "too long"
# Control char (#63)
OUT=$("$SB" click "#x" --profile $'work\x1b[2J' 2>&1 || true)
assert_contains "--profile control char rejected" "$OUT" "control characters"
# Em-dash separator (#55) — Safari's profile/title delimiter
OUT=$("$SB" click "#x" --profile "R&D $(printf '\xe2\x80\x94') Lab" 2>&1 || true)
assert_contains "--profile with ' — ' separator rejected (#55)" "$OUT" "separator"
# Valid profile must NOT trip validation (will fail later on Safari, but not at validate)
OUT=$("$SB" click "#x" --profile "個人" 2>&1 || true)
assert_not_contains "valid --profile passes validation" "$OUT" "control characters"
echo ""

# ─────────────────────────────────────────────────────────────────────
echo "## Targeting-flag exclusivity + index guards (parse-time)"
OUT=$("$SB" snapshot --url plaud --window 1 2>&1 || true)
assert_contains "--url + --window mutually exclusive" "$OUT" "mutually exclusive"
OUT=$("$SB" snapshot --tab-in-window 2 2>&1 || true)
assert_contains "--tab-in-window requires --window" "$OUT" "--window"
OUT=$("$SB" snapshot --window 0 2>&1 || true)
assert_contains "--window 0 rejected (1-indexed)" "$OUT" ">= 1"
OUT=$("$SB" snapshot --url-endswith "" 2>&1 || true)
assert_contains "empty --url-endswith rejected" "$OUT" "non-empty"
OUT=$("$SB" snapshot --url-regex "[" 2>&1 || true)
assert_contains "invalid --url-regex rejected at validate" "$OUT" "--url-regex"
echo ""

# ─────────────────────────────────────────────────────────────────────
echo "## #69 glued flag+value hint (zsh \$LOCK footgun)"
OUT=$("$SB" snapshot "--url report" 2>&1 || true)
assert_contains "glued '--url report' shows hint" "$OUT" "Hint:"
assert_contains "hint shows the inlined two-word form" "$OUT" "--url report"
assert_contains "hint mentions zsh array workaround" "$OUT" "zsh"
# A genuinely unknown flag must NOT get the misleading 'inline them' hint
OUT=$("$SB" snapshot --frobnicate 2>&1 || true)
assert_not_contains "genuine unknown flag gets NO glued hint" "$OUT" "Hint:"
assert_contains "genuine unknown flag still errors" "$OUT" "Unknown option"
# Glued --profile (in targetFlagNames after #60) also hinted
OUT=$("$SB" click "#x" "--profile work" 2>&1 || true)
assert_contains "glued '--profile work' hinted (#60 targetFlagNames)" "$OUT" "Hint:"
echo ""

# ─────────────────────────────────────────────────────────────────────
echo "## Subcommand / argument errors (clean, no Safari)"
assert_exit "unknown subcommand errors non-zero" 64 -- "$SB" definitely-not-a-command
assert_exit "missing required arg errors non-zero" 64 -- "$SB" click
# `tab` only accepts --window for targeting (validate)
OUT=$("$SB" tab 3 --url plaud 2>&1 || true)
assert_contains "tab <N> --url rejected (only --window)" "$OUT" "--window"
# `tabs` likewise
OUT=$("$SB" tabs --url plaud 2>&1 || true)
assert_contains "tabs --url rejected (only --window)" "$OUT" "--window"
echo ""

# ─────────────────────────────────────────────────────────────────────
echo "## Flag-only guards that don't need Safari"
# --mark-tab + --mark-tab-persist mutually exclusive (validate)
OUT=$("$SB" click "#x" --mark-tab --mark-tab-persist 2>&1 || true)
assert_contains "--mark-tab + --mark-tab-persist mutually exclusive" "$OUT" "mutually exclusive"
# pdf without --allow-hid refuses before any keystroke
OUT=$("$SB" pdf /tmp/smoke.pdf 2>&1 || true)
assert_contains "pdf without --allow-hid refuses" "$OUT" "--allow-hid"
echo ""

# ─────────────────────────────────────────────────────────────────────
echo "───────────────────────────────────────────────"
echo "SMOKE: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
