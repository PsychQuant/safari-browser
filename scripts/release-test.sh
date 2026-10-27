#!/bin/bash
# Behavior tests for scripts/release.sh (#280).
#
# A real release takes minutes (a Universal build, then an Apple round-trip) and ends
# in a signed binary, so these tests run the script against PATH shims for `swift`,
# `codesign`, `lipo`, `security`, `xcrun`, `ditto`, `shasum`, `gh` and a guarded `git`,
# inside throwaway git repositories.
#
# The shims are deliberately picky: each one fails the way the real tool would when it
# is called wrongly (a missing flag, a zip of the wrong layout, notarytool output that
# is not JSON, a file that was never signed). A shim that accepts anything makes a
# green run say nothing about the real one; review of #308 found that dozens of
# one-line mutants of release.sh survived the first version of this suite for exactly
# that reason.
#
# git is real, behind a shim that logs every call and allows only the read-only
# subcommands release.sh and stamp-version.sh use (rev-parse, status, ls-files,
# describe, `tag` as a listing, `remote get-url`); anything else is refused and logged.
# An allowlist rather than a list of writing subcommands: a new git call in the script
# fails here until someone decides it is read-only, and an option the shim does not
# know (one whose value is a separate word, like --config-env) makes its value look
# like the subcommand, which is refused too. It is a guard against regressions, not a
# sandbox: an absolute-path git or an alias gets past it. Every run is checked for
# such a call, not just the notarizing one.
#
# What the shims cannot tell us is whether Apple accepts the binary or whether the
# Universal build runs on an Intel Mac. Those are measured by hand and recorded in the
# issue; nothing here claims them.
#
# Usage: /bin/bash scripts/release-test.sh      (the Makefile runs it under /bin/bash,
#                                                the bash 3.2 that release.sh runs under)
#        RELEASE_SCRIPT=/path/to/variant.sh /bin/bash scripts/release-test.sh   # mutation checks
set -u

# A caller's git environment (a hook exports GIT_DIR / GIT_INDEX_FILE) would send this
# suite's commits and tags into another repository, and the caller's config (signing,
# status.showUntrackedFiles, a global ignore file) would change what the guards under
# test see. Config reaches git three ways and each is closed separately: the config
# FILES (GIT_CONFIG_GLOBAL / _SYSTEM), config passed through the ENVIRONMENT
# (GIT_CONFIG_PARAMETERS, GIT_CONFIG_COUNT and its KEY_n / VALUE_n), and the files git
# reads by default without any config, $XDG_CONFIG_HOME/git/ignore and .../attributes
# (or ~/.config/git/... when XDG_CONFIG_HOME is unset) — GIT_CONFIG_GLOBAL=/dev/null
# does not turn those off, so XDG_CONFIG_HOME points at an empty directory below.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_NAMESPACE
unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE="${RELEASE_SCRIPT:-$SCRIPT_DIR/release.sh}"
REAL_GIT="$(command -v git)"

PLACEHOLDER='enum BuildVersion { static let value = "unknown" }'
VERSION_FILE="Sources/SafariBrowser/BuildVersion.swift"
ENT_KEY="com.apple.security.automation.apple-events"
FAKE_ID="0123456789ABCDEF0123456789ABCDEF01234567"
EXPIRED_ID="FEDCBA9876543210FEDCBA9876543210FEDCBA98"
NOT_IN_KEYCHAIN="0000000000000000000000000000000000000000"

PASS=0
FAIL=0
CASES_RUN=0
FORBIDDEN_HITS=""
LEAKED=""
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
export XDG_CONFIG_HOME="$TMPROOT/xdg-config"   # empty: no default global ignore / attributes file
mkdir -p "$XDG_CONFIG_HOME"

ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; }
skip() { echo "  skip $1"; }

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

  # git: real, but only the read-only subcommands release.sh and stamp-version.sh use get
  # through, wherever the subcommand sits among the options (-C <dir>, -c k=v, ...).
  # Everything else is refused: an allowlist, so an option this loop does not know turns
  # its value into the "subcommand", and that is refused too (fail closed).
  cat > "$1/git" <<'EOF'
#!/bin/bash
echo "git $*" >> "$FAKE_LOG"
ORIG=("$@")
refuse() { echo "FORBIDDEN git $*" >> "$FAKE_LOG"; echo "fake git: '$*' is not allowed in a release run" >&2; exit 99; }
sub=""; skip=0; n=0
for a in "$@"; do
  n=$((n + 1))
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in
    -C|-c|--git-dir|--work-tree|--namespace) skip=1 ;;
    -*) ;;
    *) sub="$a"; break ;;
  esac
done
shift "$n"   # what follows the subcommand
case "$sub" in
  rev-parse|status|ls-files|describe) ;;
  tag)
    # a listing only: every argument must be a listing option or the value of one
    listing=0; prev=""
    for a in "$@"; do
      case "$a" in
        --list|-l|--points-at|--points-at=*) listing=1 ;;
        -*) refuse "tag $*" ;;
        *) case "$prev" in --points-at) ;; *) [ "$listing" = 1 ] || refuse "tag $*" ;; esac ;;
      esac
      prev="$a"
    done
    [ "$listing" = 1 ] || refuse "tag $*" ;;
  remote)
    [ "${1:-}" = get-url ] && [ $# -eq 2 ] || refuse "remote $*" ;;
  *) refuse "${sub:-<none>} $*" ;;
esac
exec "$REAL_GIT" "${ORIG[@]}"
EOF

  cat > "$1/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "$FAKE_LOG"
exit 1
EOF

  # `find-identity` lists expired identities unless -v is given, as the real one does.
  cat > "$1/security" <<'EOF'
#!/bin/bash
echo "security $*" >> "$FAKE_LOG"
if [ "$1" = find-identity ]; then
  valid=0
  for a in "$@"; do [ "$a" = -v ] && valid=1; done
  name="${FAKE_IDENTITY_NAME:-Developer ID Application: Example Person (ABCDE12345)}"
  n=0
  if [ -n "${FAKE_IDENTITIES:-}" ]; then
    printf '  1) %s "%s"\n' "$FAKE_IDENTITIES" "$name"
    n=1
  fi
  if [ "$valid" = 0 ]; then
    printf '  2) FEDCBA9876543210FEDCBA9876543210FEDCBA98 "Developer ID Application: Expired Person (ZZZZZ99999)" (CSSMERR_TP_CERT_EXPIRED)\n'
    n=$((n + 1))
  fi
  printf '     %d valid identities found\n' "$n"
  exit 0
fi
exit 64
EOF

  # What lipo reports is what the (fake) build was asked to build: the architectures it
  # got via --arch, unless FAKE_BUILD_ARCHS overrides them (a build that dropped a slice).
  cat > "$1/lipo" <<'EOF'
#!/bin/bash
echo "lipo $*" >> "$FAKE_LOG"
[ "$1" = -archs ] || exit 64
cat "$FAKE_BIN_PATH/archs" 2>/dev/null || { echo "fake lipo: no build products" >&2; exit 1; }
EOF

  # `swift build ... --show-bin-path` prints a directory and builds nothing. A real
  # build bakes whatever BuildVersion.swift says at that moment into the binary, which
  # is the property the self-report check relies on; the fake binary does the same. It
  # also records the configuration and architectures it was asked for.
  cat > "$1/swift" <<'EOF'
#!/bin/bash
echo "swift $*" >> "$FAKE_LOG"
for a in "$@"; do
  [ "$a" = "--show-bin-path" ] && { echo "$FAKE_BIN_PATH"; exit 0; }
done
[ "$1" = build ] || exit 64
if [ -n "${FAKE_EXPECT_OUT:-}" ]; then
  if [ -d "$FAKE_EXPECT_OUT" ]; then echo "out-reserved" >> "$FAKE_LOG"; else echo "out-not-reserved" >> "$FAKE_LOG"; fi
