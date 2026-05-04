#!/bin/bash
# E2E tests for --profile filter (Issue #47)
#
# Requires manual setup:
# - Safari running with at least 2 profiles configured
# - Each test profile has at least one window open with a known URL
#
# Why manual: GitHub Actions runners default Safari has no multi-profile
# setup;programmatic profile creation via AppleScript is not exposed by
# Safari 18. parseProfile + pickNativeTarget unit tests cover the pure
# logic;this script verifies window-name → profile extraction lands on
# real Safari.
#
# Usage:
#   1. Open Safari, configure profiles "PROFILE_A" and "PROFILE_B"
#      (Settings → Profiles → +). Or set the env vars below to match
#      your existing profile names.
#   2. Open one window in each profile, navigate to about:blank
#   3. ./Tests/e2e-profile.sh
#
# Auto-skips with exit 77 (skip code per autotools convention) when
# Safari has < 2 profiles or fewer windows than expected.

set -e

SB="$HOME/bin/safari-browser"
PROFILE_A="${SAFARI_E2E_PROFILE_A:-個人}"
PROFILE_B="${SAFARI_E2E_PROFILE_B:-工作}"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1: $2"; }

echo "=== safari-browser --profile E2E (Issue #47) ==="
echo "Looking for profiles: '$PROFILE_A', '$PROFILE_B'"
echo ""

echo "## --profile warning (Issue #54)"

# Test: unhonored command with --profile emits stderr warning.
# Independent of multi-profile setup — works on any Safari.
# `click --profile XXNONE_DUMMY` parses --profile fine, runs warn helper,
# then attempts the click which fails because the selector doesn't exist.
# We only care about the warning line.
WARN_OUT=$("$SB" click --profile XXNONE_DUMMY "#nonexistent_for_warn_test" 2>&1 >/dev/null | head -1 || true)
if [[ "$WARN_OUT" == *"warning: --profile"* ]]; then
  pass "unhonored command (click) emits stderr warning when --profile passed"
else
  fail "unhonored command should emit '--profile' warning to stderr" "got: $WARN_OUT"
fi

# Test: honored command does NOT emit the unhonored-warning line.
# Regression guard against accidentally adding warn calls to commands
# that already plumb profile through to SafariBridge (#47).
DOCS_WARN=$("$SB" documents --profile XXNONE_DUMMY 2>&1 >/dev/null | head -1 || true)
if [[ "$DOCS_WARN" != *"warning: --profile"* ]]; then
  pass "honored command (documents) emits NO stderr warning"
else
  fail "honored command must not emit '--profile' warning" "got: $DOCS_WARN"
fi

echo ""

# Quick discovery — list current state and verify multi-profile
DOCS_OUT=$("$SB" documents 2>&1 || true)
echo "$DOCS_OUT" | head -10
echo "..."

# Detect whether ANY tab carries a profile (auto-detect column)
if ! echo "$DOCS_OUT" | grep -qE '\[[^ ]+\]'; then
  # First [N] is the index column. Check for a SECOND bracket pair
  # which would be the [profile] column.
  if ! echo "$DOCS_OUT" | grep -qE '\] [* ] w[0-9]+\.t[0-9]+ +\['; then
    echo "SKIP: documents output has no [profile] column —"
    echo "      either single-profile setup, or all windows are default profile."
    exit 77
  fi
fi

if ! echo "$DOCS_OUT" | grep -qF "[$PROFILE_A]"; then
  echo "SKIP: profile '$PROFILE_A' not found in any window. Set SAFARI_E2E_PROFILE_A or open a window in that profile."
  exit 77
fi
if ! echo "$DOCS_OUT" | grep -qF "[$PROFILE_B]"; then
  echo "SKIP: profile '$PROFILE_B' not found in any window. Set SAFARI_E2E_PROFILE_B or open a window in that profile."
  exit 77
fi

echo "## documents --profile filter"

# Test 1: documents --profile A returns only A's tabs
A_OUT=$("$SB" documents --profile "$PROFILE_A" 2>&1)
if echo "$A_OUT" | grep -qF "[$PROFILE_A]" && ! echo "$A_OUT" | grep -qF "[$PROFILE_B]"; then
  pass "documents --profile $PROFILE_A returns only $PROFILE_A's tabs"
else
  fail "documents --profile $PROFILE_A leaked $PROFILE_B tabs" "$(echo "$A_OUT" | head -3)"
fi

# Test 2: documents --profile B returns only B's tabs
B_OUT=$("$SB" documents --profile "$PROFILE_B" 2>&1)
if echo "$B_OUT" | grep -qF "[$PROFILE_B]" && ! echo "$B_OUT" | grep -qF "[$PROFILE_A]"; then
  pass "documents --profile $PROFILE_B returns only $PROFILE_B's tabs"
else
  fail "documents --profile $PROFILE_B leaked $PROFILE_A tabs" "$(echo "$B_OUT" | head -3)"
fi

# Test 3: documents --profile Nonexistent returns no rows (filter dropped everything)
NONE_OUT=$("$SB" documents --profile "ProfileThatDoesNotExist__$$" 2>&1)
if [ -z "$NONE_OUT" ] || [ "$(echo "$NONE_OUT" | wc -l | tr -d ' ')" = "0" ]; then
  pass "documents --profile <unknown> returns empty"
else
  fail "documents --profile <unknown> should be empty" "$NONE_OUT"
fi

echo ""
echo "## --profile + --url disambiguation"

# Discover a URL substring that exists in BOTH profiles (common case
# where --profile actually adds value over --url alone). User must
# arrange this — typically by opening the same site in both profiles
# (e.g. mail.google.com).
A_URLS=$(echo "$A_OUT" | grep -oE 'https?://[^ ]+' | head -10)
B_URLS=$(echo "$B_OUT" | grep -oE 'https?://[^ ]+' | head -10)
SHARED_URL=""
while read -r url; do
  if echo "$B_URLS" | grep -qF "$url"; then
    SHARED_URL="$url"
    break
  fi
done <<< "$A_URLS"

if [ -z "$SHARED_URL" ]; then
  echo "SKIP: no URL is open in both $PROFILE_A and $PROFILE_B → --profile + --url disambiguation untested"
else
  # Strip protocol + take first path segment to get a substring
  SUBSTR=$(echo "$SHARED_URL" | sed -E 's|https?://([^/]+).*|\1|' | head -c 30)

  # Test 4: --profile A --url disambiguates to A's tab
  TITLE_A=$("$SB" get title --profile "$PROFILE_A" --url "$SUBSTR" 2>&1 || echo "ERR")
  TITLE_B=$("$SB" get title --profile "$PROFILE_B" --url "$SUBSTR" 2>&1 || echo "ERR")
  if [ "$TITLE_A" != "ERR" ] && [ "$TITLE_B" != "ERR" ] && [ "$TITLE_A" != "$TITLE_B" ]; then
    pass "--profile + --url $SUBSTR resolves to different tabs in different profiles"
  else
    fail "--profile + --url disambiguation" "TITLE_A=$TITLE_A TITLE_B=$TITLE_B"
  fi
fi

echo ""
echo "## Summary"
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" = "0" ] && exit 0 || exit 1
