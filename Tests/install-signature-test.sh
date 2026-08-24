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

VERIFIER="${VERIFY_INSTALL_SIGNATURE:-scripts/verify-install-signature.swift}"

PASS=0
FAIL=0
SKIPPED=0

# A skipped case is not a passing case. Round 5 found that on any machine with
# no codesigning identity — a plain `git clone` by anyone without an Apple
# Developer account — every fixture exercising the shape matcher skipped, and
# the suite still printed green. The words "NOT a pass" were in the output and
# in nothing else: they did not touch the exit status.
#
# So skips are counted and, by default, fatal. Set ALLOW_INCOMPLETE=1 to run
# what this machine can and accept a partial result knowingly; the summary
# still names every case that did not run. There is no CI here to appease, and
# a suite that cannot test the thing must not claim it did.
skip() { SKIPPED=$((SKIPPED + 1)); printf "  %s SKIPPED — %s\n" "⊘" "$1"; }
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
# Some cases have more than one legitimate answer — see the requirement-set
# case below. Pinning those to a single code tests the machine, not the tool.
assert_exit_in() {
    local label="$1" allowed="$2" target="$3"
    local out rc
    out=$("$VERIFIER" "$target" 2>&1); rc=$?
    for want in $allowed; do
        # pass(), not a bare echo: the first draft of this helper printed its
        # own ✓ and never touched $PASS, so the summary undercounted by one
        # while the transcript looked right. That is the same shape as the
        # skip bug above — a visible line standing in for a tallied result.
        if [[ "$rc" == "$want" ]]; then pass "$label (exit $rc)"; return 0; fi
    done
    fail "$label" "expected one of [$allowed], got $rc — output: $(echo "$out" | head -2 | tr '\n' '⏎')"
}

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

FIXTURES=$(mktemp -d "${TMPDIR:-/tmp}/install-signature-fixtures.XXXXXX") || {
    echo "✗ could not create a fixture directory (TMPDIR=${TMPDIR:-/tmp})" >&2
    exit 1
}
[[ -n "$FIXTURES" && -d "$FIXTURES" ]] || {
    echo "✗ fixture directory is empty or missing — refusing to continue" >&2
    exit 1
}
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

# Round 4 constructed these against the round-3 criterion, which was a
# substring search over a language that has string literals, boolean
# operators, negation and parens. Each defeats "the DR must contain the word
# anchor or certificate" using a different feature of that language.
# Custom-requirement fixtures MUST be signed with a real identity. Built
# ad-hoc they never reach the shape matcher at all — the observable-fact check
# answers first — so they would pass while testing nothing, which is the same
# defect (a fixture that does not exercise what it claims) that R2-B5 was
# about. Signed, they exercise exactly the path the round-4 attacks used.
SHAPE_ID="${DEVID_ANY:-${NON_DEVID:-}}"
HAVE_SHAPE_FIXTURES=0
if [[ -n "$SHAPE_ID" ]]; then
    make_dr_fixture() {  # <name> <requirement text>
        cp /bin/ls "$FIXTURES/$1"
        printf 'designated => %s\n' "$2" > "$FIXTURES/$1.req"
        codesign --force --sign "$SHAPE_ID" -r "$FIXTURES/$1.req" \
            "$FIXTURES/$1" >/dev/null 2>&1
        codesign -dvv "$FIXTURES/$1" 2>&1 | grep -q '^Signature=adhoc' \
          && fixture_fail "$1 came out ad-hoc — it would never reach the shape check"
    }
    make_dr_fixture anchor-in-string 'identifier "com.foo.anchor"'
    make_dr_fixture negated          'identifier "com.foo.neg" and !(anchor apple)'
    make_dr_fixture version-pinned   'identifier "com.foo.ver" and anchor apple generic and info[CFBundleVersion] = "1"'
    HAVE_SHAPE_FIXTURES=1
fi

