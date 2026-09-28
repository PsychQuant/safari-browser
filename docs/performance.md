# Measuring command performance

`SAFARI_BROWSER_TRACE_TIMING=1` enables timing for that CLI invocation. Other
values leave it disabled. It does not select a different backend or relax any
operation guard. Persistent daemon/MCP hosts do not emit a lifetime trace: each
opted-in handler or CLI worker has its own request context.
MCP transports worker summaries in the existing tool-result `stderr` field;
the worker's `stdout` field keeps its normal command output.

## Trace format

A stderr line begins with `[safari-browser timing] `, followed by JSON. Select
that prefix: ordinary error/help diagnostics can follow the timing line.

- `schemaVersion`: `1`.
- `requestID`: fresh UUID; `processID`: the producing process ID.
- `status`: `ok` or `error`.
- `totalNanoseconds`: monotonic time from main-entry collection to summary creation.
- `spans`: at most 64 records with positive `id`, optional `parentID`, fixed `phase`,
  `durationNanoseconds`, and `outcome` (`ok`, `error`, or `unfinished`).
- `droppedSpans`: records omitted by the bound.

The entire line is bounded to 64 KiB. Phases name command dispatch, target
resolution, direct/daemon/in-process AppleScript, process launch/wait, file-dialog
execution, AX wait/inspection, daemon request/compile/execute/cache-hit, and exec.
There are no free-text labels, arguments, source text, URLs, selectors, clipboard
values, file paths, file contents or error messages in the timing record. Ordinary
command diagnostics retain their existing content; only the timing record has
this restricted schema.

Durations are inclusive. Do not sum parent and child spans, or overlapping
client/server work, to obtain total time. `process.wait` means pipe draining and
process completion; a completed wait can still yield a nonzero process status,
reported by its enclosing operation. Main timing excludes pre-main loading,
summary encoding/writing, and final rendering/exit after a caught error or help
request. External wall time is the end-to-end measurement. A killed process can
produce no summary; an unfinished read worker is marked rather than invented as
completed, and late callbacks cannot modify an emitted trace.

`daemon.request` appears at both sides of the RPC: the outer span measures client
transport, and its imported child measures the handler. A returned application
error can have an `ok` handler span (the handler returned normally) while its
summary status is `error`; a thrown handler has an `error` span.
An `ok` span means the wrapped operation returned normally, not that every
application-level result succeeded. In particular, `ax.wait` may return its
existing fallback, and an exec handler may return step errors in its result array.
Interpret those results together with the spans.

`exec` can forward several child summaries. Readers should select the unique
record whose `processID` matches the actual root process, not guess by order or
largest duration. A single older summary without `processID` remains readable.
When an exec child fails, its valid own-process summary remains on stderr but
is excluded from the step's error message in stdout. Ordinary diagnostics and
malformed timing lookalikes are retained.

## Daemon metadata

Opted-in `applescript.execute` and `exec.runScript` requests send an optional
literal Boolean `timing: true`. Only that request collects service timing; its
response can attach a `timing` object with the same bounded schema: successful
RPC envelopes use `result.timing`, while thrown handler errors use top-level
`timing` beside the unchanged `error` object. Clients
validate, bound and reparent imported spans under the RPC. Missing metadata from
an older daemon, or invalid metadata, does not change the execution result and
never causes replay. Compile/execute remain on their existing main actor; the
cache still stores compiled scripts, not Safari state.

## Benchmark

Build the executable, then run:

```sh
swift build
python3 scripts/benchmark-performance.py --binary .build/debug/safari-browser --samples 20 --warmups 3 --timing both > benchmark.json
```

Fixed scenarios cover help startup, zero-duration wait, exec wait batch, private
daemon status, and MCP wait workers in both explicitly selected `isolated` and
`persistent` modes. Use `--mcp-worker-mode isolated|persistent|both` to choose the
comparison; the default is `both`. Each service owns a short private temporary
socket directory and namespace. It never stops an existing user daemon. The
benchmark reserves its child leader identity with non-reaping observation until
its process group is cleaned up; normal exit status is retained. Capture is
bounded and raw stdout/stderr is not copied into the report.

