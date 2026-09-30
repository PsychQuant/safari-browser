#!/bin/bash
# #217: rerun the late-joining MCP member test under concurrent process
# spawning, the condition that exposed its fixture races. Pure CPU load did
# not reproduce them; many overlapping /usr/bin/python3 start-ups did.
#
#   scripts/stress-late-join.sh [runs=40] [spawn-loops=24] [repeats=1]
#
# `runs` swift-test processes, each repeating the scenario `repeats` times
# inside one process (SAFARI_BROWSER_LATE_JOIN_REPEAT). One process per run
# alone under-samples the retirement-pass timing: use repeats=25 or more to
# exercise it (verify R2 measured 6 misses in 300 in-process runs where 130
# one-process runs showed none).
#
# A run passes only if its log says "Executed 1 test, with 0 failures". A run
# that matched no test, exited early, or was killed counts as a failure, the
# same rule scripts/run-unit-tests.py applies (#141). Prints the failure count
# and the assertion text of each failure, and exits non-zero on any failure.
set -u
cd "$(dirname "$0")/.." || exit 1
runs=${1:-40}
loops=${2:-24}
repeats=${3:-1}
test_name='MCPProcessOwnershipTests/testOneShotRetirementKillsARealLateJoiningMember'
build_log=$(mktemp)
if ! swift build --build-tests >"$build_log" 2>&1; then
  cat "$build_log"; rm -f "$build_log"; exit 1
fi
rm -f "$build_log"
pids=()
for _ in $(seq 1 "$loops"); do
  ( while true; do /usr/bin/python3 -c pass; done ) >/dev/null 2>&1 &
  pids+=($!)
done
cleanup() {
  if [ "${#pids[@]}" -gt 0 ]; then kill "${pids[@]}" 2>/dev/null; fi
  wait 2>/dev/null
  rm -f "${log:-}"
}
trap cleanup EXIT
sleep 2
failures=0
log=$(mktemp)
for i in $(seq 1 "$runs"); do
  SAFARI_BROWSER_LATE_JOIN_REPEAT="$repeats" \
    swift test --skip-build --filter "$test_name" >"$log" 2>&1 </dev/null
  status=$?
  if [ "$status" -ne 0 ] || ! grep -q 'Executed 1 test, with 0 failures' "$log"; then
    failures=$((failures + 1))
    echo "run $i (exit $status):"
    if grep -qE 'error: -\[' "$log"; then
      grep -E 'error: -\[' "$log" | sed 's/.*\] : /  /'
    else
      echo "  no assertion text; tail of the log:"; tail -5 "$log" | sed 's/^/  /'
    fi
  fi
done
echo "late-join under spawn contention: $failures/$runs runs failed ($repeats scenario(s) per run)"
[ "$failures" -eq 0 ]
