#!/bin/bash
# Behavior tests for scripts/release.sh (#280).
#
# A real release takes minutes (a Universal build, then an Apple round-trip) and ends
# in a signed binary, so these tests run the script against PATH shims for `swift`,
# `codesign`, `lipo`, `security`, `xcrun` and `gh`, inside throwaway git repositories.
# git itself is real (the shim logs the call and runs the real one), because the
# guards under test are about what git says: a clean tree, HEAD exactly on a tag.
#
# What the shims cannot tell us is whether Apple accepts the binary or whether the
# Universal build runs on an Intel Mac. Those are measured by hand and recorded in the
# issue; nothing here claims them.
#
# Usage: bash scripts/release-test.sh
#        RELEASE_SCRIPT=/path/to/variant.sh bash scripts/release-test.sh   # mutation checks
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE="${RELEASE_SCRIPT:-$SCRIPT_DIR/release.sh}"
REAL_GIT="$(command -v git)"

PLACEHOLDER='enum BuildVersion { static let value = "unknown" }'
VERSION_FILE="Sources/SafariBrowser/BuildVersion.swift"
ENT_KEY="com.apple.security.automation.apple-events"
FAKE_ID="0123456789ABCDEF0123456789ABCDEF01234567"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; }

assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}
assert_ok() { # name rc
  if [ "$2" -eq 0 ]; then ok "$1"; else fail "$1" "exit code $2"; fi
}
assert_refused() { # name rc  (any non-zero exit; the reason is asserted separately)
  if [ "$2" -ne 0 ]; then ok "$1"; else fail "$1" "expected a non-zero exit, got 0"; fi
}
assert_has() { # name needle file  (fixed string, case-insensitive)
  if grep -Fiq -- "$2" "$3" 2>/dev/null; then ok "$1"; else fail "$1" "[$2] not found in $3: $(head -c 400 "$3" 2>/dev/null)"; fi
}
assert_lacks() { # name needle file
  if grep -Fiq -- "$2" "$3" 2>/dev/null; then fail "$1" "[$2] unexpectedly present in $3"; else ok "$1"; fi
}
assert_exists() { # name path
  if [ -e "$2" ]; then ok "$1"; else fail "$1" "missing: $2"; fi
}
assert_absent() { # name path
  if [ -e "$2" ]; then fail "$1" "unexpectedly present: $2"; else ok "$1"; fi
}
line_of() { # file regex -> first matching line number, or 0
  grep -En -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1 | grep -E '^[0-9]+$' || echo 0
}

# --- the shims ------------------------------------------------------------------
# Every shim appends its argument list to $FAKE_LOG so a test can say what ran, and in
# what order. They are written once; the behavior knobs are environment variables.
make_shims() { # dir
  mkdir -p "$1"

  cat > "$1/git" <<'EOF'
#!/bin/bash
echo "git $*" >> "$FAKE_LOG"
exec "$REAL_GIT" "$@"
EOF

  cat > "$1/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "$FAKE_LOG"
exit 1
EOF

  cat > "$1/security" <<'EOF'
#!/bin/bash
echo "security $*" >> "$FAKE_LOG"
if [ "$1" = find-identity ]; then
  [ -n "${FAKE_IDENTITIES:-}" ] && printf '  1) %s "Developer ID Application: Example Person (ABCDE12345)"\n     1 valid identities found\n' "$FAKE_IDENTITIES" \
    || echo "     0 valid identities found"
  exit 0
fi
exit 64
EOF

  cat > "$1/lipo" <<'EOF'
#!/bin/bash
echo "lipo $*" >> "$FAKE_LOG"
[ "$1" = -archs ] && { echo "${FAKE_LIPO_ARCHS:-x86_64 arm64}"; exit 0; }
exit 64
EOF

  # `swift build ... --show-bin-path` prints a directory and builds nothing. A real
  # build bakes whatever BuildVersion.swift says at that moment into the binary, which
  # is the property the self-report check relies on; the fake binary does the same.
  cat > "$1/swift" <<'EOF'
#!/bin/bash
echo "swift $*" >> "$FAKE_LOG"
for a in "$@"; do
  [ "$a" = "--show-bin-path" ] && { echo "$FAKE_BIN_PATH"; exit 0; }
done
[ "$1" = build ] || exit 64
mkdir -p "$FAKE_BIN_PATH"
V="$(sed -n 's/.*value = "\(.*\)".*/\1/p' Sources/SafariBrowser/BuildVersion.swift)"
[ -n "${FAKE_BAKE_VERSION:-}" ] && V="$FAKE_BAKE_VERSION"
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "%s"; exit 0; fi\nexit 0\n' "$V" > "$FAKE_BIN_PATH/safari-browser"
chmod +x "$FAKE_BIN_PATH/safari-browser"
EOF

  # Signing appends a marker to the file, so "the shipped binary was signed" and "the
  # zip Apple received was of the signed binary" are both checkable from the outside.
  cat > "$1/codesign" <<'EOF'
#!/bin/bash
echo "codesign $*" >> "$FAKE_LOG"
case "$1" in
  --verify|-v)
    [ -n "${FAKE_CODESIGN_VERIFY_FAIL:-}" ] && { echo "fake codesign: verification failed" >&2; exit 1; }
    exit 0 ;;
