#!/bin/bash
# Build, sign and (optionally) notarize the release binary (#280).
#
# usage: DEVELOPER_ID=<cert sha-1> [NOTARIZE=1] scripts/release.sh   (from the repo root)
#
# Output is dist/<tag>/ : the signed binary, its sha256 (the hash alone, one line) and
# NOTARIZATION.json (notarytool's JSON answer). Without NOTARIZE=1 nothing is submitted
# for notarization and the output is dist/<tag>-DRYRUN/ with a DRYRUN-NOT-NOTARIZED
# marker, so a rehearsal cannot be mistaken for, or block, the real thing. (A rehearsal
# still signs with `--timestamp`, which sends the signature's hash to Apple's timestamp
# server; RELEASE_TIMESTAMP=none avoids that for an offline run.)
#
# This script never creates or pushes a tag and never calls gh. Publishing is the
# maintainer's act; the commands are printed at the end. scripts/release-test.sh checks
# every run for a git write or a gh call.
#
# Why the checks are shaped the way they are:
#   - Every refusal happens before the build. A Universal build is minutes and a
#     notarization is more, so a missing identity, a dirty tree or a dead notary
#     profile must cost seconds.
#   - The identity must be the 40-hex SHA-1 of a valid Developer ID Application
#     certificate, matched on its own line of `security find-identity -v`. A substring
#     match let `0` or `valid` through with an empty keychain.
#   - "Clean tree" means: nothing untracked anywhere (`--untracked-files=all`, so
#     status.showUntrackedFiles cannot hide it) AND nothing untracked under Sources/ or
#     Package.swift even if git ignores it: SwiftPM compiles every .swift file in the
#     target, whatever git is told to show.
#   - HEAD must carry exactly ONE `v[0-9]*` tag (the same selector as stamp-version.sh,
#     so `idd-217-baseline` cannot stand in). With several, `git describe` picks one
#     (an annotated rc beats a lightweight final; v1.2.10 beats v1.2.9) and so does the
#     stamp, so the run would build and print publish commands for the wrong tag. The
#     tag must look like vX.Y.Z: the text becomes a directory name and is printed in
#     commands for the maintainer to run.
#   - The binary must report the tag itself. A stamp that did not take reports
#     `unknown`, and a release that cannot say what it is defeats #278.
#   - `--timestamp` is what separates this from `make install-signed`: Apple refuses a
#     binary without a secure timestamp. `RELEASE_TIMESTAMP=none` exists for offline
#     rehearsals only and is refused together with NOTARIZE=1.
#   - Only the status `Accepted` passes. notarytool's exit code is not trusted to mean
#     "accepted" (an Invalid verdict is a completed submission), and a zero exit with an
#     unreadable answer is not trusted either, so the JSON is read.
#   - The output name is RESERVED with an atomic mkdir before the build, and the result
#     is staged next to it and moved in at the end. Checking that the name is free and
#     moving onto it minutes later left a window in which `mv` would nest the result
#     inside a directory that had appeared meanwhile.
#   - The zip sent to Apple is a submission container, not a deliverable (a bare Mach-O
#     is not expected to take a stapled ticket; see docs/release.md). It is built in a
#     rehearsal too, so a ditto or TMPDIR problem shows up before the real run.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY_NAME="${BINARY_NAME:-safari-browser}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-che-mcps-notary}"
RELEASE_TIMESTAMP="${RELEASE_TIMESTAMP:-}"
DIST_DIR="${DIST_DIR:-dist}"
while [ "${#DIST_DIR}" -gt 1 ] && [ "${DIST_DIR%/}" != "$DIST_DIR" ]; do DIST_DIR="${DIST_DIR%/}"; done
ENTITLEMENTS="${ENTITLEMENTS:-Sources/SafariBrowser/Entitlements.plist}"
VERIFY_BIN="${VERIFY_BIN:-.build/verify-install-signature}"
VERSION_FILE="Sources/SafariBrowser/BuildVersion.swift"
ENTITLEMENT_KEY="com.apple.security.automation.apple-events"

die() { echo "release: $*" >&2; exit 1; }

