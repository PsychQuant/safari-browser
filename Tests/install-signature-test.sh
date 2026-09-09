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
# ── This suite is itself gated (#119 round 10) ───────────────────────────
#
# Being green is not evidence. After nine review rounds this file held 35 green
# assertions, and reverting the guard's fixes one at a time — measured, not
# argued — left it at 35/35 for EIGHT of the sixteen. Each round had added
# assertions for the instance it had just fixed; none had ever asked whether
# those assertions could see the fix removed.
#
#     make test-mutation-gate      # Tests/mutation-gate.sh
#
# reverts each `// @mutant(...)` declaration in the guard and requires this suite
# to go red on a NAMED assertion. A change to the guard, or to this file, must
# pass it; a new fix to the guard should arrive with a declaration, which the
# gate cannot enforce and reviewers can.
#
# Two consequences for how assertions are written here:
#
#   * Labels are the gate's join key. They must not vary with the verifier's
#     answer — detail like `(exit $rc)` goes in pass()'s second argument, which
#     is printed and not recorded.
#   * An assertion about what the tool DOES print cannot catch a defect that
#     consists of printing something it must NOT. Three of the eight survivors
#     were exactly that (`rm -f` offered for somebody else's software), which is
#     why assert_says_not and assert_no_forged_line exist.
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
GUARD_SRC="scripts/verify-install-signature.swift"
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
# to start with a letter: the first draft required [A-Za-z] and therefore
# silently dropped 6 and 7, whose descriptions begin "--require".
DECLARED=$(sed -n 's|^//  *\([0-9][0-9]*\)  \{1,\}[^ ].*|\1|p' "$GUARD_SRC" | sort -un | tr '\n' ' ')

# The declared list is cross-checked against the codes the guard can actually
# REACH, not against a number typed here.
#
# Round 8 mutation-tested the previous mechanism — an extraction plus a
# hardcoded count of 10 — and found it exactly inverted. Adding `exit(8)`
# WITHOUT documenting it left the count at 10: green, silent. Documenting a new
# code made the count 11: hard red, until a human bumped the constant by hand.
# So the negligent edit passed and the diligent one broke the build, which is
# the opposite of what the comment above it claimed. And the constant was
# itself a hand-maintained copy of a fact about the guard — structurally the
# same object as round 7's `^[0-5]$`, which it had been introduced to remove.
#
# There is no constant now. `exit(0)` is never written (the guard falls off the
# end on success), so 0 is added as the implicit one.
REACHED=$(printf '0\n%s' "$(grep -oE 'exit\(([0-9]+)\)' "$GUARD_SRC" | grep -oE '[0-9]+')" | sort -un | tr '\n' ' ')

if [[ "$DECLARED" != "$REACHED" ]]; then
    echo "✗ the guard's documented exit codes and its reachable ones disagree." >&2
    echo "    documented: $DECLARED" >&2
    echo "    reachable:  $REACHED" >&2
    echo "  A code that exists but is undocumented is the dangerous direction —" >&2
    echo "  callers cannot act on it. A code documented but unreachable is dead" >&2
    echo "  text. Both are defects, and neither can be fixed by editing a number" >&2
    echo "  in this file." >&2
    exit 2
fi
KNOWN_CODES="$DECLARED"

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
# Machine-readable result stream, one `<PASS|FAIL|SKIP>\t<label>` line per
# assertion, written when INSTALL_SIGNATURE_RESULT_LOG names a file. Human
# output is unchanged.
#
# This exists for Tests/mutation-gate.sh, and the reason is round 9 of #119.
# "The suite goes red" is not evidence that an assertion can tell a reverted
# fix from the original: the suite also goes red when a fixture degrades, and
# when the skip accounting fires. Attributing a kill to a NAMED assertion that
# was green before the mutation and red after is the only form of that claim
# which cannot be satisfied by collateral damage.
#
# Labels are therefore the gate's join key and must not vary with the
# verifier's answer. `pass` takes an optional second argument for detail that
# is printed but NOT recorded, so `(exit $rc)` can stay in the transcript
# without making the label move when rc moves.
RESULT_LOG="${INSTALL_SIGNATURE_RESULT_LOG:-}"
record() {  # <PASS|FAIL|SKIP> <label>
    [[ -n "$RESULT_LOG" ]] || return 0
    printf '%s\t%s\n' "$1" "$2" >> "$RESULT_LOG"
}