esac
for last; do :; done
printf '# SIGNED\n' >> "$last"
EOF

  cat > "$1/xcrun" <<'EOF'
#!/bin/bash
echo "xcrun $*" >> "$FAKE_LOG"
[ "$1" = notarytool ] || exit 64
case "$2" in
  history)
    [ -n "${FAKE_NOTARY_PROBE_FAIL:-}" ] && { echo "Error: HTTP status code: 401. Invalid credentials." >&2; exit 1; }
    echo "Successfully received submission history."; exit 0 ;;
  submit)
    zip="$3"
    if [ -f "$zip" ]; then
      echo "zip-present" >> "$FAKE_LOG"
      unzip -p "$zip" safari-browser 2>/dev/null | grep -q '^# SIGNED$' && echo "zip-signed" >> "$FAKE_LOG" || echo "zip-unsigned" >> "$FAKE_LOG"
    else
      echo "zip-missing" >> "$FAKE_LOG"
    fi
    printf '{"id":"11111111-2222-3333-4444-555555555555","message":"Processing complete","status":"%s"}\n' "${FAKE_NOTARY_STATUS:-Accepted}"
    exit 0 ;;
  log)
    echo '{"status":"Invalid","issues":[{"severity":"error","message":"FAKE-LOG-THE-BINARY-IS-NOT-SIGNED"}]}'
    exit 0 ;;
esac
exit 64
EOF

  cat > "$1/fake-verify" <<'EOF'
