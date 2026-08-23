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
# grant silently stops applying — not revoked, not an error, just no longer
# matching anything. The second names an identity and survives.
#
# Reads only. No Full Disk Access, no certificate, no Safari.
#
# Exit codes are distinct on purpose — see the unsigned branch below:
#   0  requirement is identity-bound (grant survives rebuilds)
#   1  requirement is cdhash-bound (ad-hoc; grant dies on the next rebuild)
#   2  no readable signature at all (unsigned, missing, or not code)
set -u

TARGET="${1:-$HOME/bin/safari-browser}"

REQUIREMENT=$(codesign -d -r- "$TARGET" 2>&1)
CODESIGN_RC=$?

# This branch must come FIRST, and it must not fall through to the cdhash test.
# `codesign -d -r-` on an unsigned binary exits non-zero AND prints no
# requirement, so "no cdhash in the output" is true there as well — a verifier
# that only greps would report the unsigned binary as fine. Unsigned is its own
# exit code so the two failures stay distinguishable to a caller.
if [ "$CODESIGN_RC" -ne 0 ]; then
    echo "✗ no readable code signature: $TARGET" >&2
    echo "  codesign said: $(printf '%s' "$REQUIREMENT" | head -1)" >&2
    echo "  An unsigned binary cannot hold a Full Disk Access grant at all." >&2
    exit 2
fi

if printf '%s' "$REQUIREMENT" | grep -q 'cdhash'; then
    echo "✗ ad-hoc signature: $TARGET" >&2
    printf '%s\n' "$REQUIREMENT" | grep -v '^Executable' | sed 's/^/  /' >&2
    echo >&2
    echo "  The designated requirement IS the content hash, so a rebuild changes" >&2
    echo "  it and any Full Disk Access grant you gave this binary stops applying" >&2
    echo "  — silently, with no error at the moment it breaks." >&2
    echo >&2
    echo "  Fix:  DEVELOPER_ID=<cert-sha1> make install-signed" >&2
    exit 1
fi

echo "✓ identity-bound signature: $TARGET"
printf '%s\n' "$REQUIREMENT" | grep -v '^Executable' | sed 's/^/  /'
echo "  A Full Disk Access grant on this binary survives rebuilds."