fi
[ -n "${FAKE_BUILD_SLEEP:-}" ] && sleep "$FAKE_BUILD_SLEEP"
[ -n "${FAKE_LOCK_OUT:-}" ] && chmod 555 "$FAKE_LOCK_OUT"
[ -n "${FAKE_BUILD_FAIL:-}" ] && { echo "fake swift: the build failed" >&2; exit 1; }
cfg=debug; archs=""; prev=""
for a in "$@"; do
  [ "$prev" = -c ] && cfg="$a"
  [ "$prev" = --arch ] && archs="${archs:+$archs }$a"
  prev="$a"
done
mkdir -p "$FAKE_BIN_PATH"
printf '%s\n' "$cfg" > "$FAKE_BIN_PATH/build-config"
printf '%s\n' "${FAKE_BUILD_ARCHS:-$archs}" > "$FAKE_BIN_PATH/archs"
V="$(sed -n 's/.*value = "\(.*\)".*/\1/p' Sources/SafariBrowser/BuildVersion.swift)"
[ -n "${FAKE_BAKE_VERSION:-}" ] && V="$FAKE_BAKE_VERSION"
# Only a SIGNED copy answers with the stamped version: the self-report check is the one
# step that runs the binary before it ships, and pointing it at the unsigned build
# product instead must not pass unnoticed (round-2 review of #308).
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then grep -q "^# SIGNED$" "$0" || { echo unsigned-build; exit 0; }; echo "%s"; exit %s; fi\nexit 0\n' "$V" "${FAKE_VERSION_RC:-0}" > "$FAKE_BIN_PATH/safari-browser"
chmod +x "$FAKE_BIN_PATH/safari-browser"
EOF

  # Signing appends a marker to the file, so "the shipped binary was signed" and "the
  # zip Apple received was of the signed binary" are both checkable from the outside.
  # It refuses a call without the flags a real, notarizable signature needs.
  cat > "$1/codesign" <<'EOF'
#!/bin/bash
echo "codesign $*" >> "$FAKE_LOG"
bad() { echo "fake codesign: $*" >&2; exit 1; }
for last; do :; done
case "$1" in
  --verify|-v)
    case " $* " in *" --strict "*) ;; *) bad "verify without --strict" ;; esac
    grep -q '^# SIGNED$' "$last" 2>/dev/null || bad "verify: $last was never signed"
    [ -n "${FAKE_CODESIGN_VERIFY_FAIL:-}" ] && bad "verification failed"
    exit 0 ;;
esac
force=0; rt=0; ts=0; sign=""; ent=""; prev=""
for a in "$@"; do
  case "$a" in
    --force) force=1 ;;
    runtime) [ "$prev" = --options ] && rt=1 ;;
    --timestamp|--timestamp=none) ts=1 ;;
  esac
  [ "$prev" = --sign ] && sign="$a"
  [ "$prev" = --entitlements ] && ent="$a"
  prev="$a"
done
[ "$force" = 1 ] || bad "missing --force"
[ "$rt" = 1 ] || bad "missing --options runtime"
[ "$ts" = 1 ] || bad "missing --timestamp"
[ -n "$sign" ] || bad "missing --sign <identity>"
grep -q 'com.apple.security.automation.apple-events' "$ent" 2>/dev/null || bad "the entitlements file does not name apple-events"
[ -f "$last" ] || bad "no such file: $last"
printf '# SIGNED\n' >> "$last"
EOF

  # notarytool: `submit` insists on --wait, a profile and --output-format json, and on a
  # zip whose only entry is the signed binary; without json it prints text, as the real
  # tool does, which the script must not accept.
  cat > "$1/xcrun" <<'EOF'
#!/bin/bash
echo "xcrun $*" >> "$FAKE_LOG"
[ "$1" = notarytool ] || exit 64
case "$2" in
  history)
    [ -n "${FAKE_NOTARY_PROBE_FAIL:-}" ] && { echo "Error: HTTP status code: 401. Invalid credentials." >&2; exit 1; }
    echo "Successfully received submission history."; exit 0 ;;
  submit)
    zip="$3"; json=0; wait=0; profile=""; prev=""
    for a in "$@"; do
      [ "$prev" = --output-format ] && [ "$a" = json ] && json=1
      [ "$a" = --wait ] && wait=1
      [ "$prev" = --keychain-profile ] && profile="$a"
      prev="$a"
    done
    [ -f "$zip" ] || { echo "zip-missing" >> "$FAKE_LOG"; echo "Error: no such file $zip" >&2; exit 1; }
    entries="$(unzip -Z1 "$zip" 2>/dev/null)"
    [ "$entries" = "safari-browser" ] || { echo "zip-bad-layout" >> "$FAKE_LOG"; echo "Error: unexpected archive layout: $entries" >&2; exit 1; }
    unzip -p "$zip" safari-browser | grep -q '^# SIGNED$' || { echo "zip-unsigned" >> "$FAKE_LOG"; echo "Error: not signed" >&2; exit 1; }
    echo "zip-ok" >> "$FAKE_LOG"
    { [ "$wait" = 1 ] && [ -n "$profile" ]; } || { echo "Error: --wait and --keychain-profile are required here" >&2; exit 1; }
    [ -n "${FAKE_NOTARY_EMPTY:-}" ] && exit 0
    if [ "$json" = 1 ]; then
      printf '{"id":"11111111-2222-3333-4444-555555555555","message":"Processing complete","status":"%s"}\n' "${FAKE_NOTARY_STATUS:-Accepted}"
    else
      echo "Successfully uploaded file. Processing complete. status: ${FAKE_NOTARY_STATUS:-Accepted}"
    fi
    exit "${FAKE_NOTARY_RC:-0}" ;;
  log)
    echo '{"status":"Invalid","issues":[{"severity":"error","message":"FAKE-LOG-THE-BINARY-IS-NOT-SIGNED"}]}'
    exit 0 ;;
esac
exit 64
EOF

  # The install-signature guard: it must be given the Developer ID shape, the
  # entitlement, and the SIGNED file (not the unsigned build product).
  cat > "$1/fake-verify" <<'EOF'
#!/bin/bash
echo "verify $*" >> "$FAKE_LOG"
shape=""; ent=""; prev=""
for a in "$@"; do
  [ "$prev" = --require-shape ] && shape="$a"
  [ "$prev" = --require-entitlement ] && ent="$a"
  prev="$a"
done
for last; do :; done
[ "$shape" = "Developer ID" ] || { echo "fake verify: --require-shape must be exactly 'Developer ID' (got '$shape')" >&2; exit 2; }
[ "$ent" = "com.apple.security.automation.apple-events" ] || { echo "fake verify: --require-entitlement apple-events missing (got '$ent')" >&2; exit 2; }
grep -q '^# SIGNED$' "$last" 2>/dev/null || { echo "fake verify: $last is not the signed binary" >&2; exit 2; }
[ -n "${FAKE_VERIFY_FAIL:-}" ] && { echo "fake verify: not durable" >&2; exit 1; }
exit 0
EOF

  cat > "$1/shasum" <<'EOF'
#!/bin/bash
echo "shasum $*" >> "$FAKE_LOG"
[ -n "${FAKE_SHASUM_FAIL:-}" ] && { echo "fake shasum: read error" >&2; exit 1; }
[ -n "${FAKE_SHASUM_GARBAGE:-}" ] && { echo "not-a-hash  -"; exit 0; }
if [ -n "${FAKE_SHASUM_LATE_FAIL:-}" ]; then /usr/bin/shasum "$@"; exit 1; fi
# make the staging directory read-only after the hash is computed, so only the write of
# the .sha256 file fails (release.sh runs from the repo root with DIST_DIR=dist here)
if [ -n "${FAKE_SHASUM_LOCK_STAGE:-}" ]; then
  /usr/bin/shasum "$@" || exit 1
  for d in dist/.staging.*; do [ -d "$d" ] && chmod 555 "$d"; done
  exit 0
