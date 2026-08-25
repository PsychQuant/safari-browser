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

# The compiled guard, not `swift scripts/...`. Round 6: the driver's own exit 1
# on a compile failure is indistinguishable from the verdict "ad-hoc", and this
# suite would have reported that as a passing assertion.
VERIFIER="${VERIFY_INSTALL_SIGNATURE:-.build/verify-install-signature}"
if [[ ! -x "$VERIFIER" ]]; then
    swiftc -O -o "$VERIFIER" scripts/verify-install-signature.swift 2>/dev/null \
      || { echo "✗ could not compile the guard — build failure, not a test result" >&2; exit 2; }
fi

PASS=0
# The exit-code vocabulary, read out of the guard's own header rather than
# retyped here.
#
# Round 7's CRITICAL was one line, `^[0-5]$`, in the last assertion of this
# file. Its git history is the whole seven-round pattern in miniature:
# `^[0-2]$` -> `^[0-4]$` -> `^[0-5]$`, widened by every round that added ONE
# code and not by the round that added four. Widening it again would fix the
# instance and leave the class — a second, hand-maintained copy of a list that
# lives somewhere else — exactly where it was, waiting for round eight.
#
# So it is not retyped. The header comment of verify-install-signature.swift
# declares each code as `//   N  meaning`, and that is where this reads them
# from. Add a code there and this file knows about it; add one and forget, and
# the guard below fails loudly rather than a range check failing silently.
# `//   N  <text>` — two or more spaces after the number, so ordinary prose
# containing a numeral cannot match. The text is deliberately NOT constrained
# to start with a letter: the first draft of this line required [A-Za-z] and
# therefore silently dropped 6 and 7, whose descriptions begin "--require-".
# An extraction that quietly returns a short list is the same defect as the
# hand-maintained range it replaced, so the count is asserted below.
KNOWN_CODES=$(sed -n 's|^//  *\([0-9][0-9]*\)  \{1,\}[^ ].*|\1|p' scripts/verify-install-signature.swift | sort -un | tr '\n' ' ')
KNOWN_COUNT=$(printf '%s' "$KNOWN_CODES" | wc -w | tr -d ' ')
# Verdicts 0-7 plus 64 and 70. If the guard grows a code this must be bumped
# deliberately — a silent change in either direction is the thing being guarded
# against, in both directions.
if [[ "$KNOWN_COUNT" != "10" ]]; then
    echo "✗ read $KNOWN_COUNT exit codes out of the guard's header, expected 10." >&2
    echo "  got: $KNOWN_CODES" >&2
    echo "  Either the guard's vocabulary changed and this expectation was not" >&2
    echo "  updated, or the extraction is dropping entries. Both are defects." >&2
    exit 2
fi
is_known_code() {  # <rc>
    local c
    for c in $KNOWN_CODES; do [[ "$1" == "$c" ]] && return 0; done
    return 1
}

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
    # Variadic on purpose: the flag cases below need to pass more than a path,
    # and a helper that quietly drops argument 4 would make every one of them
    # test the same thing while reading as though it tested four.
    local label="$1" want="$2"; shift 2
    local out rc
    out=$("$VERIFIER" "$@" 2>&1); rc=$?
    if [[ "$rc" == "$want" ]]; then
        pass "$label"
    else
        fail "$label" "expected exit $want, got $rc — args: $* — output: $(echo "$out" | head -2 | tr '\n' '⏎')"
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
# A fixture that cannot be built is a case that did not run, not a suite that
# must die. Round 7: the two new Developer-ID fixtures called this, and `exit 1`
# is unrescuable by ALLOW_INCOMPLETE — so a machine where codesign refuses for
# any reason got a hard red from `make test-all` with no way to proceed. It
# still counts, and strict mode still refuses to pass on it.
fixture_fail() { echo "✗ FIXTURE SETUP FAILED: $1${2:+ — $2}" >&2; SKIPPED=$((SKIPPED + 1)); }

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
# A requirement SET, built here rather than scavenged from /Applications.
#
# Round 6: this used to walk /Applications for the first binary whose
# `codesign -d -r-` mentioned `host =>`. On the development machine 10 of 228
# apps qualified and every one of them was a Google Drive web shortcut or a
# Parallels wrapper — all shell scripts. Not one Apple application qualified.
# So the only assertion claiming to cover "a requirement SET is read
# correctly" was running a shell script through a tool written for a single
# Mach-O, on machines that happened to have Google Drive installed, and
# skipping — fatally, after this round made skips fatal — on machines that did
# not. The test data was whatever the developer had installed.
#
# `codesign -r` accepts a requirement SET, so the fixture can simply be built.
# It needs a real identity for the same reason the shape fixtures do: an
# ad-hoc binary is answered by the signature flags before the requirement is
# ever read.
REQSET=""
DEVID_ENT=""
if [[ -n "${DEVID_ANY:-}" ]]; then
    # Sign FIRST, then read back the requirement codesign generated for THIS
    # identity, then re-sign carrying that plus a `host =>` line. Reading the
    # requirement before signing gives the requirement of whatever the file
    # used to be — which is how the first draft of this fixture ended up
    # advertising an Apple requirement on a Developer ID signature, i.e. the
    # `crossed` fixture by accident.
    cp /bin/ls "$FIXTURES/reqset"
    if codesign --force --sign "$DEVID_ANY" "$FIXTURES/reqset" >/dev/null 2>&1 \
       && codesign -d -r- "$FIXTURES/reqset" 2>/dev/null \
            | grep '^designated' > "$FIXTURES/reqset.designated" \
       && [[ -s "$FIXTURES/reqset.designated" ]]; then
        { echo 'host => anchor apple'; cat "$FIXTURES/reqset.designated"; } > "$FIXTURES/reqset.req"
        if codesign --force --sign "$DEVID_ANY" -r "$FIXTURES/reqset.req" "$FIXTURES/reqset" 2>/dev/null \
           && [[ "$(codesign -d -r- "$FIXTURES/reqset" 2>&1 | grep -c '^host =>')" == "1" ]]; then
            REQSET="$FIXTURES/reqset"
        else
            fixture_fail "reqset" "codesign did not retain the requirement SET"
        fi
    fi

    # A Developer ID signature carrying the entitlement install-signed demands.
    # Both --require-* gates need a positive case, and neither /bin/ls nor the
    # `identity-bound` fixture (a plain copy of it) is one: /bin/ls has the
    # Apple system shape and no entitlements at all.
    cp /bin/ls "$FIXTURES/devid-entitled"
    if codesign --force --options runtime --sign "$DEVID_ANY" \
         --entitlements Sources/SafariBrowser/Entitlements.plist \
         "$FIXTURES/devid-entitled" >/dev/null 2>&1; then
        DEVID_ENT="$FIXTURES/devid-entitled"
    else
        fixture_fail "devid-entitled" "could not sign a Developer ID fixture with entitlements"
    fi