# `codesign -d -r-` can emit a requirement SET, not just one line. Real
# Developer ID applications on this machine do (round 4 found three under
# /Applications). Taking every line and feeding the lot to -R produces a
# syntax error, which the round-3 script reported as a verdict about the
# binary.
# Discovery filters on an intact seal. Without that, this picks whatever
# /Applications happens to offer first — and some real applications are
# genuinely damaged (Anki on the development machine has a modified
# Info.plist). Asserting exit 0 on an arbitrary neighbour makes the suite go
# red for a fault that is not ours.
REQSET=""
for cand in /Applications/*/Contents/MacOS/*; do
    [ -f "$cand" ] || continue
    codesign -d -r- "$cand" 2>&1 | grep -q '^host =>' || continue
    codesign --verify --strict "$cand" >/dev/null 2>&1 || continue
    REQSET="$cand"; break
done

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
# Answered by the signature field, not by the preserved requirement it
# advertises. Round 2 expected 4 here (cannot satisfy); with the observable
# fact checked first the answer is 1, and the two verdicts agree on what
# matters — do not trust this binary's grant.
assert_exit "ad-hoc with a preserved requirement is ad-hoc" 1 "$FIXTURES/adhoc-preserved"

echo
echo "── broken seal (#119 verify B1a) ──"
# Distinct from both: the metadata is fine, the signature is not, and macOS
# SIGKILLs the binary on launch. Reporting this as "grant survives rebuilds"
# is a claim about a binary that cannot start.
assert_exit "tampered binary is rejected distinctly" 3 "$FIXTURES/tampered"
# "signature" alone would also match the SUCCESS line ("identity-bound
# signature"), so this asserts on a word only the broken-seal branch prints.
assert_says "tampered rejection names the signature, not the requirement" "$FIXTURES/tampered" "code or signature have been modified"

echo
echo "── real certificate, foreign requirement (#119 verify R2-B1) ──"
# Valid seal, not ad-hoc, no cdhash — every NEGATIVE check passes. Only asking
# "does it satisfy its own DR?" catches it. This is the input round 2
# constructed after round 1's fix shipped.
if [[ "$HAVE_CROSSED" == "1" ]]; then
    assert_exit "signature that cannot satisfy its own requirement is rejected" 4 "$FIXTURES/crossed"
    assert_says "rejection names the requirement, not the seal" "$FIXTURES/crossed" "own designated requirement"
else
    skip "needs both a Developer ID and a non-Developer-ID identity"
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
    skip "no non-Developer-ID signing identity available."
fi

echo
echo "── the requirement language is not a bag of words (#119 verify R4) ──"
# Each of these defeats a substring test using a different feature of the
# requirement language: a keyword inside a string literal, a negation, an
# extra conjunct. None is a shape this tool was taught, so each must get
# "cannot tell" rather than a guess in either direction.
if [[ "$HAVE_SHAPE_FIXTURES" == "1" ]]; then
    assert_exit "a keyword inside a quoted identifier is not a clause" 5 "$FIXTURES/anchor-in-string"
    assert_exit "a negated anchor is not an anchor" 5 "$FIXTURES/negated"
    assert_exit "an anchored requirement with a version pin is not a known shape" 5 "$FIXTURES/version-pinned"
else
    skip "no signing identity available to build custom-requirement"
    echo "    fixtures. Ad-hoc ones would be answered by the signature check before"
    echo "    ever reaching the shape matcher."
    echo "    NOT a pass: the round-4 attacks are unverified in this run."
fi

# The observable-fact check answers first for an ad-hoc binary, and the
# contents of its requirement are never examined. That is the point: an
# identifier containing the word `cdhash` cannot change the verdict, because
# nothing greps for that word any more.
assert_exit "an ad-hoc binary is ad-hoc whatever its requirement says" 1 "$FIXTURES/adhoc-preserved"

if [[ -n "$REQSET" ]]; then
    # The regression is a mangled READ, not a particular verdict: round 3 fed
    # every line of the set to -R, got a syntax error, and printed that as
    # "this binary cannot satisfy the requirement it advertises". So this
    # asserts the tool reached a real answer about the requirement — 0 if the
    # shape is one it knows, 5 if not — and never a fault verdict, which for a
    # seal-verified binary could now only come from misreading the set.
    assert_exit_in "a requirement SET is read, not mangled into a false verdict" "0 5" "$REQSET"
else
    skip "no binary with a requirement set found under /Applications."
    echo "    NOT a pass: the requirement-set case is unverified in this run."
fi

echo
echo "── satisfiable but unprovable (#119 verify R3) ──"
# The verifier answers one question: will a Full Disk Access grant on this
# binary still apply later? For these it cannot tell, and says so (5) rather
# than guessing in the optimistic direction.
assert_exit "a bare-identifier ad-hoc binary is answered as ad-hoc" 1 "$FIXTURES/bare-identifier"
if [[ "$HAVE_VERSION_BOUND" == "1" ]]; then
    assert_exit "version-pinned ad-hoc binary is answered as ad-hoc" 1 "$FIXTURES/version-bound"
else
    skip "codesign did not retain the version-pinned requirement."
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
if [[ "$SKIPPED" -gt 0 ]]; then
    echo
    echo "  $SKIPPED case(s) did not run on this machine (see ⊘ above)."
    if [[ -n "${ALLOW_INCOMPLETE:-}" ]]; then
        echo "  ALLOW_INCOMPLETE=1 — accepting a partial result."
    else
        echo "  This is not a pass. Re-run with ALLOW_INCOMPLETE=1 to accept it"
        echo "  knowingly, or provide a codesigning identity so they can run."
        FAIL=$((FAIL + 1))
    fi
fi

[[ "$FAIL" -eq 0 ]]