STAGE=""
ZIPDIR=""
OUT=""
OUT_RESERVED=0   # 1 only once THIS run created $OUT with mkdir: a directory we did not create is never removed
cleanup() {
  [ -n "$STAGE" ] && rm -rf "$STAGE"
  [ -n "$ZIPDIR" ] && rm -rf "$ZIPDIR"
  [ "$OUT_RESERVED" = 1 ] && [ -n "$OUT" ] && rm -rf "$OUT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 131' QUIT   # bash 3.2 does not run the EXIT trap for a signal that has no trap of its own
trap 'exit 143' TERM
trap 'exit 129' HUP

# --- preflight --------------------------------------------------------------------

[ -n "${DEVELOPER_ID:-}" ] \
  || die "DEVELOPER_ID is unset. Name the Developer ID Application certificate (its SHA-1)."
[[ "$DEVELOPER_ID" =~ ^[0-9A-Fa-f]{40}$ ]] \
  || die "DEVELOPER_ID must be the 40-hex SHA-1 of the certificate (security find-identity -v -p codesigning), got '$DEVELOPER_ID'."
case "$NOTARIZE" in 0|1) ;; *) die "NOTARIZE must be 0 or 1 (got '$NOTARIZE')" ;; esac
case "$RELEASE_TIMESTAMP" in
  ""|none) ;;
  *) die "RELEASE_TIMESTAMP must be empty or 'none' (got '$RELEASE_TIMESTAMP')" ;;
esac
if [ "$NOTARIZE" = 1 ] && [ "$RELEASE_TIMESTAMP" = none ]; then
  die "NOTARIZE=1 needs a secure timestamp; RELEASE_TIMESTAMP=none is for offline rehearsals only."
fi

IDENTITIES="$(security find-identity -v -p codesigning 2>&1)" \
  || die "could not list code-signing identities: $IDENTITIES"
IDENTITY_LINE="$(printf '%s\n' "$IDENTITIES" | grep -Ei "^[[:space:]]*[0-9]+\)[[:space:]]+${DEVELOPER_ID}[[:space:]]" | head -1)"
[ -n "$IDENTITY_LINE" ] \
  || die "DEVELOPER_ID '$DEVELOPER_ID' is not a valid identity in the keychain."
case "$IDENTITY_LINE" in
  *'"Developer ID Application:'*) ;;
  *) die "identity $DEVELOPER_ID is not a \"Developer ID Application\" certificate: $IDENTITY_LINE" ;;
esac
TEAM_SHAPE='\(([A-Z0-9]{10})\)"[[:space:]]*$'
[[ "$IDENTITY_LINE" =~ $TEAM_SHAPE ]] || die "could not read the team ID from the identity: $IDENTITY_LINE"
TEAM_ID="${BASH_REMATCH[1]}"

# Same rule as stamp-version.sh: the repository root, or `git describe` may walk up
# into some other repository and produce a tag that is not ours.
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" && TOP="$(cd "$TOP" 2>/dev/null && pwd -P)"
[ -n "${TOP:-}" ] && [ "$TOP" = "$(pwd -P)" ] || die "run this from the repository root."

DIRTY="$(git status --porcelain --untracked-files=all)" || die "git status failed"
[ -z "$DIRTY" ] || die "the working tree is not clean; a release is built from a commit, not from edits:
$(printf '%s\n' "$DIRTY" | head -5)"
# Untracked files under Sources/ are compiled whether or not git ignores them (an entry in
# .git/info/exclude, a global excludes file, .gitignore). A Finder .DS_Store is not code.
HIDDEN="$(git ls-files --others -- Sources Package.swift)" || die "git ls-files failed"
HIDDEN="$(printf '%s\n' "$HIDDEN" | grep -v -e '^$' -e '/\.DS_Store$')"
[ -z "$HIDDEN" ] || die "untracked files under Sources/ (git may be ignoring them, SwiftPM still compiles them) would ship under the tag's name:
$(printf '%s\n' "$HIDDEN" | head -5)"

FLAGGED="$(git ls-files -v -- Sources Package.swift)" || die "git ls-files failed"
FLAGGED="$(printf '%s\n' "$FLAGGED" | grep -v -e '^$' -e '^H ')"
[ -z "$FLAGGED" ] || die "tracked files under Sources/ are marked skip-worktree or assume-unchanged, so git status cannot see edits to them:
$(printf '%s\n' "$FLAGGED" | head -5)
(git update-index --no-skip-worktree / --no-assume-unchanged <path> to clear the flag)"

