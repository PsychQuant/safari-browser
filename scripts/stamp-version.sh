#!/bin/bash
# Stamp the build version into the tracked placeholder, run a command, restore the
# placeholder. (#278, change add-cli-version)
#
#   scripts/stamp-version.sh <version-file> -- <command> [args...]
#
# Run from the repository root. The version is `git describe --tags --match
# 'v[0-9]*' --always --dirty`:
#
#   - It is computed BEFORE the file is touched. Writing the stamp first would make
#     every stamped build report `-dirty`, because the stamp itself is a tracked
#     modification.
#   - `--match 'v[0-9]*'` keeps IDD baseline tags (`idd-217-baseline`) out of the
#     string; without it `main` describes itself as `idd-217-baseline-31-g...`.
#   - Anything that is not letters, digits, `.`, `_`, `+` or `-`, or any git failure
#     (no .git, no git, no commits), becomes `unknown`. The value ends up inside a
#     Swift string literal, so a quote in a tag name must not reach the file.
#
# The original file is restored from a backup copy rather than `git checkout`, so a
# source archive without .git restores too. It is restored on every way out: the
# command succeeding, failing, or the wrapper receiving INT/QUIT/TERM/HUP. The command
# runs as a child we wait on, because bash defers a trap until a foreground child
# exits, and a TERM during a 30 s release build should not wait 30 s to clean up.
set -u

usage() {
  echo "usage: $0 <version-file> -- <command> [args...]" >&2
  exit 2
}

[ $# -ge 3 ] && [ "$2" = "--" ] || usage
FILE="$1"
shift 2
[ -f "$FILE" ] || { echo "stamp-version: $FILE does not exist" >&2; exit 2; }

# The tree must be the root of its own repository. `git describe` walks up the parent
# directories, so a source archive unpacked inside some other repository would
# otherwise be stamped with that repository's tag, a value that looks real.
VERSION="unknown"
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" && TOP="$(cd "$TOP" 2>/dev/null && pwd -P)"
HERE="$(pwd -P)"
if [ -n "${TOP:-}" ] && [ "$TOP" = "$HERE" ] \
   && DESCRIBED="$(git describe --tags --match 'v[0-9]*' --always --dirty 2>/dev/null)" && [ -n "$DESCRIBED" ]; then
  # LC_ALL=C: bracket ranges follow the locale's collation order in bash 3.2, and
  # under en_US.UTF-8 a range like A-Z lets non-ASCII letters through.
  case "$(LC_ALL=C; printf '%s' "$DESCRIBED" | LC_ALL=C tr -d 'A-Za-z0-9._+-')" in
    "") VERSION="$DESCRIBED" ;;       # nothing outside the whitelist
    *) ;;                             # unsafe for a Swift literal: keep "unknown"
  esac
fi

BACKUP="$(mktemp "${TMPDIR:-/tmp}/stamp-version.XXXXXX")" || exit 2
cp "$FILE" "$BACKUP" || { rm -f "$BACKUP"; exit 2; }

CHILD=""
restore() {
  if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
    # Keep the backup when the copy back fails: it is the only copy of the original.
    if cp "$BACKUP" "$FILE"; then
      rm -f "$BACKUP"
    else
      echo "stamp-version: could not restore $FILE; the original is kept at $BACKUP" >&2
    fi
  fi
  BACKUP=""
}
on_signal() { # exit status 128+n, the shell convention
  [ -n "$CHILD" ] && kill "$CHILD" 2>/dev/null
  restore
  exit "$1"
}
trap restore EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP
trap 'on_signal 131' QUIT

printf 'enum BuildVersion { static let value = "%s" }\n' "$VERSION" > "$FILE"

"$@" <&0 &
CHILD=$!
wait "$CHILD"
CODE=$?
CHILD=""
exit "$CODE"
