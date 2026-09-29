#!/bin/bash
# #217: rerun the late-joining MCP member test under concurrent process
# spawning, the condition that exposed its fixture races. Pure CPU load did
# not reproduce them; many overlapping /usr/bin/python3 start-ups did.
#
#   scripts/stress-late-join.sh [runs=40] [spawn-loops=24]
#
# Prints the failure count and the assertion text of each failure.
set -u
runs=${1:-40}
loops=${2:-24}
test_name='MCPProcessOwnershipTests/testOneShotRetirementKillsARealLateJoiningMemberBeforeReleasingLeader'
swift build --build-tests >/dev/null || exit 1
pids=()
for _ in $(seq 1 "$loops"); do
  ( while true; do /usr/bin/python3 -c pass; done ) >/dev/null 2>&1 &
  pids+=($!)
done
trap 'kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null' EXIT
sleep 2
failures=0
log=$(mktemp)
for i in $(seq 1 "$runs"); do
  if ! swift test --skip-build --filter "$test_name" >"$log" 2>&1 </dev/null; then
    failures=$((failures + 1))
    echo "run $i:"; grep -E 'error: -\[' "$log" | sed 's/.*\] : /  /'
  fi
done
rm -f "$log"
echo "late-join under spawn contention: $failures/$runs failed"
[ "$failures" -eq 0 ]