fi
exec /usr/bin/shasum "$@"
EOF

  # mv: the final move into the reserved output directory. FAKE_MV_SIGNAL sends TERM to
  # the script (its parent) while the move is in flight, the moment at which a deferred
  # trap used to delete the finished result.
  cat > "$1/mv" <<'EOF'
#!/bin/bash
echo "mv $*" >> "$FAKE_LOG"
[ -n "${FAKE_MV_SIGNAL:-}" ] && kill -TERM "$PPID"
exec /bin/mv "$@"
EOF

  cat > "$1/ditto" <<'EOF'
#!/bin/bash
echo "ditto $*" >> "$FAKE_LOG"
[ -n "${FAKE_DITTO_FAIL:-}" ] && { echo "fake ditto: no space left on device" >&2; exit 1; }
if [ -n "${FAKE_LOCK_STAGE:-}" ]; then
  /usr/bin/ditto "$@" || exit 1
  for src; do :; done          # the last argument is the zip; the one before it is the binary
  prev=""; for a in "$@"; do [ "$a" = "$src" ] && break; prev="$a"; done
  chmod 555 "$(dirname "$prev")"
  exit 0
fi
exec /usr/bin/ditto "$@"
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
  mkdir -p "$c/tmp"
  make_shims "$c/shims"
  new_repo "$c/repo" "${2:-v1.2.3}"
  : > "$c/calls.log"
  echo "$c"
}

# Checks that apply to EVERY run, however the test that made it was written: no write
# to git and no gh call (the promise in the script's header), and nothing left behind in
# the run's private TMPDIR.
post_run_checks() { # case-dir
  local c="$1"
  CASES_RUN=$((CASES_RUN + 1))
  if grep -Eq '^(gh |FORBIDDEN)' "$c/calls.log" 2>/dev/null; then
    FORBIDDEN_HITS="$FORBIDDEN_HITS $(basename "$c")"
  fi
  if [ -n "$(ls -A "$c/tmp" 2>/dev/null)" ]; then
    LEAKED="$LEAKED $(basename "$c")"
  fi
}

# Runs release.sh in the case's repo, under /bin/bash like the Makefile does. Extra
# args are VAR=value pairs for the script. Sets RC; stdout/stderr land in $CASE/stdout
# and $CASE/stderr. The ambient values of the script's own knobs are removed so a
# developer's shell cannot change a result. RUN_ASYNC=1 starts it in the background and
# sets ASYNC_PID (for the signal test).
run_release() { # case-dir [VAR=value ...]
  local c="$1"; shift
  mkdir -p "$c/tmp"
  local cmd=( env -u DEVELOPER_ID -u NOTARIZE -u NOTARY_PROFILE -u RELEASE_TIMESTAMP
              -u DIST_DIR -u ENTITLEMENTS -u BINARY_NAME
              PATH="$c/shims:$PATH" REAL_GIT="$REAL_GIT" TMPDIR="$c/tmp"
              FAKE_LOG="$c/calls.log" FAKE_BIN_PATH="$c/products"
              VERIFY_BIN="$c/shims/fake-verify"
              "$@" /bin/bash "$RELEASE" )
  if [ -n "${RUN_ASYNC:-}" ]; then
    # A background job of a non-interactive shell starts with SIGINT and SIGQUIT IGNORED,
    # and a signal ignored on entry cannot be trapped; job control (set -m) is what makes
    # it behave like a script run from a terminal.
    set -m
    ( cd "$c/repo" && exec "${cmd[@]}" ) >"$c/stdout" 2>"$c/stderr" &
    ASYNC_PID=$!
    set +m
    return 0
  fi
  ( cd "$c/repo${RUN_SUBDIR:+/$RUN_SUBDIR}" && "${cmd[@]}" ) >"$c/stdout" 2>"$c/stderr"
  RC=$?
  post_run_checks "$c"
}

built() { grep -q '^swift build' "$1/calls.log" 2>/dev/null; }
no_artifacts() { [ -z "$(ls -A "$1/repo/dist" 2>/dev/null)" ]; }
tree_clean() { [ -z "$(cd "$1/repo" && "$REAL_GIT" status --porcelain --untracked-files=all)" ]; }
placeholder_back() { [ "$(cat "$1/repo/$VERSION_FILE")" = "$PLACEHOLDER" ]; }
nothing_built() { # name case-dir
  if built "$2"; then fail "$1 nothing was built"; else ok "$1 nothing was built"; fi
}

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
nothing_built "1" "$C"

# 1b. set but empty is the same as unset
C="$(new_case empty-id)"
run_release "$C" DEVELOPER_ID= FAKE_IDENTITIES="$FAKE_ID"
assert_refused "1b an empty DEVELOPER_ID is refused" "$RC"
assert_has "1b the refusal is the designed message" "DEVELOPER_ID is unset" "$C/stderr"
nothing_built "1b" "$C"

# 2. a well-formed identity the keychain does not hold
C="$(new_case id-missing)"
run_release "$C" DEVELOPER_ID="$NOT_IN_KEYCHAIN" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "2 an identity not in the keychain is refused" "$RC"
assert_has "2 the refusal says keychain" "keychain" "$C/stderr"
nothing_built "2" "$C"

# 2b. anything that is not a 40-hex SHA-1 is refused up front. The old check was a
# substring match over the whole listing, so `0` or `valid` matched the summary line
# "0 valid identities found" and only codesign refused, after the build.
n=0
for BAD in 0 valid identities "valid identities found" 0123456789ABCDEF0123456789ABCDEF0123456 "${FAKE_ID}0" "not-hex-not-hex-not-hex-not-hex-not-hex-"; do
  n=$((n + 1))
  C="$(new_case "bad-id-$n")"
  run_release "$C" "DEVELOPER_ID=$BAD"   # an empty keychain: the worst case for substring matching
  assert_refused "2b '$BAD' is refused with an empty keychain" "$RC"
  assert_has "2b the refusal asks for the 40-hex SHA-1" "40" "$C/stderr"
  nothing_built "2b '$BAD'" "$C"
done

# 2c. an expired identity is listed only without `find-identity -v`
C="$(new_case id-expired)"
run_release "$C" DEVELOPER_ID="$EXPIRED_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "2c an expired identity is refused" "$RC"
assert_has "2c the refusal says keychain" "keychain" "$C/stderr"
nothing_built "2c" "$C"
assert_has "2c the listing was asked for valid identities only (-v)" "security find-identity -v" "$C/calls.log"

# 2d. a valid identity that is not a Developer ID Application one
C="$(new_case id-wrong-kind)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" "FAKE_IDENTITY_NAME=Apple Development: Example Person (ABCDE12345)"
assert_refused "2d an identity that is not a Developer ID Application is refused" "$RC"
assert_has "2d the refusal says Developer ID Application" "Developer ID Application" "$C/stderr"
nothing_built "2d" "$C"

# 3. uncommitted changes: the binary would not match any commit
C="$(new_case dirty)"
echo changed > "$C/repo/other.txt"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "3 a dirty tree is refused" "$RC"
assert_has "3 the refusal says the tree is not clean" "clean" "$C/stderr"
nothing_built "3" "$C"

# 3b. an untracked file counts: it can end up in the build
C="$(new_case untracked)"
echo new > "$C/repo/stray.txt"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "3b an untracked file is refused" "$RC"
nothing_built "3b" "$C"

# 3c. ... also when the maintainer's git is set to hide untracked files. SwiftPM
# compiles every .swift file in the target directory whatever git is told to show.
C="$(new_case untracked-hidden)"
(cd "$C/repo" && "$REAL_GIT" config status.showUntrackedFiles no)
echo 'let extra = 1' > "$C/repo/Sources/SafariBrowser/Extra.swift"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "3c an untracked source file is refused even with status.showUntrackedFiles=no" "$RC"
nothing_built "3c" "$C"

