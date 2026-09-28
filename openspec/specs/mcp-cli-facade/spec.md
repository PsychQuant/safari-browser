# mcp-cli-facade Specification

## Purpose

Expose the existing CLI through a generated MCP stdio facade while preserving command validation, bounded output and isolated execution semantics.

## Requirements

### Requirement: Metadata catalog
The MCP tool catalog SHALL be generated at runtime from the current ArgumentParser metadata, including expanded OptionGroups and all existing public leaf commands. Hidden branches and the MCP transport itself SHALL be excluded. Unknown metadata versions, unsupported shapes and naming collisions SHALL fail explicitly. CLI scalar values SHALL remain strings where metadata does not supply a trustworthy scalar type. Runtime CLI validation SHALL remain authoritative for semantic and mutual-exclusion constraints.

#### Scenario: Full public coverage
- **WHEN** the MCP transport and hidden worker are added to the baseline 78-leaf CLI with two pre-existing hidden leaves
- **THEN** all 76 existing public leaves, including setup, daemon controls and help, have generated tool schemas with deterministic names.

#### Scenario: Literal arguments
- **WHEN** a JSON option value begins with a dash or a positional includes spaces and quotes
- **THEN** the mapper preserves that value as one CLI argument without shell interpretation; invalid types, unknown keys, NUL argv or missing required values fail before execution.

---
### Requirement: Isolated command worker
Each tool call SHALL execute the existing command struct through an isolated worker of the same executable and a newly parsed command instance. CLI business logic SHALL NOT be duplicated. A healthy persistent worker SHALL support multiple sequential calls under the mcp-persistent-worker isolation and retirement contract; explicit isolated mode SHALL retain one fresh CLI execution process per call. Worker input/output SHALL be separate from MCP protocol streams. Worker build identity SHALL match the catalog's running image before dispatch, including nested CLI invocations. Ordinary CLI behavior SHALL remain unchanged outside the internal MCP context, and MCP workers SHALL NOT route implicitly through a daemon.

#### Scenario: One-shot lifetime and argument admission
- **WHEN** explicit isolated mode or persistent preselection executes one fresh CLI instance
- **THEN** it SHALL preserve the original kernel argv/environment admission while independently supervising host lifetime and retaining unconfirmed cleanup ownership
- **AND** adding supervision SHALL NOT narrow public input limits, replace the business exit status with a helper status, or replay an uncertain invocation

#### Scenario: Helper runtime augments the environment
- **WHEN** the supervisor runtime adds an environment entry before executing the one-shot CLI
- **THEN** the child SHALL receive the parent's original environment snapshot and preserve the original kernel admission boundary rather than inheriting the helper's augmented environment

##### Example: Environment padding at the kernel boundary
- **GIVEN** original argv immediately below the kernel rejection boundary with either zero or 8192 bytes of environment padding
- **WHEN** the supervised runner executes the same input
- **THEN** the accepted original input SHALL still execute and the adjacent rejected input SHALL remain rejected

#### Scenario: Executable changes
- **WHEN** the executable at the launch path is replaced after the server starts
- **THEN** a different launch-path or loaded worker image is rejected before running the tool, including when a worker is already warm and the caller is told to restart; the operation is not retried on another engine.

#### Scenario: Image rejection capture metadata
- **WHEN** an isolated CLI worker returns its executable-image validation error
- **THEN** a fully captured exit-64 error SHALL retain capture_complete true and failure null while isError remains true
- **AND** a persistent pre-dispatch image rejection SHALL retain its explicit failure and capture_complete false without retrying

#### Scenario: Cancellation or capture limit
- **WHEN** a worker is cancelled, exceeds its configured timeout, or exceeds output limits
- **THEN** its owned process group is stopped and reaped, incomplete output is not reported as success, and prior side effects are not claimed to be rolled back.

---
### Requirement: Stdio protocol
The server SHALL support modern 2026-07-28 request metadata and legacy 2025-06-18/2025-11-25 initialization. It SHALL implement discover, ping, tools/list pagination and tools/call, preserve result/error framing, and reject malformed requests without executing commands. Only one tool invocation SHALL execute at a time; cancellation and discovery SHALL remain responsive. Cancelled requests SHALL receive no subsequent response; EOF SHALL clean up in-flight and idle workers. stdout SHALL contain only MCP JSON-RPC messages.

#### Scenario: Both protocol eras
- **WHEN** a modern client supplies per-request version/capabilities or a legacy client completes initialization
- **THEN** each receives the catalog and tool results according to its supported revision; missing modern metadata or unsupported versions produce explicit protocol errors.

#### Scenario: CLI diagnostics
- **WHEN** the command writes stdout/stderr or exits nonzero
- **THEN** the MCP result preserves separate encoded streams and exit status, presents stderr before data, and distinguishes command failure from a successful empty result.

---
### Requirement: Complete facade verification
Verification SHALL cover every public tool's schema/argv mapping and safe help routing, representative actual synchronous/asynchronous CLI execution, stdin/stream isolation, cancellation/EOF, malformed protocol inputs and unchanged CLI regression tests. Test results SHALL distinguish adapter coverage from real Safari UI side-effect coverage.

#### Scenario: Runtime constraints remain
- **WHEN** a shape-valid call supplies mutually exclusive target options or an invalid CLI value
- **THEN** the existing CLI validation rejects it, a tool error is returned, and later requests remain usable.