TAGS="$(git tag --points-at HEAD --list 'v[0-9]*')" || die "git tag failed"
TAG_COUNT="$(printf '%s\n' "$TAGS" | grep -c .)"
[ "$TAG_COUNT" -ge 1 ] || die "HEAD is not on a release tag (v[0-9]*). Tag the commit first, then build."
[ "$TAG_COUNT" -eq 1 ] || die "HEAD carries $TAG_COUNT release tags and git would pick one without telling you; keep exactly one:
$TAGS"
TAG="$TAGS"
TAG_SHAPE='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
[[ "$TAG" =~ $TAG_SHAPE ]] || die "tag '$TAG' is not of the form vX.Y.Z (optionally -prerelease)."
case "$(printf '%s' "$TAG" | tr 'A-Z' 'a-z')" in
  *-dryrun) die "tag '$TAG' ends in -DRYRUN (in some case), the suffix of rehearsal output directories; pick another name." ;;
esac
COMMIT="$(git rev-parse "$TAG^{commit}")" || die "could not resolve $TAG to a commit"

[ -f "$ENTITLEMENTS" ] || die "entitlements file not found: $ENTITLEMENTS"
[ -x "$VERIFY_BIN" ] || die "install-signature guard not built: $VERIFY_BIN (make $VERIFY_BIN)"

if [ "$NOTARIZE" = 1 ]; then
  PROBE="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1)" \
    || die "notarytool cannot use the keychain profile '$NOTARY_PROFILE':
$PROBE
(set it up once with: xcrun notarytool store-credentials $NOTARY_PROFILE — see docs/release.md)"
  OUT="$DIST_DIR/$TAG"
else
  OUT="$DIST_DIR/$TAG-DRYRUN"
fi

[ ! -L "$DIST_DIR" ] || die "$DIST_DIR is a symlink; the result would be written outside the repository."
mkdir -p "$DIST_DIR" || die "cannot create $DIST_DIR"
# Reserve the output name now. mkdir is atomic, so a second run of the same tag is refused
# here, and the final move cannot land inside a directory that appeared during the build.
mkdir "$OUT" 2>/dev/null || die "$OUT already exists (or cannot be created); remove it deliberately if you mean to rebuild."
OUT_RESERVED=1
STAGE="$(mktemp -d "$DIST_DIR/.staging.XXXXXX")" || die "cannot create a staging directory in $DIST_DIR"
SHIPPED="$STAGE/$BINARY_NAME"

# --- build ------------------------------------------------------------------------

BUILD=(swift build -c release --arch arm64 --arch x86_64)
echo "→ building $TAG (Universal)"
"$SCRIPT_DIR/stamp-version.sh" "$VERSION_FILE" -- "${BUILD[@]}" \
  || die "build failed"
BIN_DIR="$("${BUILD[@]}" --show-bin-path)" || die "could not locate the build products"
[ -x "$BIN_DIR/$BINARY_NAME" ] || die "no $BINARY_NAME in $BIN_DIR"

ARCHS="$(lipo -archs "$BIN_DIR/$BINARY_NAME")" || die "lipo could not read $BIN_DIR/$BINARY_NAME"
for want in arm64 x86_64; do
  case " $ARCHS " in
    *" $want "*) ;;
    *) die "the build is missing the $want slice (it has: $ARCHS)" ;;
  esac
done

# --- sign and verify --------------------------------------------------------------

cp "$BIN_DIR/$BINARY_NAME" "$SHIPPED" && chmod +x "$SHIPPED" || die "could not stage the binary"

TIMESTAMP_FLAG="--timestamp"
[ "$RELEASE_TIMESTAMP" = none ] && TIMESTAMP_FLAG="--timestamp=none"
echo "→ signing"
codesign --force --options runtime "$TIMESTAMP_FLAG" \
         --sign "$DEVELOPER_ID" \
         --entitlements "$ENTITLEMENTS" \
         "$SHIPPED" \
  || die "codesign failed"

codesign --verify --strict --verbose=2 "$SHIPPED" \
  || die "codesign --verify rejected the signed binary"
"$VERIFY_BIN" --require-shape "Developer ID" --require-entitlement "$ENTITLEMENT_KEY" "$SHIPPED" \
  || die "the signed binary does not meet the install-signature contract (see above)"
REPORTED="$("$SHIPPED" --version 2>&1)" \
  || die "the signed binary could not report its version: $REPORTED"
[ "$REPORTED" = "$TAG" ] || die "the binary reports '$REPORTED', expected '$TAG'"

# --- the submission zip (built in a rehearsal too) --------------------------------