C="$(new_case untracked-hidden-top)"
(cd "$C/repo" && "$REAL_GIT" config status.showUntrackedFiles no)
echo stray > "$C/repo/stray.txt"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "3c an untracked top-level file is refused even with status.showUntrackedFiles=no" "$RC"
assert_has "3c the refusal is the clean-tree one" "not clean" "$C/stderr"
nothing_built "3c top-level" "$C"

# 3d. ... and when git IGNORES that file (info/exclude, global excludes, .gitignore):
# the compiler does not care what git ignores either.
C="$(new_case untracked-ignored)"
printf 'Sources/SafariBrowser/Local*.swift\n' >> "$C/repo/.git/info/exclude"
echo 'let local = 1' > "$C/repo/Sources/SafariBrowser/LocalSecret.swift"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "3d an ignored but compiled source file is refused" "$RC"
assert_has "3d the refusal names Sources" "Sources" "$C/stderr"
nothing_built "3d" "$C"

# 3f. a tracked source file git has been told not to look at (skip-worktree,
# assume-unchanged): `git status` stays clean, the edit still compiles
for FLAG in --skip-worktree --assume-unchanged; do
  C="$(new_case "hidden-edit$FLAG")"
  printf 'let a = 1\n' > "$C/repo/Sources/SafariBrowser/Tracked.swift"
  (cd "$C/repo" && "$REAL_GIT" add Sources && "$REAL_GIT" commit -q -m tracked && "$REAL_GIT" tag -d v1.2.3 >/dev/null && "$REAL_GIT" tag v1.2.3 \
     && "$REAL_GIT" update-index "$FLAG" Sources/SafariBrowser/Tracked.swift)
  printf 'let a = 2\n' > "$C/repo/Sources/SafariBrowser/Tracked.swift"
  run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
  assert_refused "3f a $FLAG source file is refused" "$RC"
  assert_has "3f the refusal names the file" "Tracked.swift" "$C/stderr"
  nothing_built "3f $FLAG" "$C"
done

# 3e. ignored files that are NOT compiled must not block a release: build products,
# and the Finder's .DS_Store inside Sources when the repo ignores it
C="$(new_case ignored-ok)"
printf '.DS_Store\n' >> "$C/repo/.gitignore"
(cd "$C/repo" && "$REAL_GIT" add .gitignore && "$REAL_GIT" commit -q -m ignore && "$REAL_GIT" tag -d v1.2.3 >/dev/null && "$REAL_GIT" tag v1.2.3)
mkdir -p "$C/repo/.build" && echo x > "$C/repo/.build/junk"
echo x > "$C/repo/Sources/SafariBrowser/.DS_Store"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_ok "3e ignored build output and .DS_Store do not block a release" "$RC"

# 4. HEAD is on no release tag, and an IDD baseline tag does not stand in for one
C="$(new_case no-tag)"
(cd "$C/repo" && "$REAL_GIT" tag -d v1.2.3 >/dev/null && "$REAL_GIT" tag idd-217-baseline)
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "4 HEAD on only an idd-*-baseline tag is refused" "$RC"
assert_has "4 the refusal says HEAD is not on a release tag" "not on a release tag" "$C/stderr"
nothing_built "4" "$C"

# 4b. ... and a baseline tag on the SAME commit as the release tag (the usual IDD state)
# must not get the release refused or renamed
C="$(new_case baseline-and-release)"
(cd "$C/repo" && "$REAL_GIT" tag idd-9-baseline)
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_ok "4b a baseline tag next to the release tag is fine" "$RC"
assert_exists "4b the output is named after the release tag" "$C/repo/dist/v1.2.3-DRYRUN/safari-browser"

# 4c. several release tags on HEAD: git would pick one silently (an annotated rc beats a
# lightweight final; v1.2.10 beats v1.2.9), so the script must refuse and say which
C="$(new_case two-tags)"
(cd "$C/repo" && "$REAL_GIT" tag -a v1.2.3-rc.1 -m rc)
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "4c two release tags on HEAD are refused" "$RC"
assert_has "4c the refusal names the first tag" "v1.2.3" "$C/stderr"
assert_has "4c the refusal names the second tag" "v1.2.3-rc.1" "$C/stderr"
assert_has "4c the refusal says there are 2 release tags" "2 release tags" "$C/stderr"
nothing_built "4c" "$C"

# 4d. a tag that would collide with the dry-run directory name
C="$(new_case dryrun-tag 'v1.2.3-DRYRUN')"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "4d a tag ending in -DRYRUN is refused" "$RC"
nothing_built "4d" "$C"

C="$(new_case dryrun-tag-lower 'v1.2.3-dryrun')"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "4d a tag ending in -dryrun (any case) is refused" "$RC"
nothing_built "4d lower-case" "$C"

# 5. the tag is an ancestor but HEAD has moved on
C="$(new_case after-tag)"
(cd "$C/repo" && echo b > other.txt && "$REAL_GIT" commit -q -am two)
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "5 a commit after the tag is refused" "$RC"
nothing_built "5" "$C"

# 5b. a tag that is not a version: its text would reach a directory name and a shell line
C="$(new_case odd-tag 'v1.2.3;touch-pwned')"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "5b a tag that is not vX.Y.Z is refused" "$RC"
nothing_built "5b" "$C"
assert_absent "5b nothing was created from the tag text" "$C/repo/touch-pwned"

# 6. a release that is going to Apple needs a secure timestamp
C="$(new_case no-ts)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" NOTARIZE=1 RELEASE_TIMESTAMP=none
assert_refused "6 NOTARIZE=1 with RELEASE_TIMESTAMP=none is refused" "$RC"
assert_has "6 the refusal says timestamp" "timestamp" "$C/stderr"
nothing_built "6" "$C"

# 7. the notary profile must answer before an 8-minute build, not after
C="$(new_case probe-fails)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" NOTARIZE=1 FAKE_NOTARY_PROBE_FAIL=1
assert_refused "7 a failing notarytool profile probe is refused" "$RC"
assert_has "7 the refusal names the profile" "che-mcps-notary" "$C/stderr"
nothing_built "7" "$C"

# 7b. knobs with a closed set of values are checked, not coerced into a default
C="$(new_case bad-notarize)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" NOTARIZE=yes
assert_refused "7b NOTARIZE other than 0 or 1 is refused" "$RC"
assert_has "7b the refusal names NOTARIZE" "NOTARIZE must be" "$C/stderr"
nothing_built "7b" "$C"

C="$(new_case bad-timestamp)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" RELEASE_TIMESTAMP=bogus
assert_refused "7c RELEASE_TIMESTAMP other than empty or none is refused" "$RC"
assert_has "7c the refusal names RELEASE_TIMESTAMP" "RELEASE_TIMESTAMP must be" "$C/stderr"
nothing_built "7c" "$C"

# 7d. git describe walks up into parent repositories, so only the repository root is allowed
C="$(new_case subdir)"
RUN_SUBDIR=Sources run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "7d running from a subdirectory is refused" "$RC"
assert_has "7d the refusal says repository root" "repository root" "$C/stderr"
nothing_built "7d" "$C"

# 7e. what the signing step needs is checked before the build, not after it
C="$(new_case no-entitlements)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" ENTITLEMENTS="$C/nowhere.plist"
assert_refused "7e a missing entitlements file is refused" "$RC"
assert_has "7e the refusal names the entitlements file" "entitlements file not found" "$C/stderr"
nothing_built "7e" "$C"

C="$(new_case no-guard)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" VERIFY_BIN="$C/nowhere"
assert_refused "7f a missing install-signature guard is refused" "$RC"
assert_has "7f the refusal names the guard" "install-signature guard" "$C/stderr"
nothing_built "7f" "$C"

