## MODIFIED Requirements

### Requirement: Isolated command worker
Each tool call SHALL execute the existing command struct through an isolated worker of the same executable and a newly parsed command instance. CLI business logic SHALL NOT be duplicated. A healthy persistent worker SHALL support multiple sequential calls under the mcp-persistent-worker isolation and retirement contract; explicit isolated mode SHALL retain one process per call. Worker input/output SHALL be separate from MCP protocol streams. Worker build identity SHALL match the catalog's running image before dispatch, including nested CLI invocations. Ordinary CLI behavior SHALL remain unchanged outside the internal MCP context, and MCP workers SHALL NOT route implicitly through a daemon.

#### Scenario: Executable changes
- **WHEN** the executable at the launch path is replaced after the server starts
- **THEN** a different launch-path or loaded worker image is rejected before running the tool, including when a worker is already warm and the caller is told to restart; the operation is not retried on another engine.

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
