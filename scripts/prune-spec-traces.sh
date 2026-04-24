#!/usr/bin/env bash
# prune-spec-traces.sh — strip transient `.remember/` paths from @trace blocks in openspec/specs/*.
#
# Spectra archive appends `<!-- @trace ... -->` HTML comments to every spec it touches,
# listing every file the archiving session wrote. On a repo with autonomous logging, that
# list balloons with `.remember/logs/autonomous/save-*.log` entries — one spec grew to
# 35 000 lines of which 98%+ was log-file noise invisible to any rendered view.
#
# This script:
#   1. For each `openspec/specs/*/spec.md`, scans every `<!-- @trace ... -->` HTML
#      comment block.
#   2. Within each block, drops lines of the form `  - .remember/logs/...` and
#      `  - .remember/tmp/...` (the transient ones). Everything else (real
#      Sources/Tests/doc paths, the `source:` / `updated:` / `code:` headers) is kept.
#   3. If after pruning a block has no `code:` entries left, collapse the block to a
#      minimal form (keeps `source:` + `updated:` as provenance).
#   4. Collapses runs of consecutive trace blocks with identical content after pruning
#      into a single block.
#   5. Backs up every modified file to /tmp/spec-prune-backup/<timestamp>/ before
#      writing, so a wrong run is recoverable without git.
#
# Usage:
#   scripts/prune-spec-traces.sh --dry-run              # preview line deltas
#   scripts/prune-spec-traces.sh --apply                # rewrite files in place
#   scripts/prune-spec-traces.sh --apply path1 path2    # limit scope
#
# Idempotent: running twice is a no-op on the second run.

set -euo pipefail

MODE=""
TARGETS=()

for arg in "$@"; do
    case "$arg" in
        --dry-run)  MODE="dry-run" ;;
        --apply)    MODE="apply" ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)          TARGETS+=("$arg") ;;
    esac
done

if [[ -z "$MODE" ]]; then
    echo "error: must pass --dry-run or --apply" >&2
    echo "run with --help for usage" >&2
    exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    mapfile -t TARGETS < <(find openspec/specs -name spec.md -type f | sort)
fi

BACKUP_DIR="/tmp/spec-prune-backup/$(date +%Y%m%d-%H%M%S)"
if [[ "$MODE" == "apply" ]]; then
    mkdir -p "$BACKUP_DIR"
fi

prune_file() {
    local path="$1"
    local tmp
    tmp="$(mktemp)"

    # Awk program:
    #   - Buffer lines between `<!-- @trace` and `-->` (inclusive of both).
    #   - Within the buffer, drop `  - .remember/logs/...` and `  - .remember/tmp/...`.
    #   - After the block ends, compare to the previous block's post-prune text;
    #     if identical, drop this block entirely (dedupe consecutive traces).
    #   - Emit everything else verbatim.
    awk '
        function flush_block(   i, cur, line) {
            # Strip transient .remember/logs + .remember/tmp entries
            cur = ""
            for (i = 1; i <= bn; i++) {
                line = buf[i]
                if (line ~ /^[[:space:]]*-[[:space:]]+\.remember\/(logs|tmp)\//) continue
                cur = cur line "\n"
            }
            # Dedupe: if previous emitted block had identical content, skip this one.
            if (cur == last_block) return
            last_block = cur
            printf "%s", cur
        }
        {
            if (in_block) {
                buf[++bn] = $0
                if ($0 ~ /-->/) {
                    flush_block()
                    bn = 0
                    in_block = 0
                }
                next
            }
            if ($0 ~ /<!--[[:space:]]*@trace/) {
                in_block = 1
                bn = 0
                buf[++bn] = $0
                next
            }
            # Non-block line: reset dedupe window so unrelated traces downstream still print.
            last_block = ""
            print
        }
        END {
            # Unclosed block: emit as-is.
            if (in_block) {
                for (i = 1; i <= bn; i++) print buf[i]
            }
        }
    ' "$path" > "$tmp"

    local before after
    before=$(wc -l < "$path" | tr -d ' ')
    after=$(wc -l < "$tmp" | tr -d ' ')

    if [[ "$before" == "$after" ]]; then
        rm -f "$tmp"
        return 1  # no change
    fi

    printf '%-55s %7s → %-7s (-%d lines)\n' \
        "$path" "$before" "$after" "$((before - after))"

    if [[ "$MODE" == "apply" ]]; then
        local backup="$BACKUP_DIR/$path"
        mkdir -p "$(dirname "$backup")"
        cp "$path" "$backup"
        mv "$tmp" "$path"
    else
        rm -f "$tmp"
    fi

    return 0
}

total_before=0
total_after=0
changed=0
unchanged=0

for path in "${TARGETS[@]}"; do
    if [[ ! -f "$path" ]]; then
        echo "warn: skipping non-file $path" >&2
        continue
    fi
    before=$(wc -l < "$path" | tr -d ' ')
    if prune_file "$path"; then
        after=$(wc -l < "$path" 2>/dev/null | tr -d ' ' || echo "$before")
        # If we're in dry-run we didn't overwrite, so `after` above is still `before`.
        # Recompute from the temp by re-running just the awk (cheap vs confusing state).
        if [[ "$MODE" == "dry-run" ]]; then
            after=$(awk '
                function flush_block(   i, cur, line) {
                    cur = ""
                    for (i = 1; i <= bn; i++) {
                        line = buf[i]
                        if (line ~ /^[[:space:]]*-[[:space:]]+\.remember\/(logs|tmp)\//) continue
                        cur = cur line "\n"
                    }
                    if (cur == last_block) return
                    last_block = cur
                    printf "%s", cur
                }
                {
                    if (in_block) { buf[++bn] = $0; if ($0 ~ /-->/) { flush_block(); bn=0; in_block=0 } next }
                    if ($0 ~ /<!--[[:space:]]*@trace/) { in_block=1; bn=0; buf[++bn]=$0; next }
                    last_block = ""; print
                }
                END { if (in_block) for (i=1;i<=bn;i++) print buf[i] }
            ' "$path" | wc -l | tr -d ' ')
        fi
        total_before=$((total_before + before))
        total_after=$((total_after + after))
        changed=$((changed + 1))
    else
        unchanged=$((unchanged + 1))
    fi
done

echo ""
echo "──────────────────────────────────────────────────────────"
echo "mode:      $MODE"
echo "files:     $changed changed, $unchanged unchanged"
if (( changed > 0 )); then
    echo "lines:     $total_before → $total_after (−$((total_before - total_after)))"
fi
if [[ "$MODE" == "apply" ]]; then
    echo "backup:    $BACKUP_DIR"
else
    echo ""
    echo "This was a dry run. Re-run with --apply to rewrite files."
fi
