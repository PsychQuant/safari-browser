#!/bin/bash
# Will a Full Disk Access grant on this binary still apply later? (#119)
#
# TCC stores the binary's designated requirement (DR) and re-evaluates it, so
# the grant is durable exactly when the DR names an identity the binary keeps
# across rebuilds — rather than its bytes, which change every build.
#
#   0  durable: a recognised identity-bound shape, and the binary satisfies it
#   1  ad-hoc signature — the DR is the content hash, so a rebuild kills it
#   2  no signature, or the check could not run (environment, not a verdict)
#   3  seal broken — macOS SIGKILLs this binary, so the question never arises
#   4  recognised shape, but this binary cannot satisfy it — grant never applies
#   5  a requirement shape this tool does not recognise — it cannot tell
#
# ── Why it is built this way ─────────────────────────────────────────────
#
# Four rounds of review defeated four successive criteria, each by
# constructing an input the previous one had not imagined:
#
#   v1  "the DR does not contain cdhash"     → --preserve-metadata carries an
#                                               identity-bound DR onto an
#                                               ad-hoc signature
#   v2  + "the signature is not ad-hoc"      → sign with one certificate while
#                                               preserving another's DR
#   v3  + "the binary satisfies its own DR"  → a DR naming only an identifier;
#                                               a DR pinning CFBundleVersion
#   v4  "the DR must contain anchor or       → identifier "com.foo.anchor";
#        certificate"                          identifier "x" and !(anchor apple)
#
# v4 is the instructive one. Its criterion was inverted from exclusion to
# inclusion — the right direction — but the implementation was still `grep`
# over a language that has string literals, boolean operators, negation and
# parentheses. Changing what the rule SAID without changing what the code
# could SEE bought nothing: a word inside a quoted identifier reads the same
# to grep as a clause, and so does a negated one.
#
# So this version stops trying to judge arbitrary requirements. Two decisions
# instead, in this order:
#
#   1. Observable facts, no parsing. Is the seal intact? Is the signature
#      ad-hoc? Both come straight out of `codesign` as fields — the same
#      source CodeSigningState.parse() reads, so the CLI and this script
#      cannot disagree about one binary.
#
#   2. Shape recognition, whole-line and anchored. The DR must match one of
#      the forms a standard `codesign` invocation emits, end to end, with
#      quoted strings matched as opaque `"[^"]*"` groups so their contents
#      cannot leak into the structure. Anything else is exit 5 — not a
#      failure, an admission.
#
# The residual error is now "refuses to vouch for a requirement nobody taught
# it" rather than "vouches for one it misread". That claim is worth exactly
# what the next attempt to break it establishes, and no more.
set -u

TARGET="${1:-$HOME/bin/safari-browser}"

env_problem() {
    echo "✗ $1" >&2
    echo "  This is an environment problem, not a verdict about $TARGET." >&2
    exit 2
}

# ── 1. Seal ──────────────────────────────────────────────────────────────
SEAL=$(codesign --verify --strict "$TARGET" 2>&1)
if [ $? -ne 0 ]; then
    if printf '%s' "$SEAL" | grep -q 'not signed at all'; then
        echo "✗ no code signature: $TARGET" >&2
        echo "  An unsigned binary cannot hold a Full Disk Access grant." >&2
        exit 2
    fi
    [ -e "$TARGET" ] || { echo "✗ no such file: $TARGET" >&2; exit 2; }
    echo "✗ broken seal: $TARGET" >&2
    echo "  codesign said: $(printf '%s' "$SEAL" | head -1)" >&2
    echo >&2
    echo "  The signature no longer covers the bytes, so macOS refuses to run" >&2
    echo "  this binary — SIGKILL, exit 137, no readable error. TCC never" >&2
    echo "  evaluates the requirement of code whose seal is invalid." >&2
    echo >&2
    echo "  Fix:  rm -f \"$TARGET\" && DEVELOPER_ID=<cert-sha1> make install-signed" >&2
    exit 3
fi

# ── 2. Observable facts ──────────────────────────────────────────────────
# `Signature=adhoc` is a field, not something inferred from requirement text.
# CodeSigningState.parse() keys on the same string, so the two implementations
# cannot disagree about the same binary — they did in round 2, and reading the
# same field is what stops it happening again.
DETAILS=$(codesign -dvv "$TARGET" 2>&1) \
    || env_problem "could not read the signature of $TARGET"

if printf '%s\n' "$DETAILS" | grep -q '^Signature=adhoc'; then
    echo "✗ ad-hoc signature: $TARGET" >&2
    printf '%s\n' "$DETAILS" | grep -E '^Signature=|^TeamIdentifier=' | sed 's/^/  /' >&2
    echo >&2
    echo "  An ad-hoc signature has no certificate behind it, so its designated" >&2
    echo "  requirement is the binary's own content hash. A rebuild changes the" >&2
    echo "  hash, and any Full Disk Access grant stops applying — silently." >&2
    echo >&2
    echo "  Fix:  DEVELOPER_ID=<cert-sha1> make install-signed" >&2
    exit 1
fi

# ── 3. The designated requirement, and only it ───────────────────────────
# `codesign -d -r-` can emit a requirement SET — real Developer ID apps on
# this machine do, carrying `host => ...` alongside `designated => ...`. An
# earlier version stripped the prefix from EVERY line and fed the lot to -R,
# which then failed to parse; that parse failure was printed as a verdict
# about the binary, condemning textbook-durable applications.
RAW=$(codesign -d -r- "$TARGET" 2>&1) \
    || env_problem "could not read the designated requirement of $TARGET"

