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
daemon status, and MCP wait workers. Each service owns a short private temporary
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
host measurements retain the service but still launch the documented CLI/worker.
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

## Reference: `js` with 109 tabs open (#180)

Same machine, same minute, Safari with 5 windows / 109 tabs, `SAFARI_BROWSER_TRACE_TIMING=1`;
a direct `osascript … do JavaScript` on the same tab took 0.19 s at the time.

| form | before (09-11 build) | after | `target.native` spans (full enumerations) after |
|---|---|---|---|
| `js --window 1 --tab-in-window 2 'location.host'` | 11.6 s | 1.4 s | 1 (was 6) |
| `js 'location.host'` (default target) | — | 1.4 s | 0 |
| `js --url … --first-match 'location.host'` | — | 1.5 s | 1 |

What changed: `js` anchors positional targets once at the command boundary
(`resolveToAnchoredTarget`), so each of its six AppleScript steps takes the
`.resolvedTab` shortcut instead of re-running the resolver; and the enumeration
reads a window's tab URLs/names in two Apple events per window instead of two per
tab (standalone 2.3 s → 0.43 s at 109 tabs, byte-identical output). The remaining
~1.4 s is six `osascript` launches at ~0.2 s each — the same floor a direct
`osascript` call pays per round-trip — and no longer grows with the total tab count.