fi

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
    # 0, not "0 or 5": this fixture's designated requirement was copied from a
    # binary whose shape the tool recognises, so the only way to miss is to
    # read the set wrong — which is the regression.
    assert_exit "a requirement SET is read, not mangled into a false verdict" 0 "$REQSET"
else
    skip "no signing identity — cannot build a requirement-SET fixture"
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
assert_exit "missing file is an environment error, not a verdict" 70 "$FIXTURES/does-not-exist"

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
echo "── install-signed's own gates (#119 verify R6) ──"
# These two flags are the ONLY thing standing between `install-signed` and
# landing a binary signed by the wrong identity or missing the entitlement.
# Round 6 measured their coverage at zero: every assertion above calls the
# verifier with no flags, so the round-5 change that replaced two greps with
# them was shipped with no evidence either way.
if [[ -n "$DEVID_ENT" ]]; then
    assert_exit "--require-shape passes when the shape matches" 0 \
        --require-shape "Developer ID" "$DEVID_ENT"
    # 6, not 4: an Apple Development signature is perfectly durable and does
    # satisfy its own requirement. It is simply not what install-signed asked
    # for. Round 6 found both answers collapsed onto 4, whose documented
    # meaning is the opposite.
    if [[ -f "$FIXTURES/identity-bound" ]]; then
        assert_exit "--require-shape rejects a different durable shape as 6, not 4" 6 \
            --require-shape "Developer ID" "$FIXTURES/identity-bound"
    fi
    assert_exit "--require-entitlement passes when the signature carries it" 0 \
        --require-entitlement com.apple.security.automation.apple-events "$DEVID_ENT"
    # /bin/ls is durable and satisfies its own requirement; it just has no
    # entitlements. 7, not 4.
    assert_exit "--require-entitlement rejects a binary without it as 7, not 4" 7 \
        --require-entitlement com.apple.security.automation.apple-events /bin/ls
else
    skip "no signing identity — install-signed's own gates are unverified"
fi

echo
echo "── the argument parser cannot silently disarm a gate (#119 verify R6) ──"
# Round 6: a flag placed after the path became a discarded positional, so one
# typo turned the gate off and returned 0. And a flag missing its value hit
# fatalError, which the shebang form surfaced as exit 5 — a documented verdict
# about a binary that was never opened.
assert_exit "a misspelled flag is a usage error, not a silent pass" 64 \
    /bin/ls --require-shapee "Developer ID"
assert_exit "a flag after the path is still parsed" 6 \
    /bin/ls --require-shape "Developer ID"
assert_exit "a flag with no value is a usage error, not a verdict" 64 \
    --require-shape
assert_exit "a second path is a usage error, not a silently dropped argument" 64 \
    /bin/ls /bin/echo