#!/bin/bash
echo "verify $*" >> "$FAKE_LOG"
[ -n "${FAKE_VERIFY_FAIL:-}" ] && { echo "fake verify: not durable" >&2; exit 1; }
exit 0
EOF

  chmod +x "$1"/*
}

# A repo whose tracked state is exactly what release.sh may build from: a placeholder
# BuildVersion.swift, the entitlements, and a .gitignore that hides dist/. HEAD is on
# the given tag.
new_repo() { # dir [tag]
  local tag="${2:-v1.2.3}"
  mkdir -p "$1/Sources/SafariBrowser"
  (
    cd "$1" || exit 1
    "$REAL_GIT" init -q . && "$REAL_GIT" config user.email t@example.com && "$REAL_GIT" config user.name t
    printf '%s\n' "$PLACEHOLDER" > "$VERSION_FILE"
    cp "$REPO_ROOT/Sources/SafariBrowser/Entitlements.plist" Sources/SafariBrowser/Entitlements.plist
    printf '.build/\ndist/\n' > .gitignore
    echo a > other.txt
    "$REAL_GIT" add -A && "$REAL_GIT" commit -q -m one && "$REAL_GIT" tag "$tag"
  )
}

# One case = one directory holding the repo, the shims, the call log and the captured
# output. Prints the directory; the caller reads $CASE/repo, $CASE/calls.log, …
new_case() { # name [tag]
  local c="$TMPROOT/$1"
  mkdir -p "$c"
  make_shims "$c/shims"
  new_repo "$c/repo" "${2:-v1.2.3}"
  : > "$c/calls.log"
  echo "$c"
}

# Runs release.sh in the case's repo. Extra args are VAR=value pairs for the script.
# Sets RC; stdout/stderr land in $CASE/stdout and $CASE/stderr. The ambient values of
# the script's own knobs are removed so a developer's shell cannot change a result.
run_release() { # case-dir [VAR=value ...]
  local c="$1"; shift
  ( cd "$c/repo${RUN_SUBDIR:+/$RUN_SUBDIR}" && env -u DEVELOPER_ID -u NOTARIZE -u NOTARY_PROFILE -u RELEASE_TIMESTAMP \
      -u DIST_DIR -u ENTITLEMENTS -u BINARY_NAME \
      PATH="$c/shims:$PATH" REAL_GIT="$REAL_GIT" \
      FAKE_LOG="$c/calls.log" FAKE_BIN_PATH="$c/products" \
      VERIFY_BIN="$c/shims/fake-verify" \
      "$@" bash "$RELEASE" ) >"$c/stdout" 2>"$c/stderr"
  RC=$?
}

built() { grep -q '^swift build' "$1/calls.log" 2>/dev/null; }
no_artifacts() { [ -z "$(ls -A "$1/repo/dist" 2>/dev/null)" ]; }
tree_clean() { [ -z "$(cd "$1/repo" && "$REAL_GIT" status --porcelain)" ]; }
placeholder_back() { [ "$(cat "$1/repo/$VERSION_FILE")" = "$PLACEHOLDER" ]; }

echo "release.sh"

if [ ! -f "$RELEASE" ]; then
  fail "scripts/release.sh exists" "$RELEASE"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

# --- preflight: every refusal happens before the build ---------------------------

# 1. no signing identity named at all
C="$(new_case no-id)"
run_release "$C" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "1 DEVELOPER_ID unset is refused" "$RC"
# not just "some error mentioning it": under set -u an unset variable would crash with
# "DEVELOPER_ID: unbound variable" even without the explicit check
assert_has "1 the refusal is the designed message" "DEVELOPER_ID is unset" "$C/stderr"
built "$C" && fail "1 nothing was built" || ok "1 nothing was built"

# 1b. set but empty is the same as unset (an empty string would match every keychain line)
C="$(new_case empty-id)"
run_release "$C" DEVELOPER_ID= FAKE_IDENTITIES="$FAKE_ID"
assert_refused "1b an empty DEVELOPER_ID is refused" "$RC"
assert_has "1b the refusal is the designed message" "DEVELOPER_ID is unset" "$C/stderr"
built "$C" && fail "1b nothing was built" || ok "1b nothing was built"

# 2. an identity the keychain does not hold
C="$(new_case id-missing)"
run_release "$C" DEVELOPER_ID=0000DEADBEEF FAKE_IDENTITIES="$FAKE_ID"
assert_refused "2 an identity not in the keychain is refused" "$RC"
assert_has "2 the refusal says keychain" "keychain" "$C/stderr"
built "$C" && fail "2 nothing was built" || ok "2 nothing was built"

# 3. uncommitted changes: the binary would not match any commit
C="$(new_case dirty)"
echo changed > "$C/repo/other.txt"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "3 a dirty tree is refused" "$RC"
assert_has "3 the refusal says the tree is not clean" "clean" "$C/stderr"
built "$C" && fail "3 nothing was built" || ok "3 nothing was built"

# 3b. an untracked file counts: it can end up in the build
C="$(new_case untracked)"
echo new > "$C/repo/stray.txt"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "3b an untracked file is refused" "$RC"
built "$C" && fail "3b nothing was built" || ok "3b nothing was built"

# 4. HEAD is on no release tag, and an IDD baseline tag does not stand in for one
C="$(new_case no-tag)"
(cd "$C/repo" && "$REAL_GIT" tag -d v1.2.3 >/dev/null && "$REAL_GIT" tag idd-217-baseline)
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "4 HEAD on only an idd-*-baseline tag is refused" "$RC"
assert_has "4 the refusal says tag" "tag" "$C/stderr"
built "$C" && fail "4 nothing was built" || ok "4 nothing was built"

# 5. the tag is an ancestor but HEAD has moved on
C="$(new_case after-tag)"
(cd "$C/repo" && echo b > other.txt && "$REAL_GIT" commit -q -am two)
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "5 a commit after the tag is refused" "$RC"
built "$C" && fail "5 nothing was built" || ok "5 nothing was built"

# 5b. a tag that is not a version: its text would reach a directory name and a shell line
C="$(new_case odd-tag 'v1.2.3;touch-pwned')"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "5b a tag that is not vX.Y.Z is refused" "$RC"
built "$C" && fail "5b nothing was built" || ok "5b nothing was built"
assert_absent "5b nothing was created from the tag text" "$C/repo/touch-pwned"

# 6. a release that is going to Apple needs a secure timestamp
C="$(new_case no-ts)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" NOTARIZE=1 RELEASE_TIMESTAMP=none
assert_refused "6 NOTARIZE=1 with RELEASE_TIMESTAMP=none is refused" "$RC"
assert_has "6 the refusal says timestamp" "timestamp" "$C/stderr"
built "$C" && fail "6 nothing was built" || ok "6 nothing was built"

# 7. the notary profile must answer before an 8-minute build, not after
C="$(new_case probe-fails)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" NOTARIZE=1 FAKE_NOTARY_PROBE_FAIL=1
assert_refused "7 a failing notarytool profile probe is refused" "$RC"
assert_has "7 the refusal names the profile" "che-mcps-notary" "$C/stderr"
built "$C" && fail "7 nothing was built" || ok "7 nothing was built"

# 7b. knobs with a closed set of values are checked, not coerced into a default
C="$(new_case bad-notarize)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" NOTARIZE=yes
assert_refused "7b NOTARIZE other than 0 or 1 is refused" "$RC"
assert_has "7b the refusal names NOTARIZE" "NOTARIZE must be" "$C/stderr"
built "$C" && fail "7b nothing was built" || ok "7b nothing was built"

C="$(new_case bad-timestamp)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" RELEASE_TIMESTAMP=bogus
assert_refused "7c RELEASE_TIMESTAMP other than empty or none is refused" "$RC"
assert_has "7c the refusal names RELEASE_TIMESTAMP" "RELEASE_TIMESTAMP must be" "$C/stderr"
built "$C" && fail "7c nothing was built" || ok "7c nothing was built"

# 7d. git describe walks up into parent repositories, so only the repository root is allowed
C="$(new_case subdir)"
RUN_SUBDIR=Sources run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "7d running from a subdirectory is refused" "$RC"
assert_has "7d the refusal says repository root" "repository root" "$C/stderr"
built "$C" && fail "7d nothing was built" || ok "7d nothing was built"

# 7e. what the signing step needs is checked before the build, not after it
C="$(new_case no-entitlements)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" ENTITLEMENTS="$C/nowhere.plist"
assert_refused "7e a missing entitlements file is refused" "$RC"
assert_has "7e the refusal names the entitlements file" "entitlements file not found" "$C/stderr"
built "$C" && fail "7e nothing was built" || ok "7e nothing was built"

C="$(new_case no-guard)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" VERIFY_BIN="$C/nowhere"
assert_refused "7f a missing install-signature guard is refused" "$RC"
assert_has "7f the refusal names the guard" "install-signature guard" "$C/stderr"
built "$C" && fail "7f nothing was built" || ok "7f nothing was built"

# --- the dry run (NOTARIZE defaults to 0) ----------------------------------------

C="$(new_case dry)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_ok "8 a dry run succeeds" "$RC"
D="$C/repo/dist/v1.2.3-DRYRUN"
assert_exists "8 the dry-run directory is named as one" "$D/safari-browser"
assert_exists "8 the dry-run directory carries its marker" "$D/DRYRUN-NOT-NOTARIZED"
assert_absent "8 no release directory exists" "$C/repo/dist/v1.2.3"
assert_absent "8 no NOTARIZATION.json" "$D/NOTARIZATION.json"
assert_lacks "8 notarytool was never invoked" "notarytool submit" "$C/calls.log"
assert_has "8 codesign got the hardened runtime" "--options runtime" "$C/calls.log"
grep -Eq -- '^codesign .*--timestamp( |$)' "$C/calls.log" \
  && ok "8 codesign got a secure timestamp (not --timestamp=none)" || fail "8 codesign got a secure timestamp (not --timestamp=none)" "$(grep '^codesign --force' "$C/calls.log")"
assert_has "8 codesign got the identity" "--sign $FAKE_ID" "$C/calls.log"
assert_has "8 codesign got the entitlements file" "--entitlements" "$C/calls.log"
assert_has "8 the shipped binary is the signed one" "# SIGNED" "$D/safari-browser"
assert_has "8 the verifier required the Developer ID shape" "--require-shape Developer ID" "$C/calls.log"
assert_has "8 the verifier required the apple-events entitlement" "--require-entitlement $ENT_KEY" "$C/calls.log"
assert_eq "8 the shipped binary reports the tag" "v1.2.3" "$("$D/safari-browser" --version)"

# 9. the checksum file holds the hash and nothing else
# (an absent file would make both sides empty and "equal", so it has to exist first)
if [ -f "$D/safari-browser" ] && [ -f "$D/safari-browser.sha256" ]; then
  assert_eq "9 the checksum is the sha256 of the shipped binary, alone" "$(shasum -a 256 < "$D/safari-browser" | awk '{print $1}')" "$(cat "$D/safari-browser.sha256")"
  assert_eq "9 the checksum file is one line" "1" "$(wc -l < "$D/safari-browser.sha256" | tr -d ' ')"
else
  fail "9 the checksum is the sha256 of the shipped binary, alone" "binary or checksum file missing in $D"
  fail "9 the checksum file is one line" "binary or checksum file missing in $D"
fi

# 10. both sides of the stamping contract: the tree is untouched afterwards
tree_clean "$C" && ok "10 the tree is clean after a successful run" || fail "10 the tree is clean after a successful run" "$(cd "$C/repo" && "$REAL_GIT" status --porcelain)"
placeholder_back "$C" && ok "10 the placeholder is back after a successful run" || fail "10 the placeholder is back after a successful run"

# 11. an existing output directory is never overwritten
BEFORE="$(shasum -a 256 < "$D/safari-browser" 2>/dev/null)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "11 a second run into the same directory is refused" "$RC"
if [ -n "$BEFORE" ]; then
  assert_eq "11 the first run's binary is untouched" "$BEFORE" "$(shasum -a 256 < "$D/safari-browser")"
else
  fail "11 the first run's binary is untouched" "there was no first run's binary to compare"
fi

# 12. RELEASE_TIMESTAMP=none exists for an offline dry run and nothing else
C="$(new_case offline)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" RELEASE_TIMESTAMP=none
assert_ok "12 an offline dry run succeeds" "$RC"
assert_has "12 codesign got --timestamp=none" "--timestamp=none" "$C/calls.log"

# --- failures after the build leave nothing behind --------------------------------

# 13. a Universal build that is missing a slice
C="$(new_case one-slice)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" FAKE_LIPO_ARCHS="arm64"
assert_refused "13 a missing x86_64 slice is refused" "$RC"
assert_has "13 the refusal names the missing slice" "x86_64" "$C/stderr"
no_artifacts "$C" && ok "13 no artifacts were left" || fail "13 no artifacts were left" "$(ls -A "$C/repo/dist")"
tree_clean "$C" && ok "13 the tree is clean after a failure" || fail "13 the tree is clean after a failure"
placeholder_back "$C" && ok "13 the placeholder is back after a failure" || fail "13 the placeholder is back after a failure"

# 14. the binary says something other than the tag (a stamp that did not take)
C="$(new_case wrong-version)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" FAKE_BAKE_VERSION=unknown
assert_refused "14 a binary that does not report the tag is refused" "$RC"
assert_has "14 the refusal shows what it reported" "unknown" "$C/stderr"
no_artifacts "$C" && ok "14 no artifacts were left" || fail "14 no artifacts were left"

# 15. a signature that does not verify
C="$(new_case bad-signature)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" FAKE_CODESIGN_VERIFY_FAIL=1
assert_refused "15 a signature that fails codesign --verify is refused" "$RC"
no_artifacts "$C" && ok "15 no artifacts were left" || fail "15 no artifacts were left"

# 16. a signature that would not survive a rebuild (the Full Disk Access contract)
C="$(new_case not-durable)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" FAKE_VERIFY_FAIL=1
assert_refused "16 a binary the install-signature guard rejects is refused" "$RC"
no_artifacts "$C" && ok "16 no artifacts were left" || fail "16 no artifacts were left"

# --- notarization (NOTARIZE=1) ---------------------------------------------------

C="$(new_case notarized)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" NOTARIZE=1
assert_ok "17 an accepted submission succeeds" "$RC"
D="$C/repo/dist/v1.2.3"
assert_exists "17 the release directory has the binary" "$D/safari-browser"
assert_exists "17 the release directory has the checksum" "$D/safari-browser.sha256"
assert_exists "17 the release directory has the notarization record" "$D/NOTARIZATION.json"
assert_has "17 the record carries the submission id" "11111111-2222-3333-4444-555555555555" "$D/NOTARIZATION.json"
assert_has "17 the record carries the status" "Accepted" "$D/NOTARIZATION.json"
assert_absent "17 no dry-run directory" "$C/repo/dist/v1.2.3-DRYRUN"
assert_absent "17 no dry-run marker" "$D/DRYRUN-NOT-NOTARIZED"
assert_eq "17 the zip sent to Apple is not shipped" "0" "$(ls "$D" | grep -c '\.zip$')"
# the probe line also names the profile, so the submit line itself has to be the one checked
grep -Eq '^xcrun notarytool submit .*--keychain-profile che-mcps-notary' "$C/calls.log" \
  && ok "17 submit used the default profile" || fail "17 submit used the default profile" "$(grep '^xcrun notarytool submit' "$C/calls.log")"
grep -Eq '^xcrun notarytool submit .*--wait' "$C/calls.log" \
  && ok "17 submit waits for the verdict" || fail "17 submit waits for the verdict" "$(grep '^xcrun notarytool submit' "$C/calls.log")"
assert_has "17 the zip existed when submitted" "zip-present" "$C/calls.log"
assert_has "17 the zip held the signed binary" "zip-signed" "$C/calls.log"
SIGN_AT="$(line_of "$C/calls.log" '^codesign --force')"
VERIFY_AT="$(line_of "$C/calls.log" '^verify ')"
SUBMIT_AT="$(line_of "$C/calls.log" '^xcrun notarytool submit')"
if [ "$SIGN_AT" -gt 0 ] && [ "$VERIFY_AT" -gt "$SIGN_AT" ] && [ "$SUBMIT_AT" -gt "$VERIFY_AT" ]; then
  ok "17 order is sign, then verify, then submit"
else
  fail "17 order is sign, then verify, then submit" "sign=$SIGN_AT verify=$VERIFY_AT submit=$SUBMIT_AT"
fi

# 18. the script prints the outward commands and does not run them
assert_has "18 it tells the user how to push the tag" "git push origin v1.2.3" "$C/stdout"
assert_has "18 it tells the user how to create the release" "gh release create v1.2.3" "$C/stdout"
grep -Eq '^git (tag|push)( |$)' "$C/calls.log" && fail "18 git tag / git push were never run" "$(grep -E '^git (tag|push)' "$C/calls.log")" || ok "18 git tag / git push were never run"
grep -q '^gh ' "$C/calls.log" && fail "18 gh was never run" || ok "18 gh was never run"

# 19. an Invalid verdict stops everything and shows why
C="$(new_case invalid)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" NOTARIZE=1 FAKE_NOTARY_STATUS=Invalid
assert_refused "19 an Invalid submission fails" "$RC"
assert_has "19 the notarytool log was fetched for the submission" "notarytool log 11111111-2222-3333-4444-555555555555" "$C/calls.log"
assert_has "19 the log's reason reached the user" "FAKE-LOG-THE-BINARY-IS-NOT-SIGNED" "$C/stderr"
no_artifacts "$C" && ok "19 no artifacts were left" || fail "19 no artifacts were left" "$(ls -A "$C/repo/dist")"
tree_clean "$C" && ok "19 the tree is clean after a rejection" || fail "19 the tree is clean after a rejection"

# 20. any verdict that is not Accepted is not a pass
C="$(new_case in-progress)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" NOTARIZE=1 "FAKE_NOTARY_STATUS=In Progress"
assert_refused "20 a status other than Accepted fails" "$RC"
no_artifacts "$C" && ok "20 no artifacts were left" || fail "20 no artifacts were left"

# --- wiring in the repository itself ---------------------------------------------

MAKE_OUT="$(cd "$REPO_ROOT" && make -n release-signed DEVELOPER_ID=x 2>&1)"
case "$MAKE_OUT" in
  *scripts/release.sh*) ok "21 make release-signed runs scripts/release.sh" ;;
  *) fail "21 make release-signed runs scripts/release.sh" "$(printf '%s' "$MAKE_OUT" | head -c 400)" ;;
esac
grep -Eq '^test-all:.*test-release' "$REPO_ROOT/Makefile" \
  && ok "22 test-all includes test-release" || fail "22 test-all includes test-release"
(cd "$REPO_ROOT" && "$REAL_GIT" check-ignore -q dist/v1.0.0/safari-browser) \
  && ok "23 dist/ is gitignored" || fail "23 dist/ is gitignored"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