skip() { SKIPPED=$((SKIPPED + 1)); record SKIP "$1"; printf "  %s SKIPPED — %s\n" "⊘" "$1"; }
pass() { PASS=$((PASS + 1)); record PASS "$1"; echo "  ✓ $1${2:+ $2}"; }
fail() { FAIL=$((FAIL + 1)); record FAIL "$1"; echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "      $2"; }

# Some cases must vary the tool's idea of HOME: `isOurInstall` is defined
# against $HOME/bin/safari-browser, and the only honest way to exercise the
# staging-suffix rule is to put a fixture at that path. Writing into the real
# ~/bin would be a test that damages the machine it runs on, so HOME is
# redirected for the duration of ONE assertion via with_home.
ASSERT_HOME=""
run_verifier() {
    if [[ -n "$ASSERT_HOME" ]]; then
        HOME="$ASSERT_HOME" "$VERIFIER" "$@"
    else
        "$VERIFIER" "$@"
    fi
}

# with_home <home> <assert-fn> <args...>
# Scoped, and restores the previous value — a global that callers must remember
# to reset is the kind of thing that makes a later assertion silently test
# something else.
with_home() {
    local saved="$ASSERT_HOME"
    ASSERT_HOME="$1"; shift
    "$@"
    ASSERT_HOME="$saved"
}

# assert_exit "<label>" "<expected-code>" <path>
assert_exit() {
    # Variadic on purpose: the flag cases below need to pass more than a path,
    # and a helper that quietly drops argument 4 would make every one of them
    # test the same thing while reading as though it tested four.
    local label="$1" want="$2"; shift 2
    local out rc
    out=$(run_verifier "$@" 2>&1); rc=$?
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
    out=$(run_verifier "$target" 2>&1); rc=$?
    for want in $allowed; do
        # pass(), not a bare echo: the first draft of this helper printed its
        # own ✓ and never touched $PASS, so the summary undercounted by one
        # while the transcript looked right. That is the same shape as the
        # skip bug above — a visible line standing in for a tallied result.
        if [[ "$rc" == "$want" ]]; then pass "$label" "(exit $rc)"; return 0; fi
    done
    fail "$label" "expected one of [$allowed], got $rc — output: $(echo "$out" | head -2 | tr '\n' '⏎')"
}

