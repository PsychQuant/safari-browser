## Purpose

Provide opt-in, bounded randomized spacing after CLI operations without requiring callers to insert explicit waits. Keep command results, cancellation boundaries, and execution modes consistent while preserving default speed.

## ADDED Requirements

### Requirement: Explicit environment policy

The CLI SHALL treat an absent, empty, or `off` value of `SAFARI_BROWSER_PACING` as disabled and `cauchy` as enabled. Other values SHALL fail before an eligible operation executes. Enabled policy SHALL accept optional numeric `SAFARI_BROWSER_PACING_MIN_MS`, `SAFARI_BROWSER_PACING_MAX_MS`, `SAFARI_BROWSER_PACING_MEDIAN_MS`, and `SAFARI_BROWSER_PACING_SCALE_MS`, using the existing truncated Cauchy defaults and adaptive scale. It SHALL reject nonfinite, invalid-distribution, nonrepresentable-nanosecond and max-above-3600000ms configurations before effects. Disabled policy SHALL ignore ancillary pacing parameters and perform no extra sleep. Global pacing SHALL NOT expose a seed.

#### Scenario: Explicit off overrides inherited parameters
- **WHEN** pacing is `off` and inherited pacing numeric parameters are invalid
- **THEN** the command SHALL retain its original execution behavior without pacing validation failure or additional sleep

#### Scenario: Invalid enabled settings do not execute
- **WHEN** pacing is enabled with min greater than median or max above 3600000ms
- **THEN** the CLI SHALL report a configuration error on stderr before invoking the operation

### Requirement: One bounded delay at the command boundary

For an eligible public command, the CLI SHALL validate and draw one duration before invoking the operation, then await that duration once after operation success or runtime error. It SHALL reuse the existing truncated Cauchy sampler and checked nanosecond conversion, draw anew per operation, and preserve the operation's output and error after a completed wait. Nearly fixed distributions SHALL retain the existing warning. It SHALL NOT clamp invalid draws or substitute an unbounded sleep.

#### Scenario: Ordering and runtime failure
- **WHEN** an eligible command throws a runtime error under enabled pacing
- **THEN** events SHALL occur in the order prepare, operation, sleep, original error propagation
- **AND** the operation SHALL execute exactly once

#### Scenario: Preparation failure
- **WHEN** configuration or sampling fails
- **THEN** neither the operation nor its post-operation sleep SHALL execute

### Requirement: Explicit exemptions and wrapper ownership

Help, root and command-group usage, parse or parser-validation errors, explicit `wait`, all daemon management commands, long-lived MCP or daemon hosts, and hidden wrappers SHALL NOT receive an additional pacing wait. Hidden one-shot wrappers SHALL apply the policy to their eligible inner command exactly once. The `exec` container SHALL NOT wait after the entire batch; each actually dispatched eligible step SHALL own its wait. Skipped steps SHALL NOT wait. Explicit wait steps SHALL retain their own semantics without extra pacing.

#### Scenario: Help remains available
- **WHEN** help is requested with invalid pacing settings
- **THEN** the CLI SHALL produce its normal help response without pacing validation or sleep

#### Scenario: Two steps and one skipped step
- **WHEN** a batch dispatches two eligible steps and skips a third by its condition
- **THEN** there SHALL be two additional waits, one after each dispatched operation, and no container or skipped-step wait

#### Scenario: One-shot wrapper does not double wait
- **WHEN** isolated MCP invokes an eligible inner command through its hidden wrapper
- **THEN** the inner command SHALL receive one wait and the wrapper SHALL receive none

### Requirement: Cancellation never replays an operation

Enabled pacing SHALL check cancellation before invoking an operation. Operation cancellation or an already cancelled task SHALL stop additional waiting. Cancellation during a post-operation wait SHALL NOT rerun the operation. If the operation succeeded, pacing interruption SHALL produce a nonzero result with a fixed diagnostic stating that the operation already executed and effects are not undone. If the operation already failed, that original error SHALL remain authoritative. Existing OS signal handling and MCP deadlines SHALL remain unchanged, with pacing time included in the invocation budget and unknown-outcome semantics retained after effects.

#### Scenario: Cancel after a side effect
- **WHEN** a fixture records its operation effect and cancellation interrupts the following sleep
- **THEN** the effect count SHALL remain one
- **AND** the result SHALL NOT claim that the operation was never executed

#### Scenario: Preserve an earlier operation error
- **WHEN** an operation fails and its pacing wait is interrupted
- **THEN** the original operation error SHALL be propagated without a retry

### Requirement: Consistent callers and documented scope

Standalone CLI, isolated MCP and persistent MCP SHALL use the same parsed-command pacing boundary. Policy scope SHALL be one invocation and SHALL NOT leak between persistent calls. Documentation SHALL specify enable/disable examples, parameter units/defaults, exemptions, exec routing cost, and that MCP timeout includes the added waits. It SHALL distinguish per-caller pacing from cross-process rate limiting and SHALL NOT promise avoidance of remote anti-bot measures. Defaults SHALL remain disabled.

#### Scenario: Persistent policy isolation
- **WHEN** an enabled invocation is followed by a disabled invocation in the same process
- **THEN** only the enabled invocation SHALL add a wait
- **AND** the previous invocation's policy SHALL NOT remain active

#### Scenario: Caller parity
- **WHEN** the same eligible non-GUI runtime-failure fixture runs through standalone, isolated and persistent modes with the same policy
- **THEN** all modes SHALL preserve the original error result and apply one bounded wait
