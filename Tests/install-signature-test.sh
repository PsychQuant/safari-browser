#!/bin/bash
# Install-signature tests — does the installed binary hold a Full Disk Access
# grant that survives a rebuild? (#119)
#
# Why this tier exists: TCC stores a binary's *designated requirement*, not its
# path. An ad-hoc signature's requirement IS the content hash
# (`designated => cdhash H"..."`), so any rebuild changes it and the grant
# silently stops applying. A Developer ID signature's requirement names an
# identity instead (`identifier ... and certificate leaf[subject.OU] = "..."`)
# and survives. `make install` produces the former; `make install-signed`
# produces the latter.
#
# Nothing here needs Full Disk Access, a signing certificate, or a live Safari
# — only `codesign`, which reads. Fixtures are copies in a temp dir.
#
# Usage:
#   make test-install-signature
#   ./Tests/install-signature-test.sh
#
# Exit 0 = all green, 1 = at least one failure.
set -u

VERIFIER="${VERIFY_INSTALL_SIGNATURE:-scripts/verify-install-signature.sh}"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "      $2"; }

# assert_exit "<label>" "<expected-code>" <path>
assert_exit() {
    local label="$1" want="$2" target="$3"
    local out rc
    out=$("$VERIFIER" "$target" 2>&1); rc=$?
    if [[ "$rc" == "$want" ]]; then
        pass "$label"
    else
        fail "$label" "expected exit $want, got $rc — output: $(echo "$out" | head -2 | tr '\n' '⏎')"
    fi
}

