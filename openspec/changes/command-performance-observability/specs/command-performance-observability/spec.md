## ADDED Requirements

### Requirement: Opt-in bounded request timing
The CLI SHALL enable timing only when SAFARI_BROWSER_TRACE_TIMING equals 1. It SHALL preserve normal stdout and command behavior, emitting at most one own summary to stderr with prefix `[safari-browser timing] ` and schemaVersion 1. Producers SHALL include their positive processID; readers SHALL allow its absence in a single older summary. The summary SHALL contain requestID, status, totalNanoseconds, spans and droppedSpans. Each span SHALL contain id, optional parentID, phase, durationNanoseconds and outcome. It SHALL use monotonic elapsed time, at most 64 spans and at most 64 KiB of encoded output.

#### Scenario: Disabled timing
- **WHEN** timing is absent or disabled
- **THEN** no timing summary SHALL be emitted and normal output SHALL remain unchanged

#### Scenario: Parent and child summaries share stderr
- **WHEN** exec forwards timing summaries from child processes
- **THEN** the benchmark SHALL identify the unique root summary by its actual process ID and SHALL NOT guess by duration or order

#### Scenario: Nested operation fails
- **WHEN** an instrumented operation throws
- **THEN** the original error SHALL propagate exactly once and its span SHALL be marked error
- **AND** inclusive child durations SHALL NOT be summed as total time

### Requirement: Timing excludes operation contents
Timing SHALL use only predefined phase and outcome values. It SHALL NOT contain scripts, URLs, selectors, clipboard data, file contents, private paths, arbitrary error messages or caller-supplied labels.

#### Scenario: Sensitive command fails
- **WHEN** a command or error contains sensitive strings
- **THEN** the timing summary SHALL contain only allowed metadata and SHALL NOT copy those strings

### Requirement: Timing contexts remain isolated
Each CLI worker and opted-in daemon request SHALL own a separate timing context. Persistent daemon and MCP hosts SHALL NOT collect all requests into one lifetime trace. A finished context SHALL reject late additions; unfinished spans SHALL be marked unfinished and excess spans SHALL increase droppedSpans.

#### Scenario: Late AX worker
- **WHEN** a request finishes before a read worker returns
- **THEN** the already emitted summary SHALL remain unchanged and SHALL NOT be attached to another request

### Requirement: Optional daemon timing preserves execution semantics
A daemon request SHALL enable service timing only with a literal Boolean timing value of true. The response SHALL attach bounded timing metadata only for that opted-in request. Clients SHALL validate and bound remote timing metadata; absent or invalid metadata SHALL NOT alter the command result or cause replay. Compile and execute measurements SHALL retain their existing main-actor isolation.

#### Scenario: Old daemon omits timing
- **WHEN** a successful daemon response contains no timing metadata
- **THEN** the command SHALL return its original result and report only measurable client-side phases

### Requirement: Reproducible performance benchmark
The benchmark SHALL provide bounded, fixed safe scenarios for CLI, exec, daemon and MCP. It SHALL report external monotonic wall time separately from main-entry timing, identify fresh process versus warm service, retain failure and SKIP counts, and compute nearest-rank p50 and p95 from successful samples. It SHALL record executable digest, OS build, architecture, sample counts and warmup counts without publishing private executable paths or page data. It SHALL use only its own process groups, daemon namespace and GUI fixtures, and SHALL NOT perform Print or arbitrary repeated mutations.

#### Scenario: GUI unavailable or not requested
- **WHEN** a GUI scenario cannot run
- **THEN** it SHALL be reported as SKIP, not as a zero-time success

#### Scenario: Timed out sample
- **WHEN** a sample exceeds its deadline
- **THEN** its owned process group SHALL be cleaned up and the sample SHALL remain failed without automatic retry
