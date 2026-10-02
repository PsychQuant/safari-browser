## MODIFIED Requirements

### Requirement: Daemon uses pre-compiled NSAppleScript handles, not process warmth, for latency reduction

The daemon SHALL compile AppleScript source blocks into `NSAppleScript` objects held in memory and route all Safari interactions through these cached handles rather than spawning `osascript` subprocesses per request. The cache SHALL hold at most 256 distinct sources, distinct by the UTF-8 bytes of the source (two sources that differ only in Unicode normalisation are two entries); when a new source would exceed that bound, the least recently used handle SHALL be evicted.

#### Scenario: Repeated commands do not re-compile AppleScript

- **WHEN** the daemon serves two consecutive `snapshot` requests
- **THEN** the AppleScript source is compiled at most once — the second request reuses the cached `NSAppleScript` handle

#### Scenario: Per-command latency stays below 100 ms median

- **WHEN** the daemon has warmed up and a client issues a `documents` command
- **THEN** the round-trip latency from client request send to client response receive is less than or equal to 100 ms at the 50th percentile on a reference Mac (M-series, Safari already running)

#### Scenario: Distinct sources beyond the bound

- **WHEN** the daemon has cached 256 distinct sources and compiles another
- **THEN** it SHALL evict the least recently used handle and keep the new one

### Requirement: Daemon log redaction

The daemon SHALL redact or truncate sensitive payloads in its log file at `${TMPDIR:-${_refuse_per_permissions_requirement}}/safari-browser-<NAME>.log`. Specifically:

1. For `applescript.execute` / `Safari.js` / any method whose params include arbitrary user-provided code or text, the `params.code` / `params.source` field SHALL be replaced with the literal string `<redacted N bytes>` in the log (where N is the original byte length). The raw code SHALL NEVER be written to the log. For `exec.runScript`, the request is logged whether or not the handler accepts it, so the replacement SHALL apply to every value of a step under a key other than `cmd`, `var` and `onError`, whatever its type (a string by its byte count, a number, a boolean or null by the bare marker, an array or object element by element), and to a `steps` value, or a step, that is not the expected shape, whole: a step carries what a person typed (`fill`, `type`, `storage ... set`), a stored value, the code of a `js` step, or the literals of an `if` expression, and a typo'd key or an `args` that is not an array must not turn a password into a logged value. The step's command name, its `var` name and its `onError` value, and the envelope's `targetArgs`, SHALL be kept, since they show which step failed (a `--url` inside a step's own `args` is redacted with the rest).
2. For methods whose `result` returns DOM content, cookies, storage values, page source, or text extraction, the result SHALL be truncated to at most 256 bytes in the log with a trailing `…(truncated)` marker. Metadata about the result (byte count, content type) MAY be logged in full. For `exec.runScript`, whose result carries what each step returned and error messages that can quote a selector or typed text, each step's `value` and `error.message` SHALL be replaced by their size (`<redacted N bytes>`) instead; the step number, status, variable name, skip reason and error code SHALL be kept, and a result that is not that shape SHALL be replaced whole.
3. Metadata about every request SHALL be preserved in the log: method name, `requestId`, client-visible error codes, wall-clock timestamps, and duration. This metadata SHALL NOT be redacted because it is the primary debugging surface.
4. An operator-controlled environment variable `SAFARI_BROWSER_DAEMON_LOG_FULL=1` MAY disable redaction for local-debugging sessions. When disabled, the daemon SHALL emit a single startup warning line to stderr stating that sensitive content is being logged verbatim.

#### Scenario: js reading cookies does not leak into log

- **WHEN** the daemon serves `safari-browser js "document.cookie" --daemon` and the result is a 512-byte cookie string
- **THEN** the log contains the method, requestId, duration, result-byte-count, and the first 256 bytes of the result with `…(truncated)` appended; it SHALL NOT contain the full 512-byte cookie

#### Scenario: AppleScript compile errors stay visible

- **WHEN** the daemon serves `applescript.execute` with a malformed source and the result is a compile error
- **THEN** the error code and message are logged in full (unredacted) because error metadata aids debugging and SHALL NOT be subject to the payload-redaction rule

#### Scenario: LOG_FULL opt-out emits warning

- **WHEN** the daemon starts with `SAFARI_BROWSER_DAEMON_LOG_FULL=1`
- **THEN** stderr shows a single line warning that redaction is disabled; subsequent log entries contain un-truncated params and results

#### Scenario: a malformed exec step does not leak into the log

- **WHEN** the daemon is sent an `exec.runScript` request with a step `{"cmd":"fill","arg":["#pw","hunter2"]}` (a typo'd key) or `{"cmd":"fill","args":"hunter2"}` or a step that is a bare string, and rejects it
- **THEN** the log entry for the request SHALL NOT contain `hunter2` or `#pw`

#### Scenario: an exec script's results are redacted in the log

- **WHEN** an `exec.runScript` request returns a step with `value` `s3cr3t-token` and a failing step whose error message quotes the selector `#password`
- **THEN** the log SHALL contain the step numbers, the statuses and the error code, and SHALL NOT contain `s3cr3t-token` or `#password`

#### Scenario: an exec script's typed text does not leak into the log

- **WHEN** the daemon serves an `exec.runScript` request whose steps are `fill "#password" "hunter2"` and `storage local set token "s3cr3t"`
- **THEN** the log contains the method, the step command names and the target arguments, and `<redacted 7 bytes>` and `<redacted 6 bytes>` in place of the arguments; it SHALL NOT contain `hunter2` or `s3cr3t`

