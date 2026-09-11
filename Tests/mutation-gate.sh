#!/bin/bash
# Mutation gate for the install-signature guard (#119).
#
# Reverts each fix declared `// @mutant(...)` in the guard, one at a time, and
# requires the install-signature suite to go red on a NAMED assertion that was
# green before. A mutant the suite cannot tell from the original SURVIVES, and
# a surviving mutant fails this gate.
#
# Why it exists. After nine review rounds the suite had 35 green assertions.
# Reverting three separate fixes — R5's `isOurInstall`, R7's `targetIsPrintable`
# and R8's entitlement type ladder — left it at 35/35, rc 0, every time. Each
# round had added assertions for the INSTANCE it had just fixed, and nothing had
# ever asked whether those assertions could detect the fix being removed. Nine
# rounds of "the suite is green" was nine rounds of evidence about nothing.
#
# Three distinctions this gate refuses to blur, each of them a defect this
# thread produced at least once:
#
#   * A kill is an assertion flipping PASS -> FAIL, not a non-zero exit. The
#     suite also exits non-zero when a fixture degrades and when the skip
#     accounting fires. Neither shows that anything can see the mutation.
#   * A compile failure is a broken MUTANT, not a killed one. Reporting it as a
#     kill is how a gate comes to certify its own malfunction.
#   * A baseline that skips anything cannot support a claim about the cases that
#     did not run, so this refuses to start on a partial run.
#
# Two boundaries, stated rather than implied:
#
#   * Nothing here establishes that every fix HAS a declaration. A fix can be one
#     character, and no extraction can tell a line that closes a review finding
#     from any other line. Declaring a mutant alongside a fix is a review
#     obligation; this gate only enforces that declared mutants die. Deleting a
#     declaration would also silence it — the declaration carries the prose
#     explaining which round and which defect, so removing one is visible in a
#     diff, which is the only guard there is.
#   * A declaration whose <to> compiles but changes no behaviour would be
#     reported as a survivor, sending a reader to write an assertion for a fix
#     that is still present. Identical SOURCE is caught below; a semantic no-op
#     is not, because swiftc is not byte-deterministic for identical input
#     (measured, so binary comparison is unavailable). When a survivor is
#     reported, confirm the revert actually changes an answer before treating it
#     as a gap in the suite.
#
# Usage:
#   make test-mutation-gate
#   ./Tests/mutation-gate.sh                 # all declared mutants
#   ./Tests/mutation-gate.sh printable-always ent-nonbool-granted
#
# Exit 0 = every declared mutant died. 1 = at least one survived.
#        2 = the gate could not run (bad declaration, compile failure,
#            unusable baseline) — which is not a verdict about the suite.
set -u

GUARD_SRC="${GUARD_SRC:-}"
SUITE="${SUITE:-Tests/install-signature-test.sh}"

for f in "${GUARD_SRC:-scripts/verify-install-signature.swift}" "$SUITE"; do
    [[ -r "$f" ]] || { echo "✗ cannot read $f — run this from the repository root" >&2; exit 2; }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutation-gate.XXXXXX") || {
    echo "✗ could not create a work directory" >&2; exit 2; }
