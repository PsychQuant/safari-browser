## Purpose

Reuse an isolated CLI execution process for MCP calls while preserving per-request state and stream boundaries. Define bounded worker ownership, recovery and measurement without authorizing replay of uncertain operations.

## ADDED Requirements

### Requirement: Persistent workers execute fresh command instances
The MCP server SHALL default to persistent mode and expose an explicit isolated mode for comparison and compatibility. Each host SHALL have at most one supervisor/worker pair and one active CLI invocation. Healthy sequential calls SHALL execute in the same worker process using newly parsed command instances, rather than spawning a new CLI behind a persistent broker. Busy calls SHALL preserve the existing not-executed rejection while discovery and cancellation remain responsive. The private helpers SHALL remain excluded from the public tool catalog.

#### Scenario: Healthy sequential calls reuse the actual worker
- **WHEN** twenty sequential wait 0 calls complete without retirement conditions
- **THEN** the actual CLI worker PID SHALL remain the same and each call SHALL have independent request and timing identities

#### Scenario: A second business call arrives during execution
- **WHEN** a tool is executing or its worker is stopping
- **THEN** the second call SHALL be rejected as not executed while ping, discovery and cancellation remain responsive

### Requirement: Private worker messages are bounded and correlated
The internal channel SHALL use a private inherited socket, separate from CLI stdin/stdout/stderr and public MCP JSON-RPC. Requests SHALL carry a generated UUID, literal argv and independently encoded stdin; output chunks and completion SHALL carry the same UUID. Client frames SHALL be limited to 8 MiB, server frames to 64 KiB, stdin to 4 MiB and individual output chunks to 8192 decoded bytes. PID and exit-code metadata SHALL use canonical decimal strings with explicit ranges; malformed types, NUL argv, invalid base64, unknown message shapes and stale identifiers SHALL fail without echoing the request. A completion frame SHALL follow all output chunks for that request.

#### Scenario: Output resembles protocol JSON
- **WHEN** CLI stdout contains JSON that resembles a completion or another request
- **THEN** it SHALL remain output data tagged with the current UUID and SHALL NOT become a control message

#### Scenario: A stale or incomplete frame arrives
- **WHEN** the worker returns the wrong UUID or closes its channel partway through a frame
- **THEN** the host SHALL retire that generation and report incomplete or unknown outcome without assigning the bytes to a subsequent call

### Requirement: Request state and streams are isolated before reuse
Every invocation SHALL receive separate stdin, stdout and stderr capture, a fresh trace and a fresh dialog-probe gate. The worker SHALL flush and seal request stdio and finish its known auxiliary writers before declaring successful completion. It SHALL NOT retain Safari target, AX verdict, warning budget or prior request output for the next invocation. A worker with unfinished AX work SHALL be retired after the current result; unconfirmed descendants or failed stream cleanup SHALL produce incomplete capture and retirement. Each stream's host capture SHALL remain bounded at 2 MiB and the public MCP response at 8 MiB.

#### Scenario: Stdin and diagnostics differ between calls
- **WHEN** one exec request consumes supplied stdin and emits diagnostics, followed by a different request
- **THEN** the latter SHALL receive only its own stdin/output/diagnostics and a new probe budget

#### Scenario: A producer exceeds the capture bound
- **WHEN** stdout or stderr exceeds its configured capture limit
- **THEN** the host SHALL retain only the allowed prefix, mark the result incomplete, terminate the owned group and refuse reuse of that worker

### Requirement: Supervisor ownership survives controller death
The host SHALL launch its supervisor as a new process-group leader and the actual worker SHALL inherit that group. The supervisor SHALL execute no CLI work and SHALL observe a lifetime pipe whose sole write owner is the host. EOF on that lease SHALL terminate the supervisor's live group even when the actual worker is stopped or unresponsive. No helper or descendant SHALL inherit the lease write end. Host-originated group signals SHALL use only its locally spawned, still-live or unreaped supervisor reservation, never a PID supplied in a worker message. The last signal SHALL precede reaping; lost ownership SHALL stop further signaling and surface a cleanup failure.