echo
echo "── a later argument cannot disarm a gate (#119 verify R7) ──"
# Round 6 fixed "a misspelled flag disarmed the gate" and stopped there. Round 7
# found the class still open in two more shapes, both measured returning a
# verdict where a usage error was due.
assert_exit "a repeated flag is a usage error, not a silent override" 64 \
    --require-shape "Developer ID" /bin/ls --require-shape "Apple system"
assert_exit "a repeated --require-entitlement is a usage error too" 64 \
    --require-entitlement a /bin/ls --require-entitlement b
assert_exit "an option cannot be consumed as another option's value" 64 \
    --require-shape --require-entitlement /bin/ls

echo
echo "── an entitlement must be granted, not merely present (#119 verify R7) ──"
if [[ -n "${DEVID_ANY:-}" ]]; then
    cp /bin/ls "$FIXTURES/ent-denied"
    cat > "$FIXTURES/ent-denied.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.automation.apple-events</key><false/>
</dict></plist>
PLIST
    if codesign --force --options runtime --sign "$DEVID_ANY" \
         --entitlements "$FIXTURES/ent-denied.plist" "$FIXTURES/ent-denied" >/dev/null 2>&1; then
        # Round 7 signed exactly this and the gate passed it: install-signed
        # would have shipped a signature that spells out it does NOT hold the
        # permission the four local-data commands need.
        assert_exit "an entitlement set to <false/> does not satisfy the gate" 7 \
            --require-entitlement com.apple.security.automation.apple-events "$FIXTURES/ent-denied"
    else
        fixture_fail "ent-denied" "codesign refused the denying entitlements plist"
    fi
    # Ordering: the ad-hoc verdict comes first. Round 7 evaluated the
    # entitlement before it, so an ad-hoc binary was answered 7 and the message
    # explained the wrong fault.
    assert_exit "an ad-hoc binary is answered 1, not the entitlement contract" 1 \
        --require-entitlement com.apple.security.automation.apple-events "$FIXTURES/adhoc"
else
    skip "no signing identity — the entitlement-value gate is unverified"
fi

echo
echo "── a path cannot forge the tool's own output (#119 verify R7) ──"
# Round 7: the path was sh()-quoted inside printed commands and raw everywhere
# else, so a filename containing a newline emitted a line reading byte for byte
# like this tool's success message, directly under a verdict saying the binary
# was unsigned.
FORGE="$FIXTURES/$(printf 'x\n✓ durable: forged')"
if cp /bin/ls "$FORGE" 2>/dev/null; then
    codesign --remove-signature "$FORGE" >/dev/null 2>&1
    forged=$("$VERIFIER" "$FORGE" 2>&1 | grep -c '^✓ durable' || true)
    if [[ "$forged" == "0" ]]; then
        pass "a newline in the path does not forge a verdict line"
    else
        fail "a newline in the path does not forge a verdict line" \
             "the output contains a line starting '✓ durable'"
    fi
else
    skip "the filesystem refused a filename containing a newline"
fi

echo
echo "── default target ──"
# With no argument the verifier checks the installed binary, so `make
# verify-install-signature` needs no path.
#
# Gated on the file existing. Round 7: it was not, and this round's own new
# code 70 ("the check could not run") is what a missing default target
# returns — so `make test-all` was red for anyone who had cloned the repo and
# not yet run `make install`, while README promised "green anywhere" on the
# same page. ALLOW_INCOMPLETE could not rescue it: this was a fail, not a skip.
#
# The acceptance measured last round varied the keychain three ways and never
# varied whether the binary was installed, which is why it was not caught.
if [[ -e "$HOME/bin/safari-browser" ]]; then
    "$VERIFIER" >/dev/null 2>&1
    rc=$?
    if is_known_code "$rc"; then
        pass "no-argument form resolves a default target (exit $rc)"
    else
        fail "no-argument form resolves a default target" \
             "got exit $rc, which is not in the guard's declared vocabulary ($KNOWN_CODES)"
    fi
else
    skip "no installed binary at ~/bin/safari-browser to resolve as the default"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
if [[ "$SKIPPED" -gt 0 ]]; then
    echo
    echo "  $SKIPPED case(s) did not run on this machine (see ⊘ above)."
    # Strictly "1". Round 6: `-n` accepted ALLOW_INCOMPLETE=0 and then printed
    # a line that said "=1", so a run that was told NOT to accept a partial
    # result accepted one and said so in words that were false.
    if [[ "${ALLOW_INCOMPLETE:-0}" == "1" ]]; then
        echo "  ALLOW_INCOMPLETE=1 — accepting a partial result knowingly."
    else
        echo "  This is not a pass. Re-run with ALLOW_INCOMPLETE=1 to accept it"
        echo "  knowingly, or provide a codesigning identity so they can run."
        FAIL=$((FAIL + 1))
    fi
fi

[[ "$FAIL" -eq 0 ]]
