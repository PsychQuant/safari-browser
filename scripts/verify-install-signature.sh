#!/bin/bash
# Does the installed binary hold a Full Disk Access grant that survives a
# rebuild? (#119)
#
# TCC stores a binary's *designated requirement*, not its path. Two shapes:
#
#   ad-hoc        designated => cdhash H"8837bd31..."
#   Developer ID  designated => identifier "com.checheng.safari-browser" and
#                                anchor apple generic and ...
#                                certificate leaf[subject.OU] = "6W377FS7BS"
#
# The first IS the content hash, so any rebuild changes it and an existing
# grant silently stops applying. The second names an identity and survives.
#
# Reads only. No Full Disk Access, no certificate, no Safari.
#
#   0  identity-bound signature with a valid seal (grant survives rebuilds)
#   1  ad-hoc (grant dies on the next rebuild)
#   2  no readable signature at all (unsigned, missing, or not code)
#   3  seal is broken (signature invalid — macOS will SIGKILL this binary)
#
# The checks run in this order for a reason, and the order is the fix for two
# ways the first version of this script reported green on binaries that could
# not hold a grant at all (#119 verify B1):
#
#   1. The SEAL first. `codesign -d` only prints stored metadata; it says
#      nothing about whether the signature still covers the bytes. A binary
#      with a perfect identity-bound requirement and one flipped byte prints
#      exactly what a good one prints, and dies with SIGKILL on launch.
#
#   2. Then `Signature=adhoc`, NOT the shape of the requirement.
#      `codesign --force --sign - --preserve-metadata=requirements` produces a
#      genuinely ad-hoc binary that has kept the old identity-bound
#      requirement — it prints a requirement it can never satisfy, because
#      there is no certificate chain behind it. Judging by the requirement's
#      shape passes it.
#
#      This is the same criterion `CodeSigningState.parse()` uses
#      (Sources/SafariBrowser/Utilities/CodeSigningState.swift). Deliberately
#      the same: the first version of this script invented a weaker one, and
#      the two implementations then disagreed about the same binary — the CLI
#      told the user "ad-hoc, your grant will not survive" while
#      `make verify-install-signature` said it would.
set -u

TARGET="${1:-$HOME/bin/safari-browser}"

# ── 1. Is the signature intact? ──────────────────────────────────────────
SEAL=$(codesign --verify --strict "$TARGET" 2>&1)
SEAL_RC=$?
if [ "$SEAL_RC" -ne 0 ]; then
    # Distinguish "no signature at all" from "signature present but broken".
    # Both are failures, but only the second means a binary that looks fine
    # in every metadata dump and still gets killed on launch.
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

# ── 2. Is it ad-hoc? ─────────────────────────────────────────────────────
DETAILS=$(codesign -dvv "$TARGET" 2>&1)
if printf '%s' "$DETAILS" | grep -q 'Signature=adhoc'; then
    echo "✗ ad-hoc signature: $TARGET" >&2
    printf '%s\n' "$DETAILS" | grep -E '^Signature=|^TeamIdentifier=' | sed 's/^/  /' >&2
    echo >&2
    echo "  An ad-hoc signature has no certificate behind it, so its designated" >&2
    echo "  requirement is the binary's own content hash. A rebuild changes the" >&2
    echo "  hash, and any Full Disk Access grant you gave this binary stops" >&2
    echo "  applying — silently, with no error at the moment it breaks." >&2
    echo >&2
    echo "  (An ad-hoc signature can be made to PRINT an identity-bound" >&2
    echo "   requirement via --preserve-metadata. It still cannot satisfy it.)" >&2
    echo >&2
    echo "  Fix:  DEVELOPER_ID=<cert-sha1> make install-signed" >&2
    exit 1
fi

# ── 3. Report the requirement ────────────────────────────────────────────
# Drop the `Executable=<path>` line before looking at the requirement: an
# install path that happens to contain the string would otherwise be read as
# part of the answer.
REQUIREMENT=$(codesign -d -r- "$TARGET" 2>&1 | grep -v '^Executable=')

if printf '%s' "$REQUIREMENT" | grep -q 'cdhash'; then
    echo "✗ cdhash-bound requirement: $TARGET" >&2
    printf '%s\n' "$REQUIREMENT" | sed 's/^/  /' >&2
    echo >&2
    echo "  Fix:  DEVELOPER_ID=<cert-sha1> make install-signed" >&2
    exit 1
fi

echo "✓ identity-bound signature, valid seal: $TARGET"
printf '%s\n' "$REQUIREMENT" | sed 's/^/  /'
echo "  A Full Disk Access grant on this binary survives rebuilds."
