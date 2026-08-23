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
#   5  a requirement shape this tool does not recognise — cannot tell
#
# What this tool will and will not answer (narrowed in round 3):
#
#   It recognises the designated requirements that a standard `codesign`
#   invocation produces — an identifier plus an `anchor` and/or `certificate`
#   clause, or a bare cdhash. For those it gives a verdict. For anything else
#   it says it CANNOT TELL (exit 5) rather than guessing.
#
#   The narrowing is the point. Three rounds of review each constructed a new
#   requirement shape that walked between the previous round's exclusions:
#
#     v1  success = "the DR does not contain cdhash".
#         Broken by --preserve-metadata: an ad-hoc signature carrying someone
#         else's identity-bound DR.
#     v2  success = that, and "the signature is not ad-hoc".
#         Broken by signing with a real certificate while preserving a
#         DIFFERENT certificate's DR.
#     v3  success = that, and "the binary satisfies its own DR".
#         Broken twice: a DR naming only an identifier (satisfiable by an
#         ad-hoc signature, and by anything else claiming that identifier),
#         and a DR pinning info[CFBundleVersion] (stable across a rebuild,
#         not across a version bump).
#
#   Each version added an exclusion and each time the next input walked
#   between them, because success was still decided by what was ABSENT.
#   Success is now decided by what is PRESENT: the DR must name an anchor or
#   a certificate. A shape this tool has not been taught gets exit 5, so the
#   residual error is "refuses to vouch for something durable" rather than
#   "vouches for something that is not".
#
#   Notably NOT required: a Developer ID authority. /bin/ls is Apple-signed
#   and its grant is durable. Whether the certificate is specifically
#   Developer ID is `install-signed`'s contract, asserted there.
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

# ── 3. Is the requirement a shape we recognise as stable? ───────────────
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

# Positive recognition. Absence of `cdhash` is not evidence of durability —
# `identifier "x"` alone has none, and `info[CFBundleVersion] = "1"` breaks at
# the next version bump. Both were constructed by review after earlier
# versions decided success by exclusion. An anchor or certificate clause is
# what actually ties the requirement to an identity rather than to bytes.
if ! printf '%s' "$REQUIREMENT" | grep -qE '(^|[^[:alnum:]_])(anchor|certificate)([^[:alnum:]_]|$)'; then
    echo "✗ cannot tell whether this grant is durable: $TARGET" >&2
    printf '%s\n' "$REQUIREMENT" | sed 's/^/  DR: /' >&2
    echo >&2
    echo "  The requirement names no anchor and no certificate, so there is no" >&2
    echo "  identity tying it to a signer. This tool only vouches for shapes it" >&2
    echo "  recognises, and it does not recognise this one — the honest answer" >&2
    echo "  is that it does not know, not that the grant is durable." >&2
    echo >&2
    echo "  Two ways a requirement like this bites: an ad-hoc signature can" >&2
    echo "  satisfy it (so the grant is no more durable than the bytes), and so" >&2
    echo "  can any other binary claiming the same identifier." >&2
    echo >&2
    echo "  Fix:  DEVELOPER_ID=<cert-sha1> make install-signed" >&2
    exit 5
fi

# ── 4. Does the binary satisfy its OWN requirement? ──────────────────────
# An unchecked mktemp made every temp-dir problem look like a signature
# defect: the redirect failed, `-R ""` failed, and the binary was reported as
# unable to satisfy its own requirement. install-signed gates on this script,
# so a broken TMPDIR refused correctly-signed binaries. Infrastructure
# failures must not be reported as verdicts about the binary.
REQ_FILE=$(mktemp "${TMPDIR:-/tmp}/verify-install-dr.XXXXXX") || {
    echo "✗ could not create a temporary file (TMPDIR=${TMPDIR:-/tmp})" >&2
    echo "  This is an environment problem, not a verdict about $TARGET." >&2
    exit 2
}
trap 'rm -f "$REQ_FILE"' EXIT
printf '%s\n' "$REQUIREMENT" > "$REQ_FILE" || {
    echo "✗ could not write the requirement file: $REQ_FILE" >&2
    echo "  This is an environment problem, not a verdict about $TARGET." >&2
    exit 2
}

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