[[ -n "$WORK" && -d "$WORK" ]] || { echo "✗ work directory missing" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
# Compile and mutate the exact same shared assessment plus CLI wrapper used
# by normal builds. An explicit GUARD_SRC remains a full-source test override.
if [[ -z "$GUARD_SRC" ]]; then
    GUARD_SRC="$WORK/combined.swift"
    python3 scripts/build-signature-guard.py --emit-source "$GUARD_SRC" || exit 2
fi

# ── Read the declarations out of the guard ────────────────────────────────
# Emits one `id<TAB>lineno<TAB>from<TAB>to` record per mutant. The target is the
# first line after the declaration that is neither blank nor a comment; <from>
# must occur exactly once in it. Anything else is a malformed declaration and
# stops the gate, because a declaration the gate cannot apply is indistinguish-
# able from a mutant that was never tested.
python3 - "$GUARD_SRC" > "$WORK/mutants.tsv" <<'PY' || exit 2
import re, sys
src = open(sys.argv[1]).read().split('\n')
DECL = re.compile(r'^\s*//\s*@mutant\(([a-z0-9][a-z0-9-]*)\)\s+(.+?)\s+=>\s+(.*?)\s*$')
seen, out, errs = set(), [], []
for i, line in enumerate(src):
    m = DECL.match(line)
    if not m:
        continue
    mid, frm, to = m.group(1), m.group(2), m.group(3)
    if mid in seen:
        errs.append(f"{mid}: declared more than once")
        continue
    seen.add(mid)
    j = i + 1
    while j < len(src) and (not src[j].strip() or src[j].strip().startswith('//')):
        j += 1
    if j >= len(src):
        errs.append(f"{mid}: declaration has no target line after it")
        continue
    n = src[j].count(frm)
    if n != 1:
        errs.append(f"{mid}: target line contains {n} occurrences of «{frm}», need exactly 1\n"
                    f"      target (line {j+1}): {src[j].strip()[:120]}")
        continue
    out.append('\t'.join([mid, str(j + 1), frm, to]))
if errs:
    sys.stderr.write("✗ malformed @mutant declarations:\n")
    for e in errs:
        sys.stderr.write("    " + e + "\n")
    sys.exit(2)
if not out:
    sys.stderr.write("✗ no @mutant declarations found in the guard.\n")
    sys.exit(2)
print('\n'.join(out))
PY

TOTAL=$(wc -l < "$WORK/mutants.tsv" | tr -d ' ')

# Optional id filter from argv.
if [[ $# -gt 0 ]]; then
    : > "$WORK/wanted.tsv"
    for want in "$@"; do
        if ! awk -F'\t' -v w="$want" '$1==w {print; found=1} END {exit !found}' \
               "$WORK/mutants.tsv" >> "$WORK/wanted.tsv"; then
            echo "✗ no declared mutant named '$want'. Declared: $(cut -f1 "$WORK/mutants.tsv" | tr '\n' ' ')" >&2
            exit 2
        fi
    done
    mv "$WORK/wanted.tsv" "$WORK/mutants.tsv"
fi
RUNNING=$(wc -l < "$WORK/mutants.tsv" | tr -d ' ')

echo "Mutation gate — $RUNNING of $TOTAL declared mutant(s)"
echo

# run_suite <verifier-binary> <result-log>  -> suite's exit status
run_suite() {
    VERIFY_INSTALL_SIGNATURE="$1" INSTALL_SIGNATURE_RESULT_LOG="$2" \
        ALLOW_INCOMPLETE= bash "$SUITE" > "${2%.log}.out" 2>&1
}

# ── Baseline ─────────────────────────────────────────────────────────────
echo "── baseline (pristine guard) ──"
if ! swiftc -O -o "$WORK/baseline.bin" "$GUARD_SRC" 2> "$WORK/baseline.compile"; then
    echo "✗ the pristine guard does not compile — fix that first, it is not a suite result" >&2
    sed 's/^/    /' "$WORK/baseline.compile" | head -10 >&2
    exit 2
fi
run_suite "$WORK/baseline.bin" "$WORK/baseline.log"
BASE_RC=$?
BASE_PASS=$(awk -F'\t' '$1=="PASS"' "$WORK/baseline.log" 2>/dev/null | wc -l | tr -d ' ')
BASE_FAIL=$(awk -F'\t' '$1=="FAIL"' "$WORK/baseline.log" 2>/dev/null | wc -l | tr -d ' ')
BASE_SKIP=$(awk -F'\t' '$1=="SKIP"' "$WORK/baseline.log" 2>/dev/null | wc -l | tr -d ' ')
echo "  $BASE_PASS passed, $BASE_FAIL failed, $BASE_SKIP skipped (suite rc=$BASE_RC)"

if [[ "$BASE_RC" != "0" || "$BASE_FAIL" != "0" || "$BASE_SKIP" != "0" ]]; then
    echo >&2
    echo "✗ the gate needs a fully green baseline with nothing skipped." >&2
    echo "  A mutant 'killed' by a case that was already failing, or by one that" >&2
    echo "  does not run on this machine, has not been shown to be visible to any" >&2
    echo "  assertion. This machine needs BOTH a Developer ID and a" >&2
    echo "  non-Developer-ID signing identity; see the suite's skip notes:" >&2
    sed 's/^/      /' "$WORK/baseline.out" | grep -E '⊘|✗' | head -12 >&2
    exit 2
fi

# The join key must be unique, or "this label flipped" is ambiguous.
if [[ "$(cut -f2 "$WORK/baseline.log" | sort | uniq -d | wc -l | tr -d ' ')" != "0" ]]; then
    echo "✗ duplicate assertion labels in the baseline — the gate joins on the label:" >&2
    cut -f2 "$WORK/baseline.log" | sort | uniq -d | sed 's/^/      /' >&2
    exit 2
fi
cut -f2 "$WORK/baseline.log" | sort > "$WORK/baseline.labels"
echo

# ── Mutants ──────────────────────────────────────────────────────────────
SURVIVED=""; KILLED=0; ERRORED=""
while IFS=$'\t' read -r id lineno frm to; do
    [[ -n "$id" ]] || continue
    printf '── %s ──\n' "$id"
    MSRC="$WORK/$id.swift"

    python3 - "$GUARD_SRC" "$MSRC" "$lineno" "$frm" "$to" <<'PY'
import sys
src_p, dst_p, lineno, frm, to = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
lines = open(src_p).read().split('\n')
i = lineno - 1
assert lines[i].count(frm) == 1, "from-text is no longer unique on the target line"
lines[i] = lines[i].replace(frm, to, 1)
open(dst_p, 'w').write('\n'.join(lines))
PY
    if [[ $? -ne 0 ]]; then
        echo "  ‼ GATE ERROR: could not apply the mutation"
        ERRORED="$ERRORED $id"; echo; continue
    fi

    # A declaration whose <from> and <to> are the same text reverts nothing, and
    # would be reported as a survivor — sending a reader to add an assertion for
    # a fix that was never removed. Cheap and sound, unlike comparing the
    # compiled binaries: swiftc is not byte-deterministic for identical input
    # (measured), so a no-op at the SEMANTIC level cannot be detected this way.
    # See the boundary note in the header.
    if cmp -s "$GUARD_SRC" "$MSRC"; then
        echo "  ‼ GATE ERROR: the mutation left the source unchanged — <from> and"
        echo "    <to> are the same text, so there is nothing to revert."
        ERRORED="$ERRORED $id"; echo; continue
    fi

    # A mutant that does not compile has not been tested. Reporting the
    # resulting red suite as a kill would certify the gate's own malfunction.
    if ! swiftc -O -o "$WORK/$id.bin" "$MSRC" 2> "$WORK/$id.compile"; then
        echo "  ‼ GATE ERROR: the mutant does not compile — this is a broken"
        echo "    declaration, NOT a killed mutant. Revise <to> so the revert is"
        echo "    valid Swift:"
        grep -E 'error:' "$WORK/$id.compile" | head -3 | sed 's/^/      /'
        ERRORED="$ERRORED $id"; echo; continue
    fi

    run_suite "$WORK/$id.bin" "$WORK/$id.log"

    # Same cases must have run, or the comparison is not like for like.
    cut -f2 "$WORK/$id.log" | sort > "$WORK/$id.labels"
    if ! diff -q "$WORK/baseline.labels" "$WORK/$id.labels" >/dev/null; then
        echo "  ‼ GATE ERROR: the mutant changed WHICH assertions ran, so a flip"
        echo "    cannot be attributed. Differences:"
        diff "$WORK/baseline.labels" "$WORK/$id.labels" | head -6 | sed 's/^/      /'
        ERRORED="$ERRORED $id"; echo; continue
    fi

    # The kill condition: a label green at baseline is red here.
    join -t$'\t' -1 1 -2 1 \
        <(awk -F'\t' '$1=="PASS" {print $2}' "$WORK/baseline.log" | sort) \
        <(awk -F'\t' '$1=="FAIL" {print $2}' "$WORK/$id.log" | sort) \
        > "$WORK/$id.flips"
    FLIPS=$(wc -l < "$WORK/$id.flips" | tr -d ' ')

    if [[ "$FLIPS" -gt 0 ]]; then
        echo "  ✓ killed by $FLIPS assertion(s):"
        sed 's/^/      ✗ /' "$WORK/$id.flips" | head -4
        [[ "$FLIPS" -gt 4 ]] && echo "      … and $((FLIPS - 4)) more"
        KILLED=$((KILLED + 1))
    else
        echo "  ✗ SURVIVED — every assertion that passed on the pristine guard"
        echo "    still passes with this fix reverted. The suite cannot see it."
        echo "    Revert:  line ${lineno}, «${frm}» -> «${to}»"
        SURVIVED="$SURVIVED $id"
    fi
    echo
done < "$WORK/mutants.tsv"

# ── Report ───────────────────────────────────────────────────────────────
echo "────────────────────────────────────────────────────────────"
echo "Killed: $KILLED / $RUNNING"
RC=0
if [[ -n "$ERRORED" ]]; then
    echo
    echo "Gate errors (neither killed nor survived — nothing was measured):"
    for id in $ERRORED; do echo "  ‼ $id"; done
    RC=2
fi
if [[ -n "$SURVIVED" ]]; then
    echo
    echo "SURVIVORS — each names a fix the suite cannot detect the loss of:"
    for id in $SURVIVED; do echo "  ✗ $id"; done
    echo
    echo "  Add an assertion that fails when that fix is absent. An assertion"
    echo "  about the instance the fix was written for is what the suite already"
    echo "  has; what is missing is one that the revert breaks."
    [[ "$RC" == "0" ]] && RC=1
fi
[[ "$RC" == "0" ]] && echo && echo "✓ every declared mutant died on a named assertion."
exit $RC