#### Scenario: Controller dies while the actual worker is stopped
- **WHEN** the process holding the sole lifetime writer dies while the actual worker is SIGSTOPed
- **THEN** the supervisor SHALL observe EOF and terminate its group
- **AND** verification SHALL observe actual worker termination, not infer it merely from controller exit

#### Scenario: Host dies after retirement TERM
- **WHEN** the host sends group TERM and then dies before escalating to KILL while an actual worker or ordinary descendant has not terminated
- **THEN** the supervisor SHALL still observe its lifetime lease and terminate the owned group independently of that worker
- **AND** the supervisor's TERM disposition SHALL NOT be inherited as ignored TERM by the actual CLI

#### Scenario: Actual CLI completes during TERM grace
- **WHEN** a one-shot CLI handles TERM and completes its cleanup within the 150 ms grace period
- **THEN** the supervisor SHALL remain alive long enough to record the actual CLI status rather than shortening grace by terminating itself

#### Scenario: An explicitly started daemon detaches
- **WHEN** a public daemon start command deliberately creates its separate service group
- **THEN** request cleanup SHALL leave that explicitly created daemon unaffected while terminating ordinary owned descendants

#### Scenario: A stopped leader is still reserved
- **WHEN** waitid reports a stopped event for the owned leader
- **THEN** the host SHALL keep it classified as not exited and SHALL NOT reap based on that event

#### Scenario: Group membership changes after an initial kill
- **WHEN** a live member remains or joins while the terminated leader is still reserved
- **THEN** retirement SHALL continue signaling only that reserved group until it is quiescent or the cleanup deadline expires
- **AND** an unconfirmed cleanup SHALL retain the owner instead of authorizing a new pair

### Requirement: Retirement and recovery never replay uncertain work
Cancellation, timeout, EOF, invalid control data and output backpressure SHALL cause bounded userspace retirement while preserving unknown-outcome semantics after request transmission. The host SHALL stop and reap its owned group before reusing the slot; if cleanup cannot be confirmed it SHALL report failure and SHALL NOT start additional workers to hide the unresolved owner. A crash SHALL permit a fresh pair for the next distinct invocation, not retransmission of the failed invocation. Idle pairs SHALL retire after the configured finite idle interval, with generation checks preventing stale timers from stopping active or replacement workers. Session shutdown SHALL retire idle workers as well as active ones.

#### Scenario: Side effect occurs before the response is lost
- **WHEN** an owned fixture records an effect and the worker then crashes or loses its reply
- **THEN** that call SHALL report incomplete or unknown outcome and the effect counter SHALL remain one
- **AND** a later distinct call SHALL be able to start a new worker after confirmed cleanup

#### Scenario: Idle deadline races a new request
- **WHEN** an old idle timer fires as a new call is admitted
- **THEN** generation ownership SHALL select either retirement before dispatch or the active request, without killing a replacement or admitting two pairs

#### Scenario: An idle channel closes before a new request is transmitted
- **WHEN** the cached worker channel is closed before any bytes of a new invocation are sent
- **THEN** the host SHALL retire that generation and SHALL execute the new invocation once in a fresh pair after confirmed cleanup
- **AND** it SHALL NOT retransmit an invocation whose transmission already began

#### Scenario: MCP stdout is unread at EOF
- **WHEN** public MCP output is backpressured and input closes
- **THEN** active and idle worker cleanup SHALL proceed independently of that output stream

#### Scenario: Preselected one-shot survives no longer than its host lifetime protection
- **WHEN** a valid large-argv or private-encoding-expansion request selects one-shot execution and the MCP host dies during the call
- **THEN** independent lifetime supervision SHALL terminate the actual owned worker and its ordinary descendants without requiring that worker to respond
- **AND** verification SHALL observe actual worker termination, not only host termination