# assert_says "<label>" <path> "<needle>"
assert_says() {
    local label="$1" target="$2" needle="$3"
    local out
    out=$("$VERIFIER" "$target" 2>&1)
    if [[ "$out" == *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label" "expected output to contain «${needle}», got: $(echo "$out" | head -3 | tr '\n' '⏎')"
    fi
}

if [[ ! -x "$VERIFIER" ]]; then
    echo "✗ verifier not found / not executable: $VERIFIER" >&2
    exit 1
fi

FIXTURES=$(mktemp -d "${TMPDIR:-/tmp}/install-signature-fixtures.XXXXXX")
trap 'rm -rf "$FIXTURES"' EXIT

# Every fixture below ASSERTS ITS OWN PRECONDITION before the suite uses it.
# Round 2 of #119's verify found the reason: a fixture whose precondition
# silently fails does not fail the suite, it QUIETLY BECOMES A DIFFERENT TEST.
# `adhoc-preserved` was built from ~/bin/safari-browser, so on a machine where
# that binary was ad-hoc, the fixture's requirement already contained `cdhash`
# and the pre-fix verifier would have passed the assertion too — 10/10 green
# while proving nothing. Preconditions are checked, and a failed one aborts.
fixture_fail() { echo "✗ FIXTURE SETUP FAILED: $1" >&2; exit 1; }

# /bin/ls is Apple-signed with an identity-bound requirement
# (`identifier "com.apple.ls" and anchor apple`), present on every Mac, and
# NOT dependent on how this repo happens to be installed — which is exactly
# why every fixture is derived from it and none from ~/bin/safari-browser.
cp /bin/ls "$FIXTURES/identity-bound"
codesign -d -r- "$FIXTURES/identity-bound" 2>&1 | grep -q 'cdhash' \
  && fixture_fail "/bin/ls requirement contains cdhash — expected identity-bound"

cp /bin/ls "$FIXTURES/adhoc"
codesign --force --sign - "$FIXTURES/adhoc" >/dev/null 2>&1
codesign -dvv "$FIXTURES/adhoc" 2>&1 | grep -q 'Signature=adhoc' \
  || fixture_fail "adhoc fixture is not actually ad-hoc"

cp /bin/ls "$FIXTURES/unsigned"
codesign --remove-signature "$FIXTURES/unsigned" >/dev/null 2>&1
codesign -dvv "$FIXTURES/unsigned" 2>&1 | grep -q 'not signed' \
  || fixture_fail "unsigned fixture still carries a signature"

# Ad-hoc signature that KEPT the previous requirement. `--preserve-metadata`
# copies the old identity-bound requirement onto a signature with no
# certificate chain, so it prints a requirement it can never satisfy. Judging
# by the requirement's SHAPE passes this. (#119 verify B1b)
cp /bin/ls "$FIXTURES/adhoc-preserved"
codesign --force --sign - --preserve-metadata=requirements,entitlements \
    "$FIXTURES/adhoc-preserved" >/dev/null 2>&1
codesign -dvv "$FIXTURES/adhoc-preserved" 2>&1 | grep -q 'Signature=adhoc' \
  || fixture_fail "adhoc-preserved is not ad-hoc — --preserve-metadata did not apply as expected"
codesign -d -r- "$FIXTURES/adhoc-preserved" 2>&1 | grep -q 'cdhash' \
  && fixture_fail "adhoc-preserved's requirement contains cdhash — the preserved requirement was lost, so this fixture no longer distinguishes shape-checking from signature-checking"

# Broken seal: requirement metadata intact, signature invalid, SIGKILL on
# launch. The offset is not reasoned about — it is CHECKED. Round 2 flagged
# `len//2` with a comment claiming "inside __TEXT" that nothing guaranteed;
# the honest fix is not a better guess but an assertion that the tamper
# actually broke the seal. (#119 verify B1a / R2-B5)
cp /bin/ls "$FIXTURES/tampered"
python3 - "$FIXTURES/tampered" <<'PY' >/dev/null 2>&1
import sys
p = sys.argv[1]
b = bytearray(open(p, 'rb').read())
b[len(b) // 2] ^= 0xFF
open(p, 'wb').write(bytes(b))
PY
codesign --verify --strict "$FIXTURES/tampered" >/dev/null 2>&1 \
  && fixture_fail "tampered fixture still passes codesign --verify — the flipped byte landed outside the sealed region"

# Signed with a real certificate that is NOT Developer ID, carrying a
# preserved Developer ID requirement it can never satisfy. This is the state
# round 2 constructed: valid seal, not ad-hoc, no cdhash — every negative
# check passes, and the binary still cannot hold a grant. (#119 verify R2-B1)
#
# Needs a second signing identity, so it is CONDITIONAL — but the skip is
# announced, never silent.
NON_DEVID=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -v 'Developer ID Application' | grep -oE '[0-9A-F]{40}' | head -1)
DEVID_ANY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep 'Developer ID Application' | grep -oE '[0-9A-F]{40}' | head -1)
HAVE_CROSSED=0
if [[ -n "$NON_DEVID" && -n "$DEVID_ANY" ]]; then
    cp /bin/ls "$FIXTURES/crossed"
    codesign --force --sign "$DEVID_ANY" "$FIXTURES/crossed" >/dev/null 2>&1
    codesign --force --sign "$NON_DEVID" \
        --preserve-metadata=requirements "$FIXTURES/crossed" >/dev/null 2>&1
    if codesign --verify --strict "$FIXTURES/crossed" >/dev/null 2>&1 \
       && codesign -d -r- "$FIXTURES/crossed" 2>&1 | grep -q '6.1.13'; then
        HAVE_CROSSED=1
    fi

    cp /bin/ls "$FIXTURES/other-identity"
    codesign --force --sign "$NON_DEVID" "$FIXTURES/other-identity" >/dev/null 2>&1
    # This fixture exists to prove the verifier does NOT demand Developer ID.
    # Without the assertion it silently degrades into a duplicate of
    # identity-bound whenever the signing did not take — which is the very
    # failure (R2-B5) the round that added it was fixing. Found by round 3.
    codesign -dvv "$FIXTURES/other-identity" 2>&1 | grep -q 'Authority=Developer ID Application' \
      && fixture_fail "other-identity is Developer ID signed — it cannot prove non-Developer-ID identities pass"
    codesign -dvv "$FIXTURES/other-identity" 2>&1 | grep -q '^Authority=' \
      || fixture_fail "other-identity has no Authority line — signing with the non-Developer-ID identity did not take"
fi

# Constructed by round 3's devil's advocate. Both pass every check the round-3
# verifier had, and neither can hold what this tool means by a durable grant.
#
#   bare-identifier: a DR naming ONLY an identifier — no anchor, no
#     certificate. Satisfiable by an ad-hoc signature, and by any other binary
#     claiming the same identifier. "identity-bound" is false of it.
#   version-bound: a DR that pins info[CFBundleVersion]. Stable across a
#     rebuild, NOT stable across a version bump — which install-signed's own
#     message promises ("persists across rebuilds and version bumps").
cp /bin/ls "$FIXTURES/bare-identifier"
printf 'designated => identifier "com.checheng.safari-browser"\n' > "$FIXTURES/bare.req"
codesign --force --sign - --identifier com.checheng.safari-browser \
    -r "$FIXTURES/bare.req" "$FIXTURES/bare-identifier" >/dev/null 2>&1
codesign -d -r- "$FIXTURES/bare-identifier" 2>&1 | grep -qE 'anchor|certificate' \
  && fixture_fail "bare-identifier's DR gained an anchor/certificate clause — it no longer represents the unprovable case"

cp /bin/ls "$FIXTURES/version-bound"
printf 'designated => identifier "com.apple.ls" and info[CFBundleShortVersionString] = "1.0"\n' \
    > "$FIXTURES/ver.req"
codesign --force --sign - -r "$FIXTURES/ver.req" "$FIXTURES/version-bound" >/dev/null 2>&1
HAVE_VERSION_BOUND=0
codesign -d -r- "$FIXTURES/version-bound" 2>&1 | grep -q 'CFBundleShortVersionString' \
  && HAVE_VERSION_BOUND=1

echo "Install-signature tests ($VERIFIER)"
echo

echo "── identity-bound signature (the good state) ──"
assert_exit "identity-bound requirement passes" 0 "$FIXTURES/identity-bound"

echo
echo "── ad-hoc signature (the state #119 exists to catch) ──"
assert_exit "cdhash-bound requirement is rejected" 1 "$FIXTURES/adhoc"
assert_says "rejection names the rebuild consequence" "$FIXTURES/adhoc" "rebuild"
assert_says "rejection points at the fix" "$FIXTURES/adhoc" "install-signed"

echo
echo "── ad-hoc that kept the old requirement (#119 verify B1b) ──"
# The requirement SHAPE is identity-bound; the signature behind it is not.
# Judging by shape alone reports this as the good state, which is how the
# first version of this verifier shipped.
#
# Expected 4, not 1. Round 2's rewrite made the verdict MORE precise: an
# ad-hoc signature carrying a preserved `anchor apple` requirement has no
# certificate chain, so it can never satisfy that requirement — the grant
# would not merely die at the next rebuild (1), it would never apply at all
# (4). The earlier expectation of 1 came from classifying by signature type;
# the answer now comes from asking what the binary can actually satisfy.
assert_exit "ad-hoc with a preserved requirement cannot satisfy it" 4 "$FIXTURES/adhoc-preserved"

echo
echo "── broken seal (#119 verify B1a) ──"
# Distinct from both: the metadata is fine, the signature is not, and macOS
# SIGKILLs the binary on launch. Reporting this as "grant survives rebuilds"
# is a claim about a binary that cannot start.
assert_exit "tampered binary is rejected distinctly" 3 "$FIXTURES/tampered"
# "signature" alone would also match the SUCCESS line ("identity-bound
# signature"), so this asserts on a word only the broken-seal branch prints.
assert_says "tampered rejection names the seal, not the requirement" "$FIXTURES/tampered" "seal"

echo
echo "── real certificate, foreign requirement (#119 verify R2-B1) ──"
# Valid seal, not ad-hoc, no cdhash — every NEGATIVE check passes. Only asking
# "does it satisfy its own DR?" catches it. This is the input round 2
# constructed after round 1's fix shipped.
if [[ "$HAVE_CROSSED" == "1" ]]; then
    assert_exit "signature that cannot satisfy its own requirement is rejected" 4 "$FIXTURES/crossed"
    assert_says "rejection names the requirement, not the seal" "$FIXTURES/crossed" "own designated requirement"
else
    echo "  ⊘ SKIPPED — needs both a Developer ID and a non-Developer-ID identity"
    echo "    in the keychain. This machine has: $(security find-identity -v -p codesigning 2>/dev/null | grep -c 'valid identities\|)') entries."
    echo "    NOT a pass: the R2-B1 regression is unverified in this run."
fi

echo
echo "── durable but not Developer ID (must PASS, with a note) ──"
# /bin/ls is Apple-signed, not Developer ID, and its grant IS durable. A
# verifier that demanded Developer ID would reject it wrongly — the question
# is whether the requirement is stable and satisfiable, not who issued it.
if [[ -n "${NON_DEVID:-}" && -f "$FIXTURES/other-identity" ]]; then
    assert_exit "non-Developer-ID identity still passes" 0 "$FIXTURES/other-identity"
    # The note this used to assert on has been removed: it claimed
    # CodeSigningState would classify such a build as .unknown, which is false
    # for an ad-hoc binary (parse() returns .adHoc on the first branch), and it
    # printed an empty authority because ad-hoc signatures have no Authority
    # line. A claim about another file's behaviour that nobody had checked.
else
    echo "  ⊘ SKIPPED — no non-Developer-ID signing identity available."
fi

echo
echo "── satisfiable but unprovable (#119 verify R3) ──"
# The verifier answers one question: will a Full Disk Access grant on this
# binary still apply later? For these it cannot tell, and says so (5) rather
# than guessing in the optimistic direction.
assert_exit "bare identifier, no anchor or certificate, is not provable" 5 "$FIXTURES/bare-identifier"
assert_says "and says which clause it wanted" "$FIXTURES/bare-identifier" "anchor"
if [[ "$HAVE_VERSION_BOUND" == "1" ]]; then
    assert_exit "version-pinned requirement is not provable" 5 "$FIXTURES/version-bound"
else
    echo "  ⊘ SKIPPED — codesign did not retain the version-pinned requirement."
    echo "    NOT a pass: the version-bound case is unverified in this run."
fi

echo
echo "── unsigned / unreadable (must NOT be mistaken for the good state) ──"
# The trap this guards: `codesign -d -r-` exits 1 on an unsigned binary and
# prints no requirement at all, so a verifier that only greps for `cdhash`
# sees a miss and reports success. Unsigned must be its OWN exit code, not 0
# and not the ad-hoc code, or the two failures cannot be told apart.
assert_exit "unsigned binary is rejected distinctly" 2 "$FIXTURES/unsigned"
assert_exit "missing file is rejected distinctly" 2 "$FIXTURES/does-not-exist"

echo
echo "── real installed binary (informational) ──"
INSTALLED="$HOME/bin/safari-browser"
if [[ -e "$INSTALLED" ]]; then
    out=$("$VERIFIER" "$INSTALLED" 2>&1); rc=$?
    echo "  ℹ $INSTALLED → exit $rc"
    echo "$out" | sed 's/^/      /'
else
    echo "  ℹ $INSTALLED not present — skipped"
fi

echo
echo "── default target ──"
# With no argument the verifier checks the installed binary, so `make
# verify-install-signature` needs no path.
"$VERIFIER" >/dev/null 2>&1
rc=$?
if [[ "$rc" =~ ^[0-5]$ ]]; then
    pass "no-argument form resolves a default target (exit $rc)"
else
    fail "no-argument form resolves a default target" "got exit $rc"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