REQUIREMENT=$(printf '%s\n' "$RAW" \
    | sed -E 's/^#[[:space:]]*//' \
    | grep '^designated => ' | head -1 \
    | sed 's/^designated => //' \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')

if [ -z "$REQUIREMENT" ]; then
    env_problem "no 'designated =>' line in codesign's output for $TARGET"
fi

# ── 4. Is it a shape we recognise? ───────────────────────────────────────
# Whole-line anchored templates, with quoted strings as opaque groups. That is
# the difference from every previous version: `identifier "com.foo.anchor"`
# cannot match the Apple template, because the template requires
# ` and anchor apple` AFTER the closing quote. What is inside the string is
# never looked at, so it cannot be mistaken for structure.
# codesign emits an identifier bare when it is a simple token and quoted
# otherwise, so both forms are accepted. The bare alternative deliberately
# excludes whitespace, so it can never swallow the ` and anchor ...` that the
# template requires after it.
IDENT='identifier ("[^"]*"|[A-Za-z0-9_.-]+)'
STR='("[^"]*"|[A-Za-z0-9_.-]+)'
DEVID_OIDS='certificate 1\[field\.1\.2\.840\.113635\.100\.6\.2\.6\] /\* exists \*/ and certificate leaf\[field\.1\.2\.840\.113635\.100\.6\.1\.13\] /\* exists \*/'

SHAPE=""
# What `install-signed` produces: Developer ID with hardened runtime.
if printf '%s' "$REQUIREMENT" | grep -qE \
   "^${IDENT} and anchor apple generic and ${DEVID_OIDS} and certificate leaf\[subject\.OU\] = ${STR}\$"; then
    SHAPE="Developer ID"
# What Apple's own binaries carry (/bin/ls and friends).
elif printf '%s' "$REQUIREMENT" | grep -qE "^${IDENT} and anchor apple\$"; then
    SHAPE="Apple system"
# What an Apple Development certificate produces. Recognised deliberately:
# this tool answers "is the grant durable", and that requirement is as
# identity-bound as the Developer ID one. Whether the certificate is
# specifically Developer ID is `install-signed`'s contract, asserted there.
elif printf '%s' "$REQUIREMENT" | grep -qE \
   "^${IDENT} and anchor apple generic and certificate leaf\[subject\.CN\] = ${STR} and certificate 1\[field\.1\.2\.840\.113635\.100\.6\.2\.1\] /\* exists \*/\$"; then
    SHAPE="Apple Development"
fi

if [ -z "$SHAPE" ]; then
    echo "✗ cannot tell whether this grant is durable: $TARGET" >&2
    echo "  DR: $REQUIREMENT" >&2
    echo >&2
    echo "  This tool recognises the requirement shapes a standard codesign" >&2
    echo "  invocation produces, and this is not one of them. It does not try" >&2
    echo "  to interpret arbitrary requirements: four rounds of review showed" >&2
    echo "  that reading them with pattern matching gets the answer wrong in" >&2
    echo "  both directions, so the honest answer here is that it does not know." >&2
    echo >&2
    echo "  Inspect it yourself:  codesign -d -r- \"$TARGET\"" >&2
    echo "  Or reinstall onto known ground:  DEVELOPER_ID=<cert-sha1> make install-signed" >&2
    exit 5
fi

# ── 5. Does this binary actually satisfy it? ─────────────────────────────
# A recognised shape says the requirement WOULD be durable. It does not say
# this binary meets it: round 2 constructed one signed by certificate B while
# advertising certificate A's requirement. Only reached for shapes matched
# above, so a syntax error here is an environment problem, not a verdict.
REQ_FILE=$(mktemp "${TMPDIR:-/tmp}/verify-install-dr.XXXXXX") \
    || env_problem "could not create a temporary file (TMPDIR=${TMPDIR:-/tmp})"
trap 'rm -f "$REQ_FILE"' EXIT
printf '%s\n' "$REQUIREMENT" > "$REQ_FILE" \
    || env_problem "could not write the requirement file: $REQ_FILE"

SATISFIES=$(codesign --verify -R "$REQ_FILE" "$TARGET" 2>&1)
if [ $? -ne 0 ]; then
    if printf '%s' "$SATISFIES" | grep -qi 'invalid or corrupted code requirement'; then
        env_problem "could not parse the requirement read back from $TARGET"
    fi
    echo "✗ does not satisfy its own designated requirement: $TARGET" >&2
    echo "  DR: $REQUIREMENT" >&2
    printf '%s\n' "$DETAILS" | grep -E '^Authority=' | head -1 | sed 's/^/  actual: /' >&2
    echo >&2
    echo "  The seal is intact and the requirement is a durable shape, but this" >&2
    echo "  binary cannot satisfy it — usually a signature made with one" >&2
    echo "  identity while carrying another's requirement. TCC records the" >&2
    echo "  requirement when you grant access, so the grant would never apply." >&2
    echo >&2
    echo "  Fix:  DEVELOPER_ID=<cert-sha1> make install-signed" >&2
    exit 4
fi

echo "✓ durable: $SHAPE requirement, valid seal, and this binary satisfies it"
echo "  $TARGET"
echo "  $REQUIREMENT"
echo "  A Full Disk Access grant on this binary survives rebuilds."
