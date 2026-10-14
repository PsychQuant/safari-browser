#!/bin/bash
# Behavior tests for scripts/stamp-version.sh (#278, change add-cli-version).
#
# The stamping step wraps the release build, and a release build takes ~30 s, so
# these tests run the wrapper around cheap commands (cat, false, sleep) inside
# throwaway git repositories instead of building anything.
#
# Usage: bash scripts/stamp-version-test.sh
set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/stamp-version.sh"
FILE="Sources/SafariBrowser/BuildVersion.swift"
PLACEHOLDER='enum BuildVersion { static let value = "unknown" }'

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; }

assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}
assert_match() { # name regex actual
  if printf '%s' "$3" | grep -Eq "$2"; then ok "$1"; else fail "$1" "expected /$2/ got [$3]"; fi
}

# A repo whose tracked placeholder is already committed, tagged v1.2.3 on HEAD.
new_repo() { # dir
  mkdir -p "$1/$(dirname "$FILE")"
  (
    cd "$1" || exit 1
    git init -q . && git config user.email t@example.com && git config user.name t
    printf '%s\n' "$PLACEHOLDER" > "$FILE"
    echo a > other.txt
    git add -A && git commit -q -m one && git tag v1.2.3
  )
}
placeholder_back() { # dir
  [ "$(cat "$1/$FILE")" = "$PLACEHOLDER" ]
}

echo "stamp-version.sh"

if [ ! -x "$SCRIPT" ]; then
  fail "scripts/stamp-version.sh exists and is executable" "$SCRIPT"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

# 1. exactly on a release tag, clean tree -> the tag itself (stamping must not make the tree dirty)
R="$TMPROOT/exact"; new_repo "$R"
OUT="$(cd "$R" && "$SCRIPT" "$FILE" -- cat "$FILE")"
assert_eq "on a tag the stamped value is the tag" 'enum BuildVersion { static let value = "v1.2.3" }' "$OUT"
placeholder_back "$R" && ok "placeholder restored after success" || fail "placeholder restored after success"

# 2. commits after the tag -> describe form
R="$TMPROOT/after"; new_repo "$R"
(cd "$R" && echo b > other.txt && git commit -q -am two)
OUT="$(cd "$R" && "$SCRIPT" "$FILE" -- cat "$FILE")"
assert_match "after a tag the stamped value is tag-count-gsha" '"v1\.2\.3-1-g[0-9a-f]+"' "$OUT"

# 3. an idd-* baseline tag nearer to HEAD must not win
R="$TMPROOT/baseline"; new_repo "$R"
(cd "$R" && echo b > other.txt && git commit -q -am two && git tag idd-217-baseline)
OUT="$(cd "$R" && "$SCRIPT" "$FILE" -- cat "$FILE")"
assert_match "idd-* tags are ignored" '"v1\.2\.3-1-g[0-9a-f]+"' "$OUT"
case "$OUT" in *idd-*) fail "no idd- text in the stamped value" "$OUT" ;; *) ok "no idd- text in the stamped value" ;; esac

# 4. uncommitted change to a tracked file -> -dirty
R="$TMPROOT/dirty"; new_repo "$R"
(cd "$R" && echo changed > other.txt)
OUT="$(cd "$R" && "$SCRIPT" "$FILE" -- cat "$FILE")"
assert_match "a tracked modification adds -dirty" '"v1\.2\.3-dirty"' "$OUT"

# 5. failing command: its exit status is returned and the placeholder is restored
R="$TMPROOT/fail"; new_repo "$R"
(cd "$R" && "$SCRIPT" "$FILE" -- false); CODE=$?
assert_eq "a failing command's exit status is returned" "1" "$CODE"
placeholder_back "$R" && ok "placeholder restored after failure" || fail "placeholder restored after failure"

R="$TMPROOT/code7"; new_repo "$R"
(cd "$R" && "$SCRIPT" "$FILE" -- sh -c 'exit 7'); CODE=$?
assert_eq "exit status 7 is passed through unchanged" "7" "$CODE"

# 6. TERM while the command runs: the placeholder comes back without waiting for the command
R="$TMPROOT/term"; new_repo "$R"
( cd "$R" && "$SCRIPT" "$FILE" -- sleep 30 ) &
PID=$!
N=0; while [ $N -lt 50 ] && placeholder_back "$R"; do sleep 0.1; N=$((N + 1)); done
if placeholder_back "$R"; then
  fail "stamp is visible while the command runs" "file never changed"
else
  ok "stamp is visible while the command runs"
fi
kill -TERM "$PID" 2>/dev/null
N=0; while [ $N -lt 50 ] && kill -0 "$PID" 2>/dev/null; do sleep 0.1; N=$((N + 1)); done
if kill -0 "$PID" 2>/dev/null; then
  kill -KILL "$PID" 2>/dev/null; fail "TERM ends the wrapper within 5 s"
else
  ok "TERM ends the wrapper within 5 s"
fi
wait "$PID" 2>/dev/null
placeholder_back "$R" && ok "placeholder restored after TERM" || fail "placeholder restored after TERM"
pkill -f "sleep 30" 2>/dev/null || true

# 7. no .git directory -> unknown, and the command still runs
R="$TMPROOT/nogit"; mkdir -p "$R/$(dirname "$FILE")"; printf '%s\n' "$PLACEHOLDER" > "$R/$FILE"
OUT="$(cd "$R" && "$SCRIPT" "$FILE" -- cat "$FILE")"; CODE=$?
assert_eq "without .git the stamped value is unknown" "$PLACEHOLDER" "$OUT"
assert_eq "without .git the command still succeeds" "0" "$CODE"

# 8. a version that would break the Swift literal is replaced by unknown
R="$TMPROOT/quote"; new_repo "$R"
(cd "$R" && git tag -d v1.2.3 >/dev/null && git tag 'v1.0"x')
OUT="$(cd "$R" && "$SCRIPT" "$FILE" -- cat "$FILE")"
assert_eq "a double quote in the version is replaced by unknown" "$PLACEHOLDER" "$OUT"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