# 7g. the output directory is a symlink: the result would land outside the repository
C="$(new_case dist-symlink)"
mkdir -p "$C/elsewhere" && ln -s "$C/elsewhere" "$C/repo/dist"
(cd "$C/repo" && "$REAL_GIT" add dist && "$REAL_GIT" commit -q -m link && "$REAL_GIT" tag -d v1.2.3 >/dev/null && "$REAL_GIT" tag v1.2.3)
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "7g a symlinked dist directory is refused" "$RC"
assert_has "7g the refusal says symlink" "symlink" "$C/stderr"
nothing_built "7g" "$C"
assert_eq "7g nothing was written through the symlink" "" "$(ls -A "$C/elsewhere")"

C="$(new_case dist-symlink-slash)"
mkdir -p "$C/elsewhere" && ln -s "$C/elsewhere" "$C/repo/dist"
(cd "$C/repo" && "$REAL_GIT" add dist && "$REAL_GIT" commit -q -m link && "$REAL_GIT" tag -d v1.2.3 >/dev/null && "$REAL_GIT" tag v1.2.3)
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" DIST_DIR=dist/
assert_refused "7g a symlinked dist directory written as dist/ is refused" "$RC"
assert_eq "7g nothing was written through the symlink (dist/)" "" "$(ls -A "$C/elsewhere")"

# --- the dry run (NOTARIZE defaults to 0) ----------------------------------------

C="$(new_case dry)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_ok "8 a dry run succeeds" "$RC"
D="$C/repo/dist/v1.2.3-DRYRUN"
assert_exists "8 the dry-run directory is named as one" "$D/safari-browser"
assert_exists "8 the dry-run directory carries its marker" "$D/DRYRUN-NOT-NOTARIZED"
assert_absent "8 no release directory exists" "$C/repo/dist/v1.2.3"
assert_absent "8 no NOTARIZATION.json" "$D/NOTARIZATION.json"
assert_lacks "8 notarytool was never invoked (no probe, no submit)" "xcrun notarytool" "$C/calls.log"
assert_eq "8 the build was a release build" "release" "$(cat "$C/products/build-config" 2>/dev/null)"
assert_eq "8 the build asked for both architectures" "arm64 x86_64" "$(cat "$C/products/archs" 2>/dev/null)"
assert_has "8 the submission zip is built in a dry run too" "ditto -c -k --norsrc --noextattr" "$C/calls.log"
assert_has "8 codesign got the hardened runtime" "--options runtime" "$C/calls.log"
grep -Eq -- '^codesign .*--timestamp( |$)' "$C/calls.log" \
  && ok "8 codesign got a secure timestamp (not --timestamp=none)" || fail "8 codesign got a secure timestamp (not --timestamp=none)" "$(grep '^codesign --force' "$C/calls.log")"
assert_has "8 codesign got the identity" "--sign $FAKE_ID" "$C/calls.log"
assert_has "8 codesign got the entitlements file" "--entitlements" "$C/calls.log"
assert_has "8 the shipped binary is the signed one" "# SIGNED" "$D/safari-browser"
assert_has "8 the verifier required the Developer ID shape" "--require-shape Developer ID" "$C/calls.log"
assert_has "8 the verifier required the apple-events entitlement" "--require-entitlement $ENT_KEY" "$C/calls.log"
assert_eq "8 the shipped binary reports the tag" "v1.2.3" "$("$D/safari-browser" --version)"
# the final message must not claim that nothing reaches Apple: --timestamp contacts its server
assert_lacks "8 the dry run does not say nothing was sent to Apple" "nothing was sent to Apple" "$C/stdout"
assert_has "8 the dry run says nothing was submitted for notarization" "submitted for notarization" "$C/stdout"
assert_eq "8 dist/ holds only the output directory" "v1.2.3-DRYRUN" "$(ls -A "$C/repo/dist")"

# 9. the checksum file holds the hash and nothing else
# (an absent file would make both sides empty and "equal", so it has to exist first)
if [ -f "$D/safari-browser" ] && [ -f "$D/safari-browser.sha256" ]; then
  assert_eq "9 the checksum is the sha256 of the shipped binary, alone" "$(/usr/bin/shasum -a 256 < "$D/safari-browser" | awk '{print $1}')" "$(cat "$D/safari-browser.sha256")"
  assert_eq "9 the checksum file is one line" "1" "$(wc -l < "$D/safari-browser.sha256" | tr -d ' ')"
else
  fail "9 the checksum is the sha256 of the shipped binary, alone" "binary or checksum file missing in $D"
  fail "9 the checksum file is one line" "binary or checksum file missing in $D"
fi

# 9b. a checksum that could not be computed must not become an empty .sha256
C="$(new_case shasum-fails)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" FAKE_SHASUM_FAIL=1
assert_refused "9b a failing shasum is refused" "$RC"
no_artifacts "$C" && ok "9b no artifacts were left" || fail "9b no artifacts were left" "$(ls -A "$C/repo/dist")"

C="$(new_case shasum-garbage)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" FAKE_SHASUM_GARBAGE=1
assert_refused "9d a shasum that prints no SHA-256 is refused" "$RC"
no_artifacts "$C" && ok "9d no artifacts were left" || fail "9d no artifacts were left" "$(ls -A "$C/repo/dist")"

C="$(new_case shasum-late)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" FAKE_SHASUM_LATE_FAIL=1
assert_refused "9e a shasum that prints a hash and then fails is refused" "$RC"
no_artifacts "$C" && ok "9e no artifacts were left" || fail "9e no artifacts were left" "$(ls -A "$C/repo/dist")"

# 9f. the final move into the reserved directory fails
C="$(new_case move-fails)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" FAKE_LOCK_OUT=dist/v1.2.3-DRYRUN
chmod 755 "$C/repo/dist/v1.2.3-DRYRUN" 2>/dev/null
assert_refused "9f a failed move into the output directory is refused" "$RC"
assert_lacks "9f no success line was printed" "✓" "$C/stdout"

# 9g. the dry-run marker cannot be written: the rehearsal must not be published unmarked
C="$(new_case marker-fails)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" FAKE_LOCK_STAGE=1
for d in "$C"/repo/dist/.staging.*; do [ -d "$d" ] && chmod 755 "$d"; done
assert_refused "9g a dry-run marker that cannot be written is refused" "$RC"
assert_has "9g the refusal names the marker" "dry-run marker" "$C/stderr"
assert_absent "9g no unmarked rehearsal binary was published" "$C/repo/dist/v1.2.3-DRYRUN/safari-browser"
# the same lock keeps the cleanup from removing the staging directory, which still holds
# a signed binary: that must be said, not left for the maintainer to stumble on
assert_has "9g a staging directory that could not be removed is reported" "could not remove" "$C/stderr"

# 9h. the notarization record cannot be written after an Accepted answer
C="$(new_case record-fails)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" NOTARIZE=1 FAKE_LOCK_STAGE=1
for d in "$C"/repo/dist/.staging.*; do [ -d "$d" ] && chmod 755 "$d"; done
assert_refused "9h a notarization record that cannot be written is refused" "$RC"
assert_has "9h the refusal names the record" "notarization result" "$C/stderr"
assert_absent "9h no release was published without its record" "$C/repo/dist/v1.2.3/safari-browser"
# Apple accepted it, so where to find that submission must survive the failure
assert_has "9h the accepted submission id is still on screen" "11111111-2222-3333-4444-555555555555" "$C/stdout"

# 9i. the checksum file cannot be written (the hash itself was computed)
C="$(new_case sha256-write-fails)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" FAKE_SHASUM_LOCK_STAGE=1
for d in "$C"/repo/dist/.staging.*; do [ -d "$d" ] && chmod 755 "$d"; done
assert_refused "9i a checksum file that cannot be written is refused" "$RC"
assert_has "9i the refusal names the checksum" "could not write the checksum" "$C/stderr"
assert_absent "9i no release was published without its checksum" "$C/repo/dist/v1.2.3-DRYRUN/safari-browser"

