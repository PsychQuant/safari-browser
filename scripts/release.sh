#!/bin/bash
# Build, sign and (optionally) notarize the release binary (#280).
#
# usage: DEVELOPER_ID=<cert sha-1> [NOTARIZE=1] scripts/release.sh   (from the repo root)
#
# Output is dist/<tag>/ : the signed binary, its sha256 (the hash alone, one line) and
# NOTARIZATION.json (Apple's answer, verbatim). Without NOTARIZE=1 nothing is sent to
# Apple and the output is dist/<tag>-DRYRUN/ with a DRYRUN-NOT-NOTARIZED marker, so a
# rehearsal cannot be mistaken for, or block, the real thing.
#
# This script never creates or pushes a tag and never calls gh. Publishing is the
# maintainer's act; the commands are printed at the end.
#
# Why the checks are shaped the way they are:
#   - Every refusal happens before the build. A Universal build is minutes and a
#     notarization is more, so a missing identity, a dirty tree or a dead notary
#     profile must cost seconds.
#   - HEAD must be exactly on a `v[0-9]*` tag (same selector as stamp-version.sh, so
#     `idd-217-baseline` cannot stand in) and the tag must look like vX.Y.Z: the text
#     becomes a directory name and is printed inside commands for the maintainer to run.
#   - The binary must report the tag itself. A stamp that did not take reports
#     `unknown`, and a release that cannot say what it is defeats #278.
#   - `--timestamp` is what separates this from `make install-signed`: Apple refuses a
#     binary without a secure timestamp. `RELEASE_TIMESTAMP=none` exists for offline
#     rehearsals only and is refused together with NOTARIZE=1.
#   - Only the status `Accepted` passes. notarytool's exit code is not trusted to mean
#     "accepted" (an Invalid verdict is a completed submission), so the JSON is read.
#   - Work happens in a staging directory next to the output and is renamed into place
#     last, so a failure at any step leaves no half-built release behind.
#   - The zip sent to Apple is a submission container, not a deliverable: a bare
#     Mach-O cannot be stapled, so users receive the binary itself.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY_NAME="${BINARY_NAME:-safari-browser}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-che-mcps-notary}"
RELEASE_TIMESTAMP="${RELEASE_TIMESTAMP:-}"
DIST_DIR="${DIST_DIR:-dist}"
ENTITLEMENTS="${ENTITLEMENTS:-Sources/SafariBrowser/Entitlements.plist}"
VERIFY_BIN="${VERIFY_BIN:-.build/verify-install-signature}"
VERSION_FILE="Sources/SafariBrowser/BuildVersion.swift"
ENTITLEMENT_KEY="com.apple.security.automation.apple-events"

die() { echo "release: $*" >&2; exit 1; }

STAGE=""
ZIPDIR=""
cleanup() {
  [ -n "$STAGE" ] && rm -rf "$STAGE"
  [ -n "$ZIPDIR" ] && rm -rf "$ZIPDIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# --- preflight --------------------------------------------------------------------

[ -n "${DEVELOPER_ID:-}" ] \
  || die "DEVELOPER_ID is unset. Name the Developer ID Application certificate (its SHA-1)."
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
printf '%s\n' "$IDENTITIES" | grep -Fq -- "$DEVELOPER_ID" \
  || die "DEVELOPER_ID '$DEVELOPER_ID' is not a valid identity in the keychain."

# Same rule as stamp-version.sh: the repository root, or `git describe` may walk up
# into some other repository and produce a tag that is not ours.
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" && TOP="$(cd "$TOP" 2>/dev/null && pwd -P)"
[ -n "${TOP:-}" ] && [ "$TOP" = "$(pwd -P)" ] || die "run this from the repository root."

DIRTY="$(git status --porcelain)" || die "git status failed"
[ -z "$DIRTY" ] || die "the working tree is not clean; a release is built from a commit, not from edits:
$(printf '%s\n' "$DIRTY" | head -5)"

TAG="$(git describe --exact-match --tags --match 'v[0-9]*' HEAD 2>/dev/null)" \
  || die "HEAD is not exactly on a release tag (v[0-9]*). Tag the commit first, then build."
TAG_SHAPE='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
[[ "$TAG" =~ $TAG_SHAPE ]] || die "tag '$TAG' is not of the form vX.Y.Z (optionally -prerelease)."

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
[ ! -e "$OUT" ] || die "$OUT already exists; remove it deliberately if you mean to rebuild."

mkdir -p "$DIST_DIR" || die "cannot create $DIST_DIR"
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
REPORTED="$("$SHIPPED" --version 2>&1)"
[ "$REPORTED" = "$TAG" ] || die "the binary reports '$REPORTED', expected '$TAG'"

# --- notarize ---------------------------------------------------------------------

if [ "$NOTARIZE" = 1 ]; then
  ZIPDIR="$(mktemp -d "${TMPDIR:-/tmp}/release-submit.XXXXXX")" || die "cannot create a submission directory"
  ZIP="$ZIPDIR/$BINARY_NAME.zip"
  # Not --keepParent (Apple's example is for .app bundles): given a bare file it archives
  # the containing directory too, here a random temp name. Without --norsrc --noextattr
  # a ._<name> AppleDouble entry rides along. Measured with ditto on macOS 27.
  ditto -c -k --norsrc --noextattr "$SHIPPED" "$ZIP" || die "could not zip the binary for submission"

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
    fi
    exit 1
  fi
  printf '%s\n' "$RESULT" > "$STAGE/NOTARIZATION.json" || die "could not record the notarization result"
else
  cat > "$STAGE/DRYRUN-NOT-NOTARIZED" <<EOF
This build was signed but never submitted to Apple. Do not upload it as a release.
EOF
fi

# --- publish the directory --------------------------------------------------------

shasum -a 256 < "$SHIPPED" | awk '{print $1}' > "$STAGE/$BINARY_NAME.sha256" \
  || die "could not write the checksum"

chmod 755 "$STAGE" && mv "$STAGE" "$OUT" || die "could not move the result into $OUT"
STAGE=""

echo "✓ $OUT"
if [ "$NOTARIZE" = 1 ]; then
  cat <<EOF

Next — you run these; this script never tags, pushes or calls gh:
  git push origin $TAG        # skip if the tag is already on the remote
  gh release create $TAG '$OUT/$BINARY_NAME' '$OUT/$BINARY_NAME.sha256' --title '$TAG'
EOF
else
  echo "  dry run: signed with a real identity, nothing was sent to Apple."
fi
