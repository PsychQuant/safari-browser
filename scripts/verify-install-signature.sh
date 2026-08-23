#!/bin/bash
# Does the installed binary hold a Full Disk Access grant that survives a
# rebuild? (#119)
#
# TCC stores a binary's *designated requirement* (DR), not its path, and
# re-evaluates it every time. So the grant is durable exactly when:
#
#   1. the signature seal is intact          (else macOS SIGKILLs the binary)
#   2. the binary SATISFIES its own DR       (else the grant never applies)
#   3. the DR is not the content hash        (else a rebuild invalidates it)
#
# Reads only. No Full Disk Access, no certificate, no Safari.
#
#   0  durable: valid seal, satisfies its own DR, DR is identity-bound
#   1  ad-hoc / cdhash-bound DR — grant dies on the next rebuild
#   2  no readable signature at all (unsigned, missing, or not code)
#   3  seal is broken — macOS will SIGKILL this binary
#   4  signed, valid seal, but CANNOT SATISFY ITS OWN DR — grant never applies
#
# Check 2 is the one that took two verify rounds to arrive at, and it is worth
# saying why the two earlier versions were wrong:
#
#   v1 asked whether the DR *looked* identity-bound (no `cdhash` substring).
#      `codesign --force --sign - --preserve-metadata=requirements` copies an
#      identity-bound DR onto a signature with no certificate chain, so the
#      binary prints a DR it can never satisfy. v1 passed it.
#
#   v2 added the seal check and `Signature=adhoc`, which caught that specific
#      input — but the SUCCESS branch was still negative ("not ad-hoc and not
#      cdhash"). Sign with a real certificate while preserving a DIFFERENT
#      certificate's DR and every negative check passes. v2 passed that too.
#
# The fix is not another exclusion. `codesign --verify` given any `-R` also
# reports whether the code satisfies its designated requirement, so feeding
# the binary its OWN DR turns the question into a positive one and closes the
# whole family at once — including variants nobody has constructed yet.
#
# Note what is deliberately NOT required: a Developer ID authority. `/bin/ls`
# is Apple-signed, not Developer ID, and its grant is perfectly durable. The
# question is whether the DR is stable and satisfiable, not who issued it.
# `install-signed` separately asserts Developer ID, because that is ITS
# contract — not this script's.
#
# Known boundary, stated rather than guarded: a DR of the bare form
# `identifier "x"`, with no anchor or certificate clause, is stable across
# rebuilds AND satisfiable by an ad-hoc signature, so it would exit 0 here.
# Such a grant really would survive a rebuild — it would also be satisfied by
# any other binary claiming that identifier, which is a different problem and
# not one this script is asked about. codesign does not produce that shape on
# its own; it takes an explicit `-r`. Left unguarded deliberately: a check for
# it would be a check for something nothing in this repo can emit.
set -u

TARGET="${1:-$HOME/bin/safari-browser}"

# ── 1. Seal ──────────────────────────────────────────────────────────────
SEAL=$(codesign --verify --strict "$TARGET" 2>&1)
if [ $? -ne 0 ]; then
    if printf '%s' "$SEAL" | grep -q 'not signed at all'; then
        echo "✗ no code signature: $TARGET" >&2
        echo "  An unsigned binary cannot hold a Full Disk Access grant." >&2
        exit 2
    fi
    if [ ! -e "$TARGET" ]; then
        echo "✗ no such file: $TARGET" >&2
        exit 2
    fi
    echo "✗ broken seal: $TARGET" >&2
    echo "  codesign said: $(printf '%s' "$SEAL" | head -1)" >&2
    echo >&2
    echo "  The signature no longer covers the bytes. macOS refuses to run this" >&2
    echo "  binary — it dies with SIGKILL (exit 137) and no readable error. The" >&2
    echo "  Full Disk Access question does not arise: TCC never evaluates the" >&2
    echo "  requirement of code whose seal is invalid." >&2
    echo >&2
    echo "  Fix:  rm -f \"$TARGET\" && DEVELOPER_ID=<cert-sha1> make install-signed" >&2
    exit 3
fi