# 9c. a zip that could not be built is refused in a dry run too (it is rehearsed there)
C="$(new_case ditto-fails)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" FAKE_DITTO_FAIL=1
assert_refused "9c a failing ditto is refused, in a dry run" "$RC"
no_artifacts "$C" && ok "9c no artifacts were left" || fail "9c no artifacts were left" "$(ls -A "$C/repo/dist")"

# 10. both sides of the stamping contract: the tree is untouched afterwards
tree_clean "$C" && ok "10 the tree is clean after a failed run" || fail "10 the tree is clean after a failed run"
C="$TMPROOT/dry"
tree_clean "$C" && ok "10 the tree is clean after a successful run" || fail "10 the tree is clean after a successful run" "$(cd "$C/repo" && "$REAL_GIT" status --porcelain)"
placeholder_back "$C" && ok "10 the placeholder is back after a successful run" || fail "10 the placeholder is back after a successful run"

# 11. an existing output directory is never overwritten
D="$C/repo/dist/v1.2.3-DRYRUN"
BEFORE="$(/usr/bin/shasum -a 256 < "$D/safari-browser" 2>/dev/null)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "11 a second run into the same directory is refused" "$RC"
if [ -n "$BEFORE" ]; then
  assert_eq "11 the first run's binary is untouched" "$BEFORE" "$(/usr/bin/shasum -a 256 < "$D/safari-browser")"
else
  fail "11 the first run's binary is untouched" "there was no first run's binary to compare"
fi

# 11b. the output name is RESERVED before the build (an atomic mkdir), so a second run
# of the same tag is refused at its own preflight and the final move cannot nest the
# result inside a directory that appeared meanwhile
C="$(new_case reserve)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" FAKE_EXPECT_OUT=dist/v1.2.3-DRYRUN
assert_ok "11b a dry run with the output expected during the build succeeds" "$RC"
assert_has "11b the output directory already existed while the build ran" "out-reserved" "$C/calls.log"
assert_lacks "11b it was not created only afterwards" "out-not-reserved" "$C/calls.log"
assert_eq "11b the result is at the top level, nothing nested" "DRYRUN-NOT-NOTARIZED
safari-browser
safari-browser.sha256" "$(ls -A "$C/repo/dist/v1.2.3-DRYRUN")"

# 11c. an EMPTY directory that is already there is not ours to reuse or delete
C="$(new_case occupied)"
mkdir -p "$C/repo/dist/v1.2.3-DRYRUN"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID"
assert_refused "11c an existing empty output directory is refused" "$RC"
nothing_built "11c" "$C"
assert_exists "11c the directory that was already there is left alone" "$C/repo/dist/v1.2.3-DRYRUN"

# 11d. a TERM that arrives while the result is being moved into place: bash runs the
# trap only after `mv` returns, and the cleanup used to see the output directory as
# still reserved and delete the finished result. The signal is honoured (the run ends
# with 143), but what was moved stays.
C="$(new_case move-signal)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" FAKE_MV_SIGNAL=1
assert_eq "11d a TERM during the final move still ends the run with 143" "143" "$RC"
assert_exists "11d the moved binary is kept" "$C/repo/dist/v1.2.3-DRYRUN/safari-browser"
assert_exists "11d the moved checksum is kept" "$C/repo/dist/v1.2.3-DRYRUN/safari-browser.sha256"
assert_exists "11d the moved marker is kept" "$C/repo/dist/v1.2.3-DRYRUN/DRYRUN-NOT-NOTARIZED"
assert_eq "11d no staging directory is left" "v1.2.3-DRYRUN" "$(ls -A "$C/repo/dist")"

# 12. RELEASE_TIMESTAMP=none exists for an offline dry run and nothing else
C="$(new_case offline)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" RELEASE_TIMESTAMP=none
assert_ok "12 an offline dry run succeeds" "$RC"
assert_has "12 codesign got --timestamp=none" "--timestamp=none" "$C/calls.log"

# --- failures after the build leave nothing behind --------------------------------

# 13. a Universal build that is missing a slice, either one
C="$(new_case one-slice)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" FAKE_BUILD_ARCHS="arm64"
assert_refused "13 a missing x86_64 slice is refused" "$RC"
assert_has "13 the refusal names the missing slice" "x86_64" "$C/stderr"
no_artifacts "$C" && ok "13 no artifacts were left" || fail "13 no artifacts were left" "$(ls -A "$C/repo/dist")"
tree_clean "$C" && ok "13 the tree is clean after a failure" || fail "13 the tree is clean after a failure"
placeholder_back "$C" && ok "13 the placeholder is back after a failure" || fail "13 the placeholder is back after a failure"

C="$(new_case other-slice)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" FAKE_BUILD_ARCHS="x86_64"
assert_refused "13b a missing arm64 slice is refused" "$RC"
assert_has "13b the refusal names the missing slice" "arm64" "$C/stderr"
no_artifacts "$C" && ok "13b no artifacts were left" || fail "13b no artifacts were left"

# 13c. a failed build must not be papered over by a stale product from an earlier build
C="$(new_case stale-product)"
mkdir -p "$C/products"
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo v1.2.3; fi\n' > "$C/products/safari-browser"
chmod +x "$C/products/safari-browser"
printf 'arm64 x86_64\n' > "$C/products/archs"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" FAKE_BUILD_FAIL=1
assert_refused "13c a failed build with a stale product around is refused" "$RC"
assert_has "13c the refusal says the build failed" "build failed" "$C/stderr"
no_artifacts "$C" && ok "13c no artifacts were left" || fail "13c no artifacts were left" "$(ls -A "$C/repo/dist")"
assert_lacks "13c nothing was signed" "codesign --force" "$C/calls.log"

# 14. the binary says something other than the tag (a stamp that did not take)
C="$(new_case wrong-version)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" FAKE_BAKE_VERSION=unknown
assert_refused "14 a binary that does not report the tag is refused" "$RC"
assert_has "14 the refusal shows what it reported" "unknown" "$C/stderr"
no_artifacts "$C" && ok "14 no artifacts were left" || fail "14 no artifacts were left"

# 14b. ... or prints the tag and then fails
C="$(new_case version-fails)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" FAKE_VERSION_RC=1
assert_refused "14b a binary whose --version exits non-zero is refused" "$RC"
no_artifacts "$C" && ok "14b no artifacts were left" || fail "14b no artifacts were left"

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
"$REAL_GIT" -C "$C/repo" remote add origin https://github.com/example-owner/example-repo.git
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" NOTARIZE=1
assert_ok "17 an accepted submission succeeds" "$RC"
assert_has "17 the accepted submission id is printed" "11111111-2222-3333-4444-555555555555" "$C/stdout"
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
grep -Eq '^xcrun notarytool submit .*--output-format json' "$C/calls.log" \
  && ok "17 submit asks for json" || fail "17 submit asks for json" "$(grep '^xcrun notarytool submit' "$C/calls.log")"
assert_has "17 the zip held exactly the signed binary" "zip-ok" "$C/calls.log"
SIGN_AT="$(line_of "$C/calls.log" '^codesign --force')"
VERIFY_AT="$(line_of "$C/calls.log" '^verify ')"
SUBMIT_AT="$(line_of "$C/calls.log" '^xcrun notarytool submit')"
if [ "$SIGN_AT" -gt 0 ] && [ "$VERIFY_AT" -gt "$SIGN_AT" ] && [ "$SUBMIT_AT" -gt "$VERIFY_AT" ]; then
  ok "17 order is sign, then verify, then submit"
else
  fail "17 order is sign, then verify, then submit" "sign=$SIGN_AT verify=$VERIFY_AT submit=$SUBMIT_AT"