ZIPDIR="$(mktemp -d "${TMPDIR:-/tmp}/release-submit.XXXXXX")" || die "cannot create a submission directory"
ZIP="$ZIPDIR/$BINARY_NAME.zip"
# Not --keepParent (Apple's example is for .app bundles): given a bare file it archives
# the containing directory too, here a random temp name. Without --norsrc --noextattr
# a ._<name> AppleDouble entry rides along. Measured with ditto on macOS 27.
ditto -c -k --norsrc --noextattr "$SHIPPED" "$ZIP" || die "could not zip the binary for submission"

# --- notarize ---------------------------------------------------------------------

if [ "$NOTARIZE" = 1 ]; then
  echo "→ submitting to Apple (waiting for the verdict)"
  RESULT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
  SUBMIT_RC=$?
  SUBMISSION_ID="$(printf '%s' "$RESULT" | plutil -extract id raw -o - - 2>/dev/null)"
  STATUS="$(printf '%s' "$RESULT" | plutil -extract status raw -o - - 2>/dev/null)"

  if [ "$SUBMIT_RC" -ne 0 ] || [ "$STATUS" != "Accepted" ]; then
    echo "release: notarization was not accepted (status: ${STATUS:-unreadable}, exit: $SUBMIT_RC)" >&2
    printf '%s\n' "$RESULT" >&2
    if [ -n "$SUBMISSION_ID" ]; then
      echo "--- notarytool log $SUBMISSION_ID ---" >&2
      xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    else
      echo "release: the answer carried no readable submission id, so no log was fetched;" >&2
      echo "         find the submission with: xcrun notarytool history --keychain-profile $NOTARY_PROFILE" >&2
    fi
    exit 1
  fi
  printf '%s\n' "$RESULT" > "$STAGE/NOTARIZATION.json" || die "could not record the notarization result"
else
  printf 'This build was signed but never submitted for notarization. Do not upload it as a release.\n' \
    > "$STAGE/DRYRUN-NOT-NOTARIZED" || die "could not write the dry-run marker"
fi

# --- publish the directory --------------------------------------------------------

HASH_LINE="$(shasum -a 256 < "$SHIPPED")" || die "could not compute the checksum"
HASH="${HASH_LINE%% *}"
[[ "$HASH" =~ ^[0-9a-f]{64}$ ]] || die "shasum did not produce a SHA-256 (got '$HASH_LINE')"
printf '%s\n' "$HASH" > "$STAGE/$BINARY_NAME.sha256" || die "could not write the checksum"

mv "$STAGE"/* "$OUT"/ || die "could not move the result into $OUT"
OUT_RESERVED=0   # first: a signal from here on must not delete the finished result
rmdir "$STAGE" 2>/dev/null
STAGE=""
chmod 755 "$OUT"

echo "✓ $OUT"
if [ "$NOTARIZE" = 1 ]; then
  PRERELEASE=""
  case "$TAG" in *-*) PRERELEASE=" --prerelease" ;; esac
  echo
  echo "Next — you run these. This script never tags, pushes or calls gh."
  echo "The tag $TAG is commit $COMMIT. Push it and check that the remote shows the same"
  echo "commit BEFORE creating the release (for an annotated tag the commit is on the line"
  echo "ending in ^{}; the other line is the tag object). --verify-tag makes gh refuse a tag"
  echo "that is not on the remote (otherwise it creates one at the tip of the default branch):"
  printf '  git push origin %q\n' "$TAG"
  # TAG passed TAG_SHAPE ([0-9A-Za-z.-] only), so plain single quotes are safe and readable here
  printf "  git ls-remote origin 'refs/tags/%s' 'refs/tags/%s^{}'    # must show %s\n" "$TAG" "$TAG" "$COMMIT"
  printf '  gh release create %q --verify-tag%s %q %q --title %q --notes %q\n' \
    "$TAG" "$PRERELEASE" "$OUT/$BINARY_NAME" "$OUT/$BINARY_NAME.sha256" "$TAG" \
    "Signed with a Developer ID, team $TEAM_ID. To check a download, see docs/release.md (Checking a downloaded copy)."
else
  echo "  dry run: signed with a real identity, but nothing was submitted for notarization."
  if [ "$RELEASE_TIMESTAMP" != none ]; then
    echo "  (the signature's hash did go to Apple's timestamp server; RELEASE_TIMESTAMP=none avoids that)"
  fi
fi