Host readiness requires a private socket connection and a complete bounded
handshake line, not merely a socket path. The probe reads at most 64 KiB within
the startup deadline and sends no handler request. It never reconnects after an
uncertain established connection. Service stderr is discarded to avoid pipe
backpressure; MCP worker timing is read from its structured response. A cleanup
failure is reported as `cleanupFailed` and its samples are excluded from success
quantiles. The benchmark cannot force cleanup when the OS refuses a signal.

`--live` additionally creates one owned localhost static page per timing mode,
and may launch Safari if it is not running (including Safari's normal session
restoration). It then measures direct and warm-daemon `get title`/`get url`/`js document.title`
(`live.<mode>.get-title`, `.get-url`, `.js-title`; the `js` row is the multi-round-trip
protocol whose per-step target re-resolution #180 bounded). It verifies the window
ID, exact URL, one-tab identity and clear-dialog state. Changed or uncertain
ownership prevents cleanup actions and marks the report; an uncertain close is
not retried. No upload, PDF, Print or arbitrary repeated mutation is supported.
Without explicit live mode, or without a clear GUI preflight, GUI rows are SKIP.
Live ownership checks also require System Events access to Safari's UI. If that
access fails after creation, or the user changes the foreground window before
its ID is captured, the fixture can remain open with cleanup marked unknown.
Warm-daemon samples force the daemon route and reject host exit, direct fallback,
or truncated routing diagnostics, with timing both on and off. Rejected routes
stop subsequent warm samples without restarting the service or retrying the read.

The JSON report identifies executable digest, OS build and architecture, timing
mode, warmups, measured samples, failures and skips. Fresh process means a new CLI
process, not flushed OS caches. Cold host measurements include host setup; warm
host measurements retain the service. Daemon status still launches a fresh CLI;
MCP isolated mode creates a fresh worker, while persistent mode reuses healthy
workers. MCP scenario names now include the mode (`mcp.isolated.*` and
`mcp.persistent.*`) instead of the former mode-ambiguous `mcp.*` names.
Each MCP row includes `workerMode` and `workerIdentity`: successful measured
command traces supply the observed sample count, unique worker PID count and
unique request-ID count. Trace-off rows have no identity observation; a host PID
or scenario label is never substituted for actual worker evidence.
Host readiness is polled, so cold-host wall time also includes readiness-detection
latency (up to one polling interval under normal scheduling), not only startup.
Daemon status rows measure transport/lifecycle, not compilation or Safari work.
An exit code of zero alone is insufficient: status output must match the owned
service's namespace and PID, and that host must still be alive after the call.
The exec wait batch is not supported by the in-process daemon dispatcher and is
therefore labelled separately.

p50/p95 use nearest rank over successful samples; failure and skip counts remain
visible, and an empty success set has null quantiles. Small sample sets are
observations, not stable population percentiles. Compare identical fixtures,
versions, timing modes and warmup conditions, and retain timing-on/off results to
expose instrumentation overhead. There is no fixed speed threshold in CI and no
speedup is established merely by adding this measurement feature.


## Persistent MCP measurement (#172, 2026-09-28)

The same debug build (`c70f25a`, SHA-256
`aebf3434841cb2fe4aec321445ae445d7482e15d780272769b663af5ea58612c`)
was measured on arm64 / Darwin build 26B5091g. The fixed input was `wait 0`,
with three warmups, a three-second per-call deadline and no live Safari work.
All 18 non-GUI scenarios in the primary run succeeded 20/20, including both
trace modes. Cold host samples include startup/readiness and one request;
cleanup is excluded from the reported wall quantiles.

| Trace | Mode | Cold p50 / p95 ms | Warm p50 / p95 ms | Success per row |
|---|---|---:|---:|---:|
| off | isolated | 260.49 / 273.09 | 34.98 / 55.62 | 20/20 |
| off | persistent | 282.39 / 296.95 | 18.12 / 20.24 | 20/20 |
| on | isolated | 297.38 / 371.92 | 48.57 / 95.67 | 20/20 |
| on | persistent | 297.24 / 384.70 | 21.41 / 28.47 | 20/20 |

Trace-on warm samples observed 20 distinct worker PIDs in isolated mode and
one worker PID with 20 distinct request IDs in persistent mode. Trace-off
samples do not claim PID observations. The cold trace-off persistent cost was
about 22 ms higher at p50: an additional supervisor is not free.

A reverse-order warm-only check (persistent first, then isolated; same build,
20 samples and three warmups) exposed variability: persistent p50/p95 was
22.17/86.15 ms versus isolated 36.95/54.77 ms. **That cohort's persistent tail distribution regressed**: eight of twenty
samples exceeded the isolated median, and the means were approximately
39.8 ms (persistent) versus 40.5 ms (isolated). It is retained rather than
discarded as a favorable-result filter.

An alternating AB/BA check then kept both hosts open, warmed each three times,
and measured 60 sequential calls per mode, alternating which mode ran first in
each pair. Both modes succeeded 60/60 in each timing setting:

| Trace | Isolated warm p50 / p95 ms | Persistent warm p50 / p95 ms |
|---|---:|---:|
| off | 55.50 / 194.43 | 20.13 / 101.59 |
| on | 42.70 / 95.97 | 20.82 / 62.12 |

Trace-on identity evidence was 60 distinct isolated worker PIDs versus one
persistent PID and 60 independent request IDs. Large outliers in both modes
mostly lay outside the command trace. That interval includes IPC, scheduling,
image checks and stream/exit handling; these data do not identify one cause.
The measurements support lower warm p50/p95 for this controlled comparison,
with no success-rate loss. They do not establish a universal per-call or GUI
speedup, nor isolate trace overhead from changing system load.

After three successful trace-off calls, a separate read-only process-tree/RSS
snapshot observed no resident child in isolated mode and two resident children
(supervisor plus worker) in persistent mode. Host+children RSS sums were
22,688 KiB and 43,760 KiB respectively; the persistent children contributed
24,128 KiB. These are single `ps` snapshots, not unique-memory accounting or
population estimates. The children are retired after the configured idle interval.

[Recorded quantiles, identity counts and raw wall samples](benchmarks/mcp-worker-2026-09-28.json)
include every cohort above. To repeat the primary comparison, use the command in
this section with `--samples 20 --warmups 3 --timeout 3 --timing both
--mcp-worker-mode both`. For the alternating check, create one `Service` per
mode, call each three times to warm up, then call `Service.call_wait` once per
mode per iteration for 60 iterations, reversing the order on alternate iterations;
each call receives its own `monotonic() + 3` deadline. Close both owned services
and reject failed cleanup. The existing benchmark helpers provide the same
bounded protocol, validation, redaction and ownership checks for this procedure.


The original startup decomposition is also preserved as
[per-sample diagnostic intervals](benchmarks/mcp-startup-diagnostic-2026-09-28.json)
and the [temporary instrumentation patch](benchmarks/mcp-startup-diagnostic.patch).
Those diagnostic intervals include instrumentation overhead; the spawn syscall
is nested within spawn-to-entry. The same-process repeat was restricted to
`wait 0` and was not a delivered isolation implementation.

For a directly executable alternating warm comparison, add
`--mcp-warm-order interleaved --mcp-worker-mode both` to the benchmark command.
The driver keeps both owned hosts open, alternates AB/BA order across warmups
and measured pairs, and never retries a failed mode. Cold/CLI/daemon rows keep
their existing independent scenarios. Tests cover pair order, warmup separation,
mode selection and failure cleanup.


## R2 release comparison (2026-09-28)

After the review fixes, the checked-in interleaved driver measured an optimized
release build with the same fixed `wait 0`, 60 samples, three warmups and
three-second deadlines. Final binary SHA-256:
`300d5a25419145b81d5a38da232a0c0ce5042bb8e51ddd5f1517b4126de27945`.
All rows succeeded 60/60 on arm64 / Darwin 26B5091g; no live Safari work ran.

| Trace | Mode | Cold p50 / p95 ms | Interleaved warm p50 / p95 ms |
|---|---|---:|---:|
| off | isolated | 46.01 / 78.52 | 17.70 / 50.97 |
| off | persistent | 56.69 / 89.64 | 2.52 / 7.77 |
| on | isolated | 38.96 / 50.18 | 10.71 / 21.51 |
| on | persistent | 46.73 / 52.17 | 1.74 / 2.65 |

Trace-on observed 60 isolated worker PIDs versus one persistent PID, with 60
independent request IDs in each mode. This release comparison supports lower
warm p50/p95 without success-rate loss; it still does not prove every-call,
GUI or population-wide speedup. Cold p50 retains the additional helper cost.
Different timing-on/off cohorts remain sensitive to changing system load, so
their subtraction is not a pure estimate of tracing overhead.

[Both R2 release cohorts and wall samples](benchmarks/mcp-worker-release-r2-2026-09-28.json)
are retained, including an earlier build before the deadline-origin refinement.
Earlier debug cohorts, including the adverse tail distribution, remain above.
Reproduction command:

```sh
python3 scripts/benchmark-performance.py --binary /path/to/release/safari-browser --samples 60 --warmups 3 --timeout 3 --timing both --mcp-worker-mode both --mcp-warm-order interleaved
```

These R2 measurements predate the one-shot supervision and retained ownership
work for issue #209. They do not certify that later implementation or predict
its isolated-mode startup cost; the final runtime requires a new comparison.

## R3 supervised one-shot comparison (2026-09-28)

Runtime commit `a12ba03b053c9c9e291c1482dc90bf4923332e6b` adds lifetime
supervision and retained cleanup ownership to the one-shot path as well.
Each isolated call now pays for a fresh supervisor as well as a fresh CLI;
its total cost also includes MCP framing and transport. This changes the isolated
baseline; the R2 numbers above describe their own
older binaries. The new release binary SHA-256 is
`7797668ff99fe7113fdb86d19f67de325fe591e28770dabe9736f357206f40d8`.
The same fixed `wait 0` comparison uses 60 samples, three warmups, three-second
deadlines and alternating AB/BA warm calls. All non-live rows succeeded 60/60;
live Safari rows were skipped.

| Trace | Mode | Cold p50 / p95 ms | Interleaved warm p50 / p95 ms |
|---|---|---:|---:|
| off | isolated | 59.11 / 63.12 | 29.40 / 31.85 |
| off | persistent | 50.72 / 59.36 | 1.89 / 6.77 |
| on | isolated | 61.36 / 65.52 | 30.50 / 33.29 |
| on | persistent | 52.68 / 61.50 | 2.39 / 14.01 |

Trace-on warm samples observed 60 isolated CLI worker PIDs versus one persistent
worker PID, with 60 distinct request IDs per mode. Both warm quantiles improved
without a lower success rate in this cohort. The trace-on persistent p95 is much
higher than its p50; the result does not establish every-call or GUI speedup.
Timing-on/off subtraction also includes changing system load and is not a pure
instrumentation-cost estimate.

The same report separately retains the other fixed scenarios (trace off):

| Scenario | p50 / p95 ms |
|---|---:|
| Fresh CLI help | 11.96 / 13.86 |
| Fresh CLI wait 0 | 12.27 / 14.12 |
| Fresh CLI exec wait batch | 46.92 / 52.07 |
| Cold daemon host + status | 29.79 / 32.66 |
| Warm daemon + fresh CLI status | 12.93 / 15.90 |

Those daemon/status and CLI workloads are separate baselines, not interchangeable
with the warm MCP wait request. [All R3 scenario samples and warmups](benchmarks/mcp-worker-release-r3-2026-09-28.json)
include both timing settings, sample statuses, per-sample trace identities and
summary durations. Per-span trace arrays are omitted; the original report digest
is recorded. The earlier startup diagnostic and all adverse debug cohorts remain
available above.

After three successful calls, a separate read-only process-tree snapshot found
zero resident children for isolated mode and two for persistent mode. Host plus
child RSS sums were 17,040 KiB versus 38,000 KiB. These are single `ps` snapshots
that count shared pages, not unique memory or a population estimate. Idle cleanup
is separately tested; the extra resident helpers are the cost of process reuse.

### Final R3 deadline-clamped runtime

The final runtime at `7c585c3` also prevents an internal inherited deadline from
extending the configured timeout. Its release SHA-256 is
`6d327f2b0ad928b69c024e259ea19a2bd120ce774507862a5093c6b2d7eee997`.
A fresh run used the same 60/3/3-second AB/BA settings; all non-live rows again
succeeded 60/60. Differences from the earlier cohort include system load and
must not be attributed solely to that internal deadline correction.

| Trace | Mode | Cold p50 / p95 ms | Interleaved warm p50 / p95 ms |
|---|---|---:|---:|
| off | isolated | 46.97 / 50.03 | 24.48 / 27.47 |
| off | persistent | 35.51 / 39.20 | 1.13 / 1.77 |
| on | isolated | 47.19 / 50.27 | 23.97 / 25.48 |
| on | persistent | 36.69 / 44.41 | 1.10 / 1.46 |

Trace-on warm identity counts remained 60 versus one CLI PID and 60 request IDs
per mode. [Final R3 samples](benchmarks/mcp-worker-release-r3-final-2026-09-28.json)
retain every scenario's sample/warmup wall times, statuses and trace identities
as aligned arrays, including separate CLI/daemon and explicitly skipped live
rows. The earlier R3 report is retained above. A new three-call resident snapshot
found zero versus two children and RSS sums of 18,352 versus 38,144 KiB; the same
single-snapshot/shared-page limitations apply.

## R4 TERM-protected comparison (2026-09-29)

Runtime `834dc89` keeps both supervisors alive through TERM grace and preserves
actual worker signal handling. Release SHA-256:
`02320ed601bc71f34fabd715463d0a058d5a3776a08b00122b00ba7cfb1ca505`.
The same 60-sample, three-warmup, three-second AB/BA comparison again completed
all non-live rows 60/60, including all warmups.

| Trace | Mode | Cold p50 / p95 ms | Interleaved warm p50 / p95 ms |
|---|---|---:|---:|
| off | isolated | 52.90 / 64.56 | 24.30 / 25.57 |
| off | persistent | 36.27 / 43.84 | 1.14 / 1.47 |
| on | isolated | 47.16 / 53.09 | 23.57 / 24.71 |
| on | persistent | 35.75 / 38.19 | 1.12 / 1.37 |

Trace-on warm identity counts remain 60 versus one actual CLI PID and 60 request
IDs per mode. [All R4 scenario wall/status/identity arrays](benchmarks/mcp-worker-release-r4-2026-09-29.json)
include CLI/daemon baselines and skipped live rows. Earlier cohorts remain above;
changes across cohorts are not attributed solely to the TERM correction.
A separate three-call resident snapshot found zero versus two children, with
RSS sums of 17,728 versus 38,896 KiB (shared pages included, not unique memory).
These measurements support this fixed workload comparison; lifetime correctness
is established separately by the TERM/grace/host-death regressions.

## Reference: `js` with 109 tabs open (#180)

Historical measurements from the September 22–24 #180 implementation, before the
current main integration: same machine, same minute, Safari with 5 windows / 109
tabs, `SAFARI_BROWSER_TRACE_TIMING=1`;
a direct `osascript … do JavaScript` on the same tab took 0.19 s at the time.

| form | before (09-11 build) | after | `target.native` spans (full enumerations) after |
|---|---|---|---|
| `js --window 1 --tab-in-window 2 'location.host'` | 11.6 s | 1.4 s | 1 (was 6) |
| `js 'location.host'` (default target) | — | 1.4 s | 0 |
| `js --url … --first-match 'location.host'` | — | 1.5 s | 1 |

What changed: `js` anchors positional targets once at the command boundary
(`resolveToAnchoredTarget`), so subsequent JavaScript steps use a resolved or
anchored-current-tab target instead of repeating the enumeration. The initial
batched enumeration measured 2.3 s → 0.43 s with byte-identical output; the later
review added a URL re-read, making three bulk property reads per window in the
common case and at most six before per-tab fallback. The 1.4 s observation did
not meet the agreed ≤ 1 s target and is not a measurement of this integrated
revision. Resolving once removes repeated enumerations, but the initial
enumeration still reads all tab records; this is not a constant-time guarantee.