fi
assert_eq "17 dist/ holds only the output directory" "v1.2.3" "$(ls -A "$C/repo/dist")"
NOTARIZED_CASE="$C"

# 17b. an accepted-looking JSON with a failing exit code is not an acceptance
C="$(new_case notary-rc)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" NOTARIZE=1 FAKE_NOTARY_RC=3
assert_refused "17b a non-zero notarytool exit is refused even if the JSON says Accepted" "$RC"
no_artifacts "$C" && ok "17b no artifacts were left" || fail "17b no artifacts were left" "$(ls -A "$C/repo/dist")"

# 17c. an empty answer is not an acceptance either
C="$(new_case notary-empty)"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" NOTARIZE=1 FAKE_NOTARY_EMPTY=1
assert_refused "17c an empty notarytool answer is refused" "$RC"
no_artifacts "$C" && ok "17c no artifacts were left" || fail "17c no artifacts were left" "$(ls -A "$C/repo/dist")"

# 18. the script prints the outward commands and does not run them. The git shim and
# the per-run check refuse a push, a tag creation or any gh call in ANY run; the
# assertion for that is at the end of this file, over every run.
C="$NOTARIZED_CASE"
COMMIT="$("$REAL_GIT" -C "$C/repo" rev-parse 'v1.2.3^{commit}')"
assert_has "18 it tells the user how to push the tag" "git push origin v1.2.3" "$C/stdout"
assert_has "18 it tells the user how to see what the remote has" "git ls-remote origin 'refs/tags/v1.2.3' 'refs/tags/v1.2.3^{}'" "$C/stdout"
assert_has "18 it prints the commit the tag must show" "$COMMIT" "$C/stdout"
assert_has "18 it tells the user how to create the release" "gh release create v1.2.3" "$C/stdout"
grep -E '^  gh release create ' "$C/stdout" | grep -q -- '--verify-tag' \
  && ok "18 the printed gh line has --verify-tag" || fail "18 the printed gh line has --verify-tag" "$(grep 'gh release create' "$C/stdout")"
assert_lacks "18 it does not invite skipping the push" "skip if" "$C/stdout"
assert_lacks "18 a final release is not marked prerelease" "--prerelease" "$C/stdout"
grep -E '^  gh release create ' "$C/stdout" | grep -q -- '--notes' \
  && ok "18 the printed gh line carries release notes" || fail "18 the printed gh line carries release notes" "$(grep 'gh release create' "$C/stdout")"
grep -E '^  gh release create ' "$C/stdout" | grep -q 'ABCDE12345' \
  && ok "18 the notes name the signing team ID" || fail "18 the notes name the signing team ID" "$(grep 'gh release create' "$C/stdout")"
grep -E '^  gh release create ' "$C/stdout" | grep -q -- '--repo example-owner/example-repo' \
  && ok "18 the gh line names the repository origin points at" || fail "18 the gh line names the repository origin points at" "$(grep 'gh release create' "$C/stdout")"
# zsh without interactivecomments passes a trailing `# ...` as arguments, so no printed
# command may carry one; what a command must show is said on its own line instead
assert_eq "18 no printed command carries a trailing # comment" "0" "$(grep -E '^  (git|gh|shasum) ' "$C/stdout" | grep -c '#')"
HASH_PRINTED="$(cat "$C/repo/dist/v1.2.3/safari-browser.sha256" 2>/dev/null)"
grep -Eq '^  shasum -a 256 ' "$C/stdout" \
  && ok "18 it prints a checksum command to run before uploading" || fail "18 it prints a checksum command to run before uploading" "$(cat "$C/stdout")"
assert_has "18 it prints the hash that command must show" "$HASH_PRINTED" "$C/stdout"

C="$(new_case annotated 'v3.0.0')"
(cd "$C/repo" && "$REAL_GIT" tag -d v3.0.0 >/dev/null && "$REAL_GIT" tag -a v3.0.0 -m release)
"$REAL_GIT" -C "$C/repo" remote add origin https://notgithub.com/x/y.git
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" NOTARIZE=1
assert_ok "18a a notarized run of an annotated tag succeeds" "$RC"
grep -E '^  gh release create ' "$C/stdout" | grep -q -- '--repo' \
  && fail "18a a host that only ends in github.com is not taken for GitHub" "$(grep 'gh release create' "$C/stdout")" || ok "18a a host that only ends in github.com is not taken for GitHub"
TAG_COMMIT="$("$REAL_GIT" -C "$C/repo" rev-parse 'v3.0.0^{commit}')"
TAG_OBJECT="$("$REAL_GIT" -C "$C/repo" rev-parse v3.0.0)"
assert_has "18a the commit it prints is the tagged commit" "$TAG_COMMIT" "$C/stdout"
assert_lacks "18a it does not print the tag object as the commit" "$TAG_OBJECT" "$C/stdout"
LS_LINE="$(grep -E '^  git ls-remote ' "$C/stdout" | head -1 | sed 's/#.*$//')"
LS_ARGS="$(bash -c 'git() { for a in "$@"; do printf "ARG:%s\n" "$a"; done; }; '"$LS_LINE")"
case "$LS_ARGS" in
  *"ARG:refs/tags/v3.0.0^{}"*) ok "18a the ls-remote line asks for the peeled ref" ;;
  *) fail "18a the ls-remote line asks for the peeled ref" "$LS_LINE -> $LS_ARGS" ;;
esac

# 18b. a prerelease tag is published as a prerelease
C="$(new_case rc-tag 'v2.0.0-rc.1')"
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" NOTARIZE=1
assert_ok "18b a notarized run of a prerelease tag succeeds" "$RC"
assert_has "18b the printed gh line says --prerelease" "--prerelease" "$C/stdout"
# this fixture has no origin: the gh line cannot name a repository and says so
grep -E '^  gh release create ' "$C/stdout" | grep -q -- '--repo' \
  && fail "18b without a GitHub origin the gh line has no --repo" "$(grep 'gh release create' "$C/stdout")" || ok "18b without a GitHub origin the gh line has no --repo"
assert_has "18b without a GitHub origin it says to add --repo" "add --repo" "$C/stdout"

# 18c. the printed gh line survives a hostile DIST_DIR: pasted into a shell it must not
# run anything. Executed here with `gh` as a function that prints its arguments.
C="$(new_case hostile-dist)"
WEIRD="d'\$(touch PWNED)"
"$REAL_GIT" -C "$C/repo" remote add origin git@github.com:owner2/repo2.git
run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" NOTARIZE=1 "DIST_DIR=$WEIRD"
assert_ok "18c a notarized run with an odd DIST_DIR succeeds" "$RC"
GH_LINE="$(grep '^  gh release create' "$C/stdout" | head -1)"
mkdir -p "$C/sandbox"
PRINTED="$(cd "$C/sandbox" && bash -c 'gh() { for a in "$@"; do printf "ARG:%s\n" "$a"; done; }; '"$GH_LINE")"
assert_absent "18c pasting the printed line ran nothing" "$C/sandbox/PWNED"
assert_has "18c the printed path argument is the literal output path" "ARG:$WEIRD/v1.2.3/safari-browser" <(printf '%s\n' "$PRINTED")
case "$PRINTED" in
  *"ARG:--repo"$'\n'"ARG:owner2/repo2"*) ok "18c an ssh-style origin becomes --repo owner/name" ;;
  *) fail "18c an ssh-style origin becomes --repo owner/name" "$PRINTED" ;;
esac

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

