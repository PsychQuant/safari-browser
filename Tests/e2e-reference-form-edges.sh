#!/usr/bin/env bash
# e2e: document-reference behavior under two conditions that cannot be created
# on demand — a 0-tab front window (#96) and a modal sheet (#83).
#
# MEASURED 2026-08-05 (Safari 26), by opening a throwaway window and producing
# each dialog shape in it: under BOTH a JavaScript alert and a native file
# picker, every reference form stayed readable — `document 1`,
# `document of front window`, `count of tabs of front window`, `id of window N`,
# `tab T of window N`, and even the `current tab of front window` that #21
# originally found blocked. Only `do JavaScript` blocked. #97 relies on that
# result; re-run this harness if Safari's behavior changes.
#
# Both questions are about which document a reference actually resolves to when
# the front window is in an unusual state. Neither state is scriptable: making a
# 0-tab window frontmost means reordering the user's windows, and opening a
# modal sheet means driving a native file dialog — which, if it hangs, blocks
# every subsequent Safari command. So this harness *detects* the condition and
# tests only when it is already present, exiting 77 (skip) otherwise. Run it
# opportunistically; it is not expected to execute on most invocations.
#
# Usage: SAFARI_BROWSER_BIN=/path/to/safari-browser ./Tests/e2e-reference-form-edges.sh
set -uo pipefail

BIN="${SAFARI_BROWSER_BIN:-.build/release/safari-browser}"
[ -x "$BIN" ] || { echo "skip: binary not found at $BIN"; exit 77; }
command -v osascript >/dev/null || { echo "skip: osascript unavailable"; exit 77; }

fail=0
note() { printf '  %s\n' "$*"; }
check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n     expected: %s\n     actual:   %s\n' "$label" "$expected" "$actual"
    fail=1
  fi
}

# ---------------------------------------------------------------------------
# #96 — does `document 1` follow the front window, or the first window that
# happens to have tabs?
#
# Safari's `documents` collection omits tab-less windows. `.frontWindow`
# renders as `document 1`, so if the frontmost window has no tabs, `document 1`
# is some *other* window's document and `js` runs against a page the caller
# never targeted — silently, since nothing errors.
# ---------------------------------------------------------------------------
echo "== #96: document 1 vs a tab-less front window =="

read -r WIN_COUNT DOC_COUNT FRONT_TABS <<<"$(osascript -e '
tell application "Safari"
  set w to count of windows
  if w = 0 then return "0 0 0"
  return (w as string) & " " & ((count of documents) as string) & " " & ((count of tabs of front window) as string)
end tell' 2>/dev/null)"

if [ "${WIN_COUNT:-0}" -eq 0 ]; then
  echo "skip: Safari has no windows"
else
  note "windows=$WIN_COUNT documents=$DOC_COUNT front-window-tabs=$FRONT_TABS"

  # This part always runs: it pins the premise the hazard rests on.
  if [ "$WIN_COUNT" -gt "$DOC_COUNT" ]; then
    note "premise holds: the documents collection omits $((WIN_COUNT - DOC_COUNT)) tab-less window(s)"
  else
    note "no tab-less window present — premise not exercised this run"
  fi

  if [ "$FRONT_TABS" -eq 0 ]; then
    # The condition we cannot manufacture is actually present. Compare what
    # `document 1` resolves to against the window the user would call frontmost.
    DOC1=$(osascript -e 'tell application "Safari" to return name of document 1' 2>/dev/null)
    FRONTNAME=$(osascript -e 'tell application "Safari" to return name of front window' 2>/dev/null)
    note "document 1  -> $DOC1"
    note "front window-> $FRONTNAME"
    # A tab-less front window has no document of its own, so any non-empty
    # `document 1` here belongs to a different window. The tool must refuse
    # rather than operate on it.
    JS_OUT=$("$BIN" js "return location.href" 2>&1)
    JS_RC=$?
    if [ $JS_RC -eq 0 ]; then
      check "js against a tab-less front window must not silently succeed" "non-zero exit" "exit 0 with: $JS_OUT"
    else
      printf 'ok   js refused a tab-less front window (%s)\n' "$(printf '%s' "$JS_OUT" | head -1)"
    fi
  else
    note "skip: front window has $FRONT_TABS tab(s) — the 0-tab-front condition is not present"
  fi
fi

# ---------------------------------------------------------------------------
# #83 — does the identity-anchored reference introduced by #79 still bypass a
# modal sheet the way `document N` did (#21)?
#
# #21 chose `document 1` over `current tab of front window` precisely so that
# read-only queries keep working while a sheet blocks the front window. #79
# then changed what a `--url` match resolves to: `tab T of window id W`. That
# is a different reference form, and whether it inherits the bypass has never
# been measured.
# ---------------------------------------------------------------------------
echo "== #83: modal sheet vs the tab-scoped reference form =="

SHEET_PRESENT=$(osascript -e '
tell application "System Events"
  if not (exists process "Safari") then return "unknown"
  tell process "Safari"
    repeat with w in windows
      if (count of sheets of w) > 0 then return "yes"
    end repeat
  end tell
  return "no"
end tell' 2>/dev/null)

case "${SHEET_PRESENT:-unknown}" in
  unknown)
    note "skip: cannot query System Events (Accessibility not granted?)"
    ;;
  no)
    note "skip: no modal sheet is open — this harness will not open one"
    note "      (a stuck file dialog blocks every later Safari command; see #67)"
    ;;
  yes)
    note "a modal sheet is present — measuring both reference forms"
    FIRST_URL=$(osascript -e 'tell application "Safari" to return URL of document 1' 2>/dev/null)
    if [ -z "$FIRST_URL" ]; then
      note "document 1 unreadable — #21's premise does not hold in this state"
    fi
    # Document-scoped read (#21 form).
    DOC_OUT=$("$BIN" get url 2>&1); DOC_RC=$?
    # Identity-anchored read (#79 form) against the same page.
    if [ -n "$FIRST_URL" ]; then
      TAB_OUT=$("$BIN" get url --url "$FIRST_URL" 2>&1); TAB_RC=$?
    else
      TAB_RC=1; TAB_OUT="(no URL to target)"
    fi
    note "document-scoped: rc=$DOC_RC $(printf '%s' "$DOC_OUT" | head -1)"
    note "identity-anchored: rc=$TAB_RC $(printf '%s' "$TAB_OUT" | head -1)"
    check "identity-anchored reference must bypass the sheet like the document-scoped one" \
      "$DOC_RC" "$TAB_RC"
    ;;
esac

if [ "$fail" -ne 0 ]; then
  echo "e2e-reference-form-edges: FAILURES"
  exit 1
fi
echo "e2e-reference-form-edges: no failures (conditions not present count as skipped, not passed)"
exit 0