assert_says() {
    local label="$1" target="$2" needle="$3"
    local out
    out=$(run_verifier "$target" 2>&1)
    if [[ "$out" == *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label" "expected output to contain «${needle}», got: $(echo "$out" | head -3 | tr '\n' '⏎')"
    fi
}

# The absence of a phrase, for the cases where saying the thing IS the defect:
# telling a user to `rm -f` somebody else's software, for one.
assert_says_not() {
    local label="$1" target="$2" needle="$3"
    local out
    out=$(run_verifier "$target" 2>&1)
    if [[ "$out" != *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label" "expected output NOT to contain «${needle}», got: $(echo "$out" | head -4 | tr '\n' '⏎')"
    fi
}

# Anchored at line start, NOT a substring search — and the difference is the
# whole point. display() escapes a newline in the path to a literal backslash-n,
# so the escaped form still CONTAINS the text of a success line; it simply no
# longer begins a line with it, which is what a reader parses. A substring check
# here would fail on correct output while passing output forged another way.
assert_no_forged_line() {
    local label="$1" target="$2" n
    n=$(run_verifier "$target" 2>&1 | grep -c '^✓ durable' || true)
    if [[ "$n" == "0" ]]; then
        pass "$label"
    else
        fail "$label" "output carries $n line(s) beginning '✓ durable'"
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
# Returns 1 so the caller can gate on it. Round 8: this counted a skip and
# returned success, and every call site was `<precondition> && fixture_fail
# ...` with the assertions following UNGUARDED — so a fixture that failed to
# build was still asserted against. That produced both a vacuous PASS (a
# degraded fixture the assertion cannot distinguish) and a hard red the skip
# accounting could not forgive. Downgrading the abort without guarding the
# call sites moved the defect rather than removing it.
# Round 9 measured the residue of that fix: 11 of the 12 call sites still had
# their assertions following UNGUARDED, so `<precondition> || fixture_fail ...`
# announced the damage and then asserted against the damaged fixture anyway.
# That is a vacuous PASS whenever the degraded file happens to satisfy the
# assertion, and it was not hypothetical — with the `adhoc` fixture degraded to
# an Apple-signed /bin/ls, `rejection names the rebuild consequence` passed,
# because the guard's SUCCESS output contains the word "rebuild".
#
# So fixture_fail now takes the fixture's NAME as its first argument and
# records it; `have <name>` answers whether that fixture is sound, and
# `assert_fixture <name> ...` runs an assertion only if it is. Nothing
# hand-maintains a list of fixtures — the name written at the failure site is
# the same key read at the assertion site, and an assertion that forgets to
# name its fixture is visible in the diff rather than silently vacuous.
BROKEN_FIXTURES=" "
fixture_fail() {  # <fixture-name> [detail]
    echo "✗ FIXTURE SETUP FAILED: $1${2:+ — $2}" >&2
    BROKEN_FIXTURES="$BROKEN_FIXTURES$1 "
    SKIPPED=$((SKIPPED + 1))
    return 1
}
have() { [[ "$BROKEN_FIXTURES" != *" $1 "* ]]; }

# assert_fixture <fixture-name> <assert-fn> <label> <assert-args...>
# A degraded fixture yields a counted, named SKIP — fatal unless
# ALLOW_INCOMPLETE=1 — never a PASS.
assert_fixture() {
    local fx="$1" label="$3"
    if have "$fx"; then
        "${@:2}"
    else
        skip "$label (fixture '$fx' did not build)"
    fi
}

# The certificate a file was actually signed with, as a SHA-1 fingerprint read
# back from the signature — not "some Authority line is present". Round 8:
# other-identity's preconditions asked whether an `Authority=Developer ID
# Application` line was absent and whether any `^Authority=` line was present.
# A /bin/ls copy whose signing silently failed satisfies BOTH (Apple's own
# authority is neither), so the fixture degraded into a duplicate of
# identity-bound and its assertion passed while proving nothing — the R2-B5
# defect it was written to prevent, in the check written to prevent it.
# Exact identity, resolved through the keychain. `codesign -dvvv` does NOT
# print the certificate's SHA-1 — the 40-hex strings in its output are cdhash
# values, so comparing them to an identity fingerprint never matches and could
# in principle match the wrong thing. The reliable route is the identity's
# common name, which `security find-identity` gives for the fingerprint we
# asked codesign to sign with, compared against the signature's LEAF authority.
signed_by() {  # <path> <identity-sha1>  -> 0 when the leaf certificate is that identity
    local cn auth
    cn=$(security find-identity -v -p codesigning 2>/dev/null \
         | grep -F "$2" | sed -n 's/.*"\(.*\)".*/\1/p' | head -1)
    [[ -n "$cn" ]] || return 1
    auth=$(codesign -dvv "$1" 2>&1 | sed -n 's/^Authority=//p' | head -1)
    [[ "$auth" == "$cn" ]]
}

# /bin/ls is Apple-signed with an identity-bound requirement
# (`identifier "com.apple.ls" and anchor apple`), present on every Mac, and
# NOT dependent on how this repo happens to be installed — which is exactly
# why every fixture is derived from it and none from ~/bin/safari-browser.
cp /bin/ls "$FIXTURES/identity-bound"
codesign -d -r- "$FIXTURES/identity-bound" 2>&1 | grep -q 'cdhash' \
  && fixture_fail identity-bound "/bin/ls requirement contains cdhash — expected identity-bound"

cp /bin/ls "$FIXTURES/adhoc"
codesign --force --sign - "$FIXTURES/adhoc" >/dev/null 2>&1
codesign -dvv "$FIXTURES/adhoc" 2>&1 | grep -q 'Signature=adhoc' \
  || fixture_fail adhoc "not actually ad-hoc"

cp /bin/ls "$FIXTURES/unsigned"
codesign --remove-signature "$FIXTURES/unsigned" >/dev/null 2>&1
codesign -dvv "$FIXTURES/unsigned" 2>&1 | grep -q 'not signed' \
  || fixture_fail unsigned "still carries a signature"

# Ad-hoc signature that KEPT the previous requirement. `--preserve-metadata`
# copies the old identity-bound requirement onto a signature with no
# certificate chain, so it prints a requirement it can never satisfy. Judging
# by the requirement's SHAPE passes this. (#119 verify B1b)
cp /bin/ls "$FIXTURES/adhoc-preserved"
codesign --force --sign - --preserve-metadata=requirements,entitlements \
    "$FIXTURES/adhoc-preserved" >/dev/null 2>&1
codesign -dvv "$FIXTURES/adhoc-preserved" 2>&1 | grep -q 'Signature=adhoc' \
  || fixture_fail adhoc-preserved "not ad-hoc — --preserve-metadata did not apply as expected"
codesign -d -r- "$FIXTURES/adhoc-preserved" 2>&1 | grep -q 'cdhash' \
  && fixture_fail adhoc-preserved "its requirement contains cdhash — the preserved requirement was lost, so this fixture no longer distinguishes shape-checking from signature-checking"

# Broken seal: requirement metadata intact, signature invalid, SIGKILL on
# launch. The offset is not reasoned about — it is CHECKED. Round 2 flagged
# `len//2` with a comment claiming "inside __TEXT" that nothing guaranteed;
# the honest fix is not a better guess but an assertion that the tamper
# actually broke the seal. (#119 verify B1a / R2-B5)
# One definition, because three fixtures now need a broken seal, and a second
# copy of the byte-flip would be a second thing to keep true.
break_seal() {  # <path> -> 0 when codesign now rejects it
    python3 - "$1" <<'PY' >/dev/null 2>&1
import sys
p = sys.argv[1]
b = bytearray(open(p, 'rb').read())
b[len(b) // 2] ^= 0xFF
open(p, 'wb').write(bytes(b))
PY
    ! codesign --verify --strict "$1" >/dev/null 2>&1
}

cp /bin/ls "$FIXTURES/tampered"
break_seal "$FIXTURES/tampered" \
  || fixture_fail tampered "still passes codesign --verify — the flipped byte landed outside the sealed region"

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

    HAVE_OTHER_IDENTITY=0
    cp /bin/ls "$FIXTURES/other-identity"
    codesign --force --sign "$NON_DEVID" "$FIXTURES/other-identity" >/dev/null 2>&1
    # This fixture exists to prove the verifier does NOT demand Developer ID.
    # Its preconditions used to ask whether an `Authority=Developer ID
    # Application` line was ABSENT and whether any `^Authority=` line was
    # PRESENT. A /bin/ls copy whose signing silently failed satisfies both —
    # Apple's own authority is neither — so the fixture degraded into a
    # duplicate of identity-bound and its assertion passed while proving
    # nothing. That is R2-B5 reproduced inside the check written to prevent it
    # (round 8). It now demands the certificate we actually asked for.
    if signed_by "$FIXTURES/other-identity" "$NON_DEVID"; then
        HAVE_OTHER_IDENTITY=1
    else
        fixture_fail "other-identity" "not signed by the non-Developer-ID identity — it would silently duplicate identity-bound" || true
    fi
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
  && fixture_fail bare-identifier "its DR gained an anchor/certificate clause — it no longer represents the unprovable case"

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
          && fixture_fail "$1" "came out ad-hoc — it would never reach the shape check"
    }
    make_dr_fixture bare-identifier-signed 'identifier "com.foo.bar"'
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

# ── Fixtures added in round 10, each to make a declared @mutant die ──────
#
# Round 10 did not add these by reading the code and imagining gaps. It ran
# Tests/mutation-gate.sh, which reverts each declared fix and requires the suite
# to go red: 8 of 16 mutants survived a fully green 35-assertion run. Every
# fixture below exists because a specific revert was invisible to every one of
# those 35.

# Paths carrying characters that must never reach output unescaped. Built with
# python3 because macOS ships bash 3.2, whose printf has no \u escape — and
# written to per-key files rather than one list, because one of these paths
# CONTAINS a newline and no line-oriented format can carry it.
CTRL_DIR="$FIXTURES/ctrl"
mkdir -p "$CTRL_DIR"
if have bare-identifier-signed; then
    # A signed binary whose requirement shape is unrecognised (verdict 5). That
    # branch offers `codesign -d -r- <path>` to paste, which is the only place
    # an unprintable path is both reachable and consequential without first
    # needing the path to be one this project installs.
    python3 - "$FIXTURES/bare-identifier-signed" "$CTRL_DIR" <<'PY' || \
      fixture_fail ctrl-paths "could not create paths containing control characters"
import os, shutil, sys
src, d = sys.argv[1], sys.argv[2]
for key, name in (("nel",   "bad" + chr(0x85) + "name"),
                  ("rlo",   "bad" + chr(0x202e) + "name"),
                  ("forge", "x" + chr(0x0a) + chr(0x2713) + " durable: forged")):
    path = os.path.join(d, name)
    shutil.copy(src, path)
    with open(os.path.join(d, ".path." + key), "w") as fh:
        fh.write(path)
PY
    for k in nel rlo forge; do
        [[ -s "$CTRL_DIR/.path.$k" ]] || fixture_fail "ctrl-$k" "path file missing"
    done
else
    fixture_fail ctrl-paths "needs the unrecognised-shape fixture, which needs a signing identity"
    for k in nel rlo forge; do fixture_fail "ctrl-$k" "depends on ctrl-paths"; done
fi
ctrl_path() { cat "$CTRL_DIR/.path.$1"; }   # preserves an embedded newline

# A fake HOME, so the staging-suffix rule can be exercised at the one path it is
# defined against ($HOME/bin/safari-browser.XXXXXX) without writing into the
# real ~/bin. A test that damages the machine it runs on is not a test.
FAKE_HOME="$FIXTURES/fakehome"
mkdir -p "$FAKE_HOME/bin" || fixture_fail fakehome "could not create a fake home"
# suffix -> fixture name. abc123 is mktemp's actual shape (six from its
# alphabet); the other two are the shapes round 6's bare hasPrefix accepted.
for pair in "abc123:staging-valid" "abcdefg:staging-long" "ab12:staging-short"; do
    suf="${pair%%:*}"; name="${pair#*:}"
    cp /bin/ls "$FAKE_HOME/bin/safari-browser.$suf"
    break_seal "$FAKE_HOME/bin/safari-browser.$suf" \
      || fixture_fail "$name" "seal not broken — the fix-offering branch is unreachable"
done

# Entitlement values that are present but are not a boolean true. Round 8 closed
# the TYPE class here and nothing tested it: the suite's only entitlement-value
# fixture is <false/>, which is a boolean, so the branch that answers every
# other type was never reached.
for pair in "string:<string>false</string>" "integer:<integer>1</integer>"; do
    kind="${pair%%:*}"; xml="${pair#*:}"
    if [[ -z "${DEVID_ANY:-}" ]]; then
        fixture_fail "ent-$kind" "no signing identity"
        continue
    fi
    cp /bin/ls "$FIXTURES/ent-$kind"
    cat > "$FIXTURES/ent-$kind.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.automation.apple-events</key>$xml
</dict></plist>
PLIST
    codesign --force --options runtime --sign "$DEVID_ANY" \
        --entitlements "$FIXTURES/ent-$kind.plist" "$FIXTURES/ent-$kind" >/dev/null 2>&1 \
      || fixture_fail "ent-$kind" "codesign refused the $kind entitlements plist"
done

echo "Install-signature tests ($VERIFIER)"
echo

echo "── identity-bound signature (the good state) ──"
assert_fixture identity-bound assert_exit "identity-bound requirement passes" 0 "$FIXTURES/identity-bound"

echo
echo "── ad-hoc signature (the state #119 exists to catch) ──"
assert_fixture adhoc assert_exit "cdhash-bound requirement is rejected" 1 "$FIXTURES/adhoc"
assert_fixture adhoc assert_says "rejection names the rebuild consequence" "$FIXTURES/adhoc" "rebuild"
assert_fixture adhoc assert_says "rejection points at the fix" "$FIXTURES/adhoc" "install-signed"

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
assert_fixture adhoc-preserved assert_exit "ad-hoc with a preserved requirement is ad-hoc" 1 "$FIXTURES/adhoc-preserved"

echo
echo "── broken seal (#119 verify B1a) ──"
# Distinct from both: the metadata is fine, the signature is not, and macOS
# SIGKILLs the binary on launch. Reporting this as "grant survives rebuilds"
# is a claim about a binary that cannot start.
assert_fixture tampered assert_exit "tampered binary is rejected distinctly" 3 "$FIXTURES/tampered"
# "signature" alone would also match the SUCCESS line ("identity-bound
# signature"), so this asserts on a word only the broken-seal branch prints.
assert_fixture tampered assert_says "tampered rejection names the signature, not the requirement" "$FIXTURES/tampered" "code or signature have been modified"

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
if [[ "${HAVE_OTHER_IDENTITY:-0}" == "1" ]]; then
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
    assert_fixture anchor-in-string assert_exit "a keyword inside a quoted identifier is not a clause" 5 "$FIXTURES/anchor-in-string"
    assert_fixture negated assert_exit "a negated anchor is not an anchor" 5 "$FIXTURES/negated"
    assert_fixture version-pinned assert_exit "an anchored requirement with a version pin is not a known shape" 5 "$FIXTURES/version-pinned"
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
assert_fixture adhoc-preserved assert_exit "an ad-hoc binary is ad-hoc whatever its requirement says" 1 "$FIXTURES/adhoc-preserved"

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
echo "── the ad-hoc verdict answers first, whatever the DR says ──"
# What these two actually establish. Round 8: they were labelled as covering
# R3 ("a DR naming only an identifier"; "a DR pinning CFBundleVersion") and
# they cannot — both fixtures are ad-hoc, and the guard answers ad-hoc BEFORE
# it reads the requirement, so their .req files change nothing and ANY ad-hoc
# binary returns 1. They were vacuous with the fixtures built perfectly, not
# only when they degraded. On a plain clone they printed two ✓ for a
# regression that had not run.
#
# Kept, renamed to what they prove: ordering. R3 itself is covered below by
# real-identity fixtures, which is the only way to reach the shape matcher.
assert_fixture bare-identifier assert_exit "an ad-hoc binary is ad-hoc even with an identifier-only DR" 1 "$FIXTURES/bare-identifier"
if [[ "$HAVE_VERSION_BOUND" == "1" ]]; then
    assert_exit "an ad-hoc binary is ad-hoc even with a version-pinned DR" 1 "$FIXTURES/version-bound"
else
    skip "codesign did not retain the version-pinned requirement."
fi

echo
echo "── satisfiable but unprovable (#119 verify R3) ──"
# The actual R3 regression: a requirement that is satisfiable and stable but
# not a shape this tool was taught. It must say "cannot tell" (5), not guess
# in either direction — and reaching that code at all requires a REAL identity,
# which is why the ad-hoc pair above cannot stand in for it.
if [[ "$HAVE_SHAPE_FIXTURES" == "1" ]]; then
    assert_fixture bare-identifier-signed assert_exit "an identifier-only requirement is not a shape we know" 5 "$FIXTURES/bare-identifier-signed"
else
    skip "no signing identity — the R3 identifier-only case is unverified"
fi

echo "── unsigned / unreadable (must NOT be mistaken for the good state) ──"
# The trap this guards: `codesign -d -r-` exits 1 on an unsigned binary and
# prints no requirement at all, so a verifier that only greps for `cdhash`
# sees a miss and reports success. Unsigned must be its OWN exit code, not 0
# and not the ad-hoc code, or the two failures cannot be told apart.
assert_fixture unsigned assert_exit "unsigned binary is rejected distinctly" 2 "$FIXTURES/unsigned"
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
    assert_fixture identity-bound assert_exit \
        "--require-shape rejects a different durable shape as 6, not 4" 6 \
        --require-shape "Developer ID" "$FIXTURES/identity-bound"
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
        assert_fixture ent-denied assert_exit "an entitlement set to <false/> does not satisfy the gate" 7 \
            --require-entitlement com.apple.security.automation.apple-events "$FIXTURES/ent-denied"
    else
        fixture_fail "ent-denied" "codesign refused the denying entitlements plist"
    fi
    # Ordering: the ad-hoc verdict comes first. Round 7 evaluated the
    # entitlement before it, so an ad-hoc binary was answered 7 and the message
    # explained the wrong fault.
    assert_fixture adhoc assert_exit "an ad-hoc binary is answered 1, not the entitlement contract" 1 \
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
        pass "no-argument form resolves a default target" "(exit $rc)"
    else
        fail "no-argument form resolves a default target" \
             "got exit $rc, which is not in the guard's declared vocabulary ($KNOWN_CODES)"
    fi
else
    skip "no installed binary at ~/bin/safari-browser to resolve as the default"
fi

echo
echo "── a destructive prescription reaches only our own install (#119 R5/R6) ──"
# R5 told a user to `rm -f` the executable of a working copy of Anki. R6 then
# found the narrowing itself too loose. Both fixes were measured by the round-10
# mutation gate as invisible to the whole suite: reverting either left 35/35.
#
# The reason is structural, not an oversight — every assertion above checks an
# exit code or a phrase the tool DOES print, and this class of defect is
# entirely about a phrase it must NOT print, on a path nobody was testing.
assert_fixture tampered assert_says \
    "a broken seal outside our install names the refusal" \
    "$FIXTURES/tampered" "not a path this project installs"
assert_fixture tampered assert_says_not \
    "a broken seal outside our install is offered no rm -f" \
    "$FIXTURES/tampered" "rm -f"
with_home "$FAKE_HOME" assert_fixture staging-valid assert_says \
    "the staging file install-signed verifies IS ours" \
    "$FAKE_HOME/bin/safari-browser.abc123" "rm -f"
# Spelled with a `.` component, which denotes the same directory. Deliberately
# NOT "a doubled slash": that is what TMPDIR happens to produce on this machine,
# and a fixture whose discriminating power depends on the developer's
# environment is the defect round 6 found in the requirement-SET case.
with_home "$FAKE_HOME/." assert_fixture staging-valid assert_says \
    "a HOME spelled non-canonically still resolves to our install" \
    "$FAKE_HOME/bin/safari-browser.abc123" "rm -f"
with_home "$FAKE_HOME" assert_fixture staging-long assert_says_not \
    "a seven-character suffix is not mktemp's shape" \
    "$FAKE_HOME/bin/safari-browser.abcdefg" "rm -f"
with_home "$FAKE_HOME" assert_fixture staging-short assert_says_not \
    "a four-character suffix is not mktemp's shape" \
    "$FAKE_HOME/bin/safari-browser.ab12" "rm -f"

echo
echo "── control characters in a path never reach output unescaped (#119 R7/R8) ──"
# The existing forge assertion (further up) runs against an UNSIGNED fixture,
# which exits 2 on a branch that offers no command at all — so it never reaches
# the printability test it was written to cover. That is why reverting
# `targetIsPrintable` to a constant true changed nothing the suite could see.
# These run on the unrecognised-shape branch, which does offer a command.
assert_fixture ctrl-nel assert_says \
    "a NEL in the path suppresses the paste-ready command" \
    "$(ctrl_path nel)" "no paste-ready command"
assert_fixture ctrl-rlo assert_says \
    "a bidi override in the path suppresses the paste-ready command" \
    "$(ctrl_path rlo)" "no paste-ready command"
assert_fixture ctrl-forge assert_no_forged_line \
    "a newline in the path cannot forge a verdict through the inspect command" \
    "$(ctrl_path forge)"

echo
echo "── the entitlement gate wants a boolean true, not merely a value (#119 R8) ──"
assert_fixture ent-string assert_exit \
    "an entitlement carrying a string is not a boolean true" 7 \
    --require-entitlement com.apple.security.automation.apple-events "$FIXTURES/ent-string"
assert_fixture ent-integer assert_exit \
    "an entitlement carrying an integer is not a boolean true" 7 \
    --require-entitlement com.apple.security.automation.apple-events "$FIXTURES/ent-integer"

echo
echo "── a flag's value is a name, and an unknown flag is not a target (#119 R6/R8) ──"
# Both of these were fixed and neither was tested. The misspelled-flag assertion
# above passes on the pristine guard AND with the unknown-option fix reverted,
# because three positionals then trip the extra-path check instead — a green
# assertion standing in front of a branch it never reaches.
assert_exit "an absolute path where a shape name belongs is a usage error" 64 \
    --require-shape /bin/ls
assert_exit "a relative path where a shape name belongs is a usage error" 64 \
    --require-shape ./nonexistent
assert_exit "an unknown option alone is a usage error, not a target" 64 \
    --require-shapee

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