# 20b. SIGQUIT (Ctrl-\) runs the cleanup too: bash 3.2 does not run an EXIT trap for a
# signal that has no trap of its own. The signal is delivered during the build; the
# script exits after its foreground child, with 131, and leaves nothing behind.
C="$(new_case sigquit)"
RUN_ASYNC=1 run_release "$C" DEVELOPER_ID="$FAKE_ID" FAKE_IDENTITIES="$FAKE_ID" FAKE_BUILD_SLEEP=2
for _ in $(seq 1 100); do grep -q '^swift build' "$C/calls.log" 2>/dev/null && break; sleep 0.1; done
kill -QUIT "$ASYNC_PID" 2>/dev/null
wait "$ASYNC_PID"; QRC=$?
assert_eq "20b the script exits 131 on SIGQUIT" "131" "$QRC"
post_run_checks "$C"
assert_eq "20b no staging directory was left behind" "" "$(ls -A "$C/repo/dist" 2>/dev/null)"
placeholder_back "$C" && ok "20b the placeholder is back" || fail "20b the placeholder is back"

# --- every run, not just the one that happens to notarize -------------------------

assert_eq "18 across all $CASES_RUN runs: no git write (push, tag creation, ...) and no gh call" "" "$FORBIDDEN_HITS"
assert_eq "no run left anything in its private TMPDIR (zip directory, backups)" "" "$LEAKED"

# --- wiring in the repository itself ---------------------------------------------

# MAKEFLAGS / MFLAGS / MAKELEVEL go too: run from `make test-all NOTARIZE=1`, the outer
# make passes NOTARIZE=1 down through MAKEFLAGS, and `env -u NOTARIZE` does not touch it.
MAKE_ENV=(env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL)
MAKE_OUT="$(cd "$REPO_ROOT" && "${MAKE_ENV[@]}" -u NOTARIZE -u ENTITLEMENTS -u DIST_DIR make -n release-signed DEVELOPER_ID=x 2>&1)"
case "$MAKE_OUT" in
  *scripts/release.sh*) ok "21 make release-signed runs scripts/release.sh" ;;
  *) fail "21 make release-signed runs scripts/release.sh" "$(printf '%s' "$MAKE_OUT" | head -c 400)" ;;
esac
case "$MAKE_OUT" in
  *'NOTARIZE="0"'*) ok "21 NOTARIZE defaults to 0 (typing the target by accident submits nothing)" ;;
  *) fail "21 NOTARIZE defaults to 0" "$(printf '%s' "$MAKE_OUT" | head -c 400)" ;;
esac
case "$MAKE_OUT" in
  *"-u ENTITLEMENTS"*"-u DIST_DIR"*|*"-u DIST_DIR"*"-u ENTITLEMENTS"*) ok "21 the recipe strips ambient ENTITLEMENTS and DIST_DIR" ;;
  *) fail "21 the recipe strips ambient ENTITLEMENTS and DIST_DIR" "$(printf '%s' "$MAKE_OUT" | head -c 400)" ;;
esac
case "$MAKE_OUT" in
  *"-u BINARY_NAME"*) ok "21 the recipe strips an ambient BINARY_NAME" ;;
  *) fail "21 the recipe strips an ambient BINARY_NAME" "$(printf '%s' "$MAKE_OUT" | head -c 400)" ;;
esac
# the documented one-shot form must keep working: make sees NOTARIZE as an environment variable
MAKE_ONE="$(cd "$REPO_ROOT" && "${MAKE_ENV[@]}" NOTARIZE=1 make -n release-signed DEVELOPER_ID=x 2>&1)"
case "$MAKE_ONE" in
  *'NOTARIZE="1"'*) ok "21 DEVELOPER_ID=<sha1> NOTARIZE=1 make release-signed reaches the script" ;;
  *) fail "21 NOTARIZE=1 in the environment reaches the script" "$(printf '%s' "$MAKE_ONE" | head -c 400)" ;;
esac
grep -Eq '^test-all:.*test-release' "$REPO_ROOT/Makefile" \
  && ok "22 test-all includes test-release" || fail "22 test-all includes test-release"
grep -Eq '^	/bin/bash scripts/release-test.sh' "$REPO_ROOT/Makefile" \
  && ok "22 make test-release runs the suite under /bin/bash (the bash release.sh runs under)" || fail "22 make test-release runs the suite under /bin/bash"

# 23 needs this tree to be a git checkout; a source archive has no .git (the same case
# Tests/repository-tracking-test.py skips on purpose)
if [ "$("$REAL_GIT" -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null)" = "$REPO_ROOT" ]; then
  "$REAL_GIT" -C "$REPO_ROOT" check-ignore -q dist/v1.0.0/safari-browser \
    && ok "23 dist/ is gitignored" || fail "23 dist/ is gitignored"
  "$REAL_GIT" -C "$REPO_ROOT" check-ignore -q Sources/SafariBrowser/dist/x \
    && fail "23 only the top-level dist/ is ignored (a nested dist/ must stay visible)" || ok "23 only the top-level dist/ is ignored"
else
  skip "23 dist/ is gitignored (not a git checkout)"
fi

# 24. wording that was wrong and must not come back: the default dry run DOES contact
# Apple's timestamp server (codesign --timestamp), so it must not be said to send nothing
BAD_PHRASES='nothing leaves the Mac|nothing is sent to Apple|nothing was sent to Apple|不會送任何東西|refuses every write'
HITS="$(cd "$REPO_ROOT" && grep -nEi "$BAD_PHRASES" README.md docs/release.md CHANGELOG.md CLAUDE.md Makefile scripts/release.sh 2>/dev/null | grep -v '^scripts/release-test.sh' | head -5)"
assert_eq "24 no document claims that a dry run sends nothing to Apple" "" "$HITS"
# ... and the round-2 siblings of that claim: an offline rehearsal still lets the system
# check certificates (unmeasured, so not claimed either way), and a rehearsal binary IS a
# valid Developer ID binary, distinguishable only by its directory name and marker
BAD_PHRASES_2='never contacts Apple|完全離線|cannot be mistaken|ties the file to your Developer ID|ties the file to the signing team'
HITS="$(cd "$REPO_ROOT" && grep -nEi "$BAD_PHRASES_2" README.md docs/release.md CHANGELOG.md CLAUDE.md Makefile scripts/release.sh 2>/dev/null | head -5)"
assert_eq "24 no document overclaims what an offline rehearsal or the download check proves" "" "$HITS"

# 25. the git shim itself: an allowlist, so a writing subcommand cannot hide behind an
# option it does not know (round-2 review: `--config-env k=V push` used to get through)
# Run inside a throwaway repository: if the shim ever let one of these through, real git
# would act on whatever repository the calls run in. Only exit 99 counts as a refusal,
# so a real git failure (no remote, no such branch) cannot pass for one.
SHIMDIR="$TMPROOT/shim-direct"; make_shims "$SHIMDIR"
SHIMREPO="$TMPROOT/shim-repo"; new_repo "$SHIMREPO"
shim_refuses() { # name args...
  local name="$1"; shift
  (cd "$SHIMREPO" && FAKE_LOG=/dev/null REAL_GIT="$REAL_GIT" "$SHIMDIR/git" "$@" >/dev/null 2>&1)
  local rc=$?
  if [ "$rc" -eq 99 ]; then ok "25 the git shim refuses: $name"; else fail "25 the git shim refuses: $name" "exit $rc"; fi
}
shim_refuses "push hidden behind --config-env" --config-env core.pager=HOME push origin v1
shim_refuses "branch deletion" branch -D main
shim_refuses "update-index" update-index --assume-unchanged x
shim_refuses "clean" clean -fdx
shim_refuses "tag creation" tag v9.9.9
shim_refuses "tag deletion" tag -d v9.9.9
shim_refuses "remote add" remote add x y
(cd "$SHIMREPO" && FAKE_LOG=/dev/null REAL_GIT="$REAL_GIT" "$SHIMDIR/git" tag --points-at HEAD --list 'v[0-9]*' >/dev/null 2>&1) \
  && ok "25 the git shim lets the script's own tag listing through" || fail "25 the git shim lets the script's own tag listing through"
assert_eq "25 no tag was created in the throwaway repository" "v1.2.3" "$("$REAL_GIT" -C "$SHIMREPO" tag --list)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