##### Example: Large valid wait input
- **GIVEN** a valid `wait 5000` argument with enough leading zeroes to trigger kernel-admission preselection
- **WHEN** the owned MCP host is terminated after one-shot launch
- **THEN** the worker SHALL be cleaned up by its lifetime supervisor rather than waiting for the five-second command to complete naturally

#### Scenario: Preselected cleanup cannot be confirmed before its deadline
- **WHEN** one-shot cleanup reaches its userspace deadline without confirming a quiescent group and actual leader exit
- **THEN** the runner SHALL return an incomplete cleanup result, retain the reserved owner and refuse new business execution
- **AND** it SHALL NOT block indefinitely in waitpid or release signal authority for reuse

### Requirement: Warm workers honor executable identity and argument admission
The loaded worker image SHALL match the host catalog image. Before each persistent dispatch, the launch-path image SHALL be checked using bounded Mach-O parsing, including the applicable thin or universal slice. Missing, malformed, ambiguous or different images SHALL invalidate the worker and require host restart without dispatching on another engine. Identity SHALL NOT be represented as an atomic guarantee against a later filesystem replacement or as code-signing authentication. Calls near the OS argv/environment boundary SHALL select the original isolated runner before any private request bytes, preserving kernel admission rather than imposing a new approximate rejection or widening its limit. No execution failure SHALL trigger backend retry.

#### Scenario: Executable changes while the worker is warm
- **WHEN** a private executable copy is atomically replaced with a different image UUID after a successful call
- **THEN** the next tool SHALL be rejected before dispatch with the existing executable-changed/not-executed guidance while protocol discovery remains usable

#### Scenario: A large argv requires original kernel admission
- **WHEN** the estimated argv/environment reservation exceeds half of the system ARG_MAX
- **THEN** the cached pair SHALL retire and the original runner SHALL execute or reject that call exactly once

#### Scenario: Worker-only invalidation remains sticky after path restoration
- **WHEN** the host observes image A, the worker rejects replacement image B, and the path is restored to A
- **THEN** the worker SHALL report a typed image invalidation and the host SHALL reject subsequent dispatch until restart

#### Scenario: Private encoding grows beyond the transport cap
- **WHEN** a public request fits the existing input limits but private base64 and JSON expansion exceeds 8 MiB
- **THEN** the host SHALL select the original runner before sending any private request bytes, preserving kernel admission

#### Scenario: Preselected execution keeps the invocation deadline
- **WHEN** image inspection or cached-pair retirement consumes part of the invocation's time budget before isolated dispatch
- **THEN** the original runner SHALL use the same absolute deadline and SHALL reject execution if it has already expired
- **AND** an inherited deadline later than the configured per-call timeout SHALL NOT extend that timeout

### Requirement: Persistent worker benefits and regressions are measured
Verification SHALL compare isolated and persistent modes from the same build under the same fixed fixture, sample count and deadline, reporting cold/warm p50, p95, success rates and actual worker PID reuse. It SHALL separate spawn syscall, loader/entry, parsing, execution and exit/cleanup evidence rather than calling all overhead spawn time. Warm p50 and p95 SHALL improve without reducing the successful-call rate before performance acceptance. Cold-start and resident-process costs SHALL be disclosed. Existing full catalog/help, CLI validation, stdin, cancellation, EOF, process-group, backpressure, explicit-daemon and binary-replacement regressions SHALL remain covered; adapter evidence SHALL NOT be presented as new Safari GUI acceptance.

#### Scenario: Compare the same harmless fixture
- **WHEN** both modes run the same wait 0 fixture with equal warmups and measured samples
- **THEN** the report SHALL distinguish cold host startup from repeated warm calls and SHALL identify the measured worker reuse
- **AND** successful fixed-input repetition inside a diagnostic prototype SHALL NOT substitute for lifecycle implementation or recovery verification