# ── 2. Read the DR ───────────────────────────────────────────────────────
# Every codesign exit status below is checked. An earlier version captured
# these into variables and looked only at their TEXT, so a failed call whose
# error message happened not to contain the bad keyword fell through to the
# success branch.
RAW_DR=$(codesign -d -r- "$TARGET" 2>&1)
if [ $? -ne 0 ]; then
    echo "✗ could not read the designated requirement: $TARGET" >&2
    echo "  codesign said: $(printf '%s' "$RAW_DR" | head -1)" >&2
    exit 2
fi
# Drop the `Executable=<path>` line so an install path containing `cdhash`
# cannot be read as part of the answer, and strip the `designated => ` prefix
# so what remains is valid requirement syntax for -R.
# codesign emits an ad-hoc DR COMMENTED OUT (`# designated => cdhash H"..."`),
# so the marker has to come off too — leaving it in produced a requirement file
# that was entirely a comment, which -R then rejected as malformed and which
# this script mis-reported as "cannot satisfy its own requirement".
REQUIREMENT=$(printf '%s\n' "$RAW_DR" | grep -v '^Executable=' | sed -E 's/^#[[:space:]]*//; s/^designated => //')
if [ -z "$REQUIREMENT" ]; then
    echo "✗ empty designated requirement: $TARGET" >&2
    exit 2
fi

# ── 3. Is the requirement stable across rebuilds? ────────────────────────
if printf '%s' "$REQUIREMENT" | grep -q 'cdhash'; then
    echo "✗ cdhash-bound requirement: $TARGET" >&2
    printf '%s\n' "$REQUIREMENT" | sed 's/^/  /' >&2
    echo >&2
    echo "  The requirement IS the content hash, so a rebuild changes it and any" >&2
    echo "  Full Disk Access grant stops applying — silently, with no error at" >&2
    echo "  the moment it breaks." >&2
    echo >&2
    echo "  Fix:  DEVELOPER_ID=<cert-sha1> make install-signed" >&2
    exit 1
fi

# ── 4. Does the binary satisfy its OWN requirement? ──────────────────────
REQ_FILE=$(mktemp "${TMPDIR:-/tmp}/verify-install-dr.XXXXXX")
trap 'rm -f "$REQ_FILE"' EXIT
printf '%s\n' "$REQUIREMENT" > "$REQ_FILE"

SATISFIES=$(codesign --verify -R "$REQ_FILE" "$TARGET" 2>&1)
if [ $? -ne 0 ]; then
    echo "✗ does not satisfy its own designated requirement: $TARGET" >&2
    printf '%s\n' "$REQUIREMENT" | sed 's/^/  DR: /' >&2
    codesign -dvv "$TARGET" 2>&1 | grep -E '^Authority=' | head -1 | sed 's/^/  actual: /' >&2
    echo >&2
    echo "  codesign said: $(printf '%s' "$SATISFIES" | grep -v 'valid on disk' | head -1)" >&2
    echo >&2
    echo "  The seal is intact, but this binary can never satisfy the requirement" >&2
    echo "  it advertises — usually a signature made with one identity while" >&2
    echo "  preserving another identity's requirement. TCC records the DR when" >&2
    echo "  you grant Full Disk Access, so the grant would never apply." >&2
    echo >&2
    echo "  Fix:  DEVELOPER_ID=<cert-sha1> make install-signed" >&2
    exit 4
fi

echo "✓ durable: valid seal, satisfies its own requirement, identity-bound"
echo "  $TARGET"
printf '%s\n' "$REQUIREMENT" | sed 's/^/  /'
echo "  A Full Disk Access grant on this binary survives rebuilds."

# Informational only — not a failure. The grant is durable regardless of who
# issued the certificate, but the CLI's own CodeSigningState classifier keys
# on `Authority=Developer ID Application` and reports anything else as
# .unknown, so its FDA guidance will be the generic one.
if ! codesign -dvv "$TARGET" 2>&1 | grep -q 'Authority=Developer ID Application'; then
    AUTH=$(codesign -dvv "$TARGET" 2>&1 | grep -E '^Authority=' | head -1)
    echo
    echo "  note: signed by ${AUTH#Authority=} — not a Developer ID certificate."
    echo "  The grant is still durable, but safari-browser's own signing-state"
    echo "  classifier reports this build as 'unknown', so its permission"
    echo "  guidance will be generic rather than tailored."
fi
