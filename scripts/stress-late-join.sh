#!/bin/bash
# #217: rerun the late-joining MCP member test under concurrent process
# spawning, the condition that exposed its fixture races. Pure CPU load did
# not reproduce them; many overlapping /usr/bin/python3 start-ups did.
#
#   scripts/stress-late-join.sh [runs=40] [spawn-loops=24] [repeats=1]
#
# `runs` swift-test processes, each repeating the scenario `repeats` times
# inside one process (SAFARI_BROWSER_LATE_JOIN_REPEAT). Whether the in-process
# repeat mode catches the fixture races the old clock had depends on the
# machine: one reviewer saw 6 misses in 300 runs of the old fixture there, two
# later attempts saw none in 300 and 750. A green run therefore shows the test
# is stable under this load, not that a race is absent.
#
# A run passes only if its log says "Executed 1 test, with 0 failures". A run
# that matched no test, exited early, or was killed counts as a failure, the
# same rule scripts/run-unit-tests.py applies. Prints the failure count and the
# assertion text of each failure, and exits non-zero on any failure. The spawn
# loops stop when the script does, including when it is killed.
set -u
cd "$(dirname "$0")/.." || exit 1
runs=${1:-40}
loops=${2:-24}
repeats=${3:-1}
test_name='MCPProcessOwnershipTests/testOneShotRetirementKillsARealLateJoiningMember'
script_pid=$$
pids=()
log=""
cleanup() {
  if [ "${#pids[@]}" -gt 0 ]; then kill "${pids[@]}" 2>/dev/null; fi
  wait 2>/dev/null
  [ -n "$log" ] && rm -f "$log"
}
# Before any background work: INT and TERM end the script, which runs EXIT.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
build_log=$(mktemp)
if ! swift build --build-tests >"$build_log" 2>&1; then
  cat "$build_log"; rm -f "$build_log"; exit 1
fi
rm -f "$build_log"
for _ in $(seq 1 "$loops"); do
  # Each loop also stops when the script's process is gone (SIGKILL runs no trap).
  ( while kill -0 "$script_pid" 2>/dev/null; do /usr/bin/python3 -c pass; done ) >/dev/null 2>&1 &
  pids+=($!)
done
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
