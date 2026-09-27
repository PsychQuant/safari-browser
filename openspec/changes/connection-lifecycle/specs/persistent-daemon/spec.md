## ADDED Requirements

### Requirement: Accepted connection revocation prevents new dispatch

Each accepted connection SHALL have a unique identity and owning daemon generation. Stop SHALL revoke each owned connection and cancel its transport task. Reading, parsing, and buffered-frame completion SHALL NOT independently authorize handler work: the Instance SHALL check active connection identity, generation, and cancellation in the same actor turn that admits the handler task. A revoked request SHALL NOT update a replacement generation's activity or in-flight records. A revoked connection SHALL NOT admit another handler, including a complete frame received after stop or a buffered second frame. Cancellation SHALL NOT be classified as a successful EOF-terminated request.

#### Scenario: Input arrives after stop

- **WHEN** a connection passes its read-loop check, is stopped, and then receives a complete fixture.sideEffect request
- **THEN** the handler invocation count remains zero
- **AND** the transport closes without replaying that request

#### Scenario: Waiting peer sends no data

- **WHEN** an accepted client is waiting for its first request and the Instance stops
- **THEN** revocation closes the transport without requiring the peer to send data
- **AND** a controlled local fixture observes transport completion within two seconds

#### Scenario: Buffered request after revocation

- **WHEN** two request frames arrive together and stop revokes the connection while the first handler is active
- **THEN** the second handler is not admitted
- **AND** side effects already started by the first handler are not represented as undone

### Requirement: Connection descriptor access and closure have one owner

A connection owner SHALL configure its socket for nonblocking I/O, close-on-exec, and SIGPIPE suppression. The owner SHALL serialize each stream-I/O descriptor access and shutdown/close against revocation with one short lock; it SHALL NOT wait for I/O while holding that lock or publish a raw descriptor for use after suspension. Revocation and final close SHALL be idempotent. Would-block retries SHALL await native readiness asynchronously outside the lock and respond to cancellation; interrupted retries SHALL yield without busy spinning. Reuse of a retired descriptor number SHALL NOT permit an old read, write, cancellation response, or completion callback to affect a replacement connection.

Native readiness notifications SHALL use a privately owned close-on-exec duplicate that performs no stream I/O and is never published in request snapshots. The duplicate SHALL close only in the dispatch source cancellation handler. Revocation SHALL cancel and wake pending readiness waits, and completed/cancelled sources SHALL retire their duplicate descriptors without one-per-wait accumulation.

#### Scenario: Readiness notification completes or is cancelled

- **WHEN** a read/write wait is completed by peer input, peer EOF, deadline, task cancellation, or owner revocation
- **THEN** exactly one outcome completes the wait
- **AND** its native monitor is cancelled and its private descriptor is closed in the cancellation handler

#### Scenario: Descriptor number is reused

- **WHEN** a revoked connection closes its descriptor and a new owned fixture receives that same descriptor number
- **THEN** resuming the old connection's read/write or completion path leaves the replacement descriptor and contents untouched

#### Scenario: Slow reader and writer

- **WHEN** a peer stops providing request data or consuming response bytes
- **THEN** the daemon releases its lock while awaiting readiness
- **AND** stop revokes the owner and allows its transport task to finish without waiting for the peer

### Requirement: Completed transport and request work retires by identity

Completed transport tasks SHALL be removed from the Instance registry while the daemon remains running. A transport waiting for a handler SHALL use single-completion cancellation arbitration so transport cancellation does not wait for a noncooperative handler. Its reader and frame ownership SHALL end when the transport task ends. Already admitted handler work SHALL retain separate unfinished-work tracking until it actually returns; completed operation handles SHALL then retire by connection and request identity. Late results after cancellation SHALL be discarded rather than retained or written. A prior generation's completion SHALL NOT remove a replacement generation's records. Verification SHALL distinguish logical byte ownership from measured process memory and SHALL NOT infer Foundation buffer capacity from Data.count.

#### Scenario: Repeated connection completion

- **WHEN** three clients connect and disconnect normally without stopping the daemon
- **THEN** all three transport tasks retire and the active transport registry returns to zero

#### Scenario: Handler ignores cancellation

- **WHEN** a handler has started and deliberately waits on a fixture gate while its connection is stopped
- **THEN** the transport finishes and closes its socket before that gate opens
- **AND** the handler remains identified as unfinished until it returns
- **AND** its late result produces no reply and cannot retire a new connection

#### Scenario: Large request churn

- **WHEN** owned large-request connections repeatedly complete and close
- **THEN** completed transport/operation counts return to baseline and ownership-release observations are recorded
- **AND** a process-footprint measurement is reported as observed evidence, without claiming a fixed whole-process memory bound

### Requirement: Shutdown replies preserve framing and bounded progress

Each request SHALL claim at most one response frame across normal completion and shutdown cancellation. Once a frame write begins, another result SHALL NOT be interleaved into it. The shutdown caller's acknowledgement SHALL be attempted before the connection-revocation plan, with a total write budget of 250 milliseconds. In-flight cancellation replies SHALL share a separate 250-millisecond absolute deadline across all clients; the deadline SHALL NOT reset per client or partial write. A failed or expired reply attempt SHALL NOT prevent revocation and stop. Cancellation snapshots SHALL refer to connection/request identities through their owners rather than delayed writes to raw descriptor numbers. Existing cancelled envelopes SHALL remain domain errors, and interrupted post-send replies SHALL retain the client's outcome-unknown/no-replay behavior. Normal requests SHALL retain their existing execution-time policy and framing limits.

#### Scenario: Normal result races cancellation

- **WHEN** normal handler completion and shutdown cancellation compete for one request's response
- **THEN** only one response frame is claimed
- **AND** cancellation never appends JSON inside a partially written normal frame

#### Scenario: Shutdown client does not consume the acknowledgement

- **WHEN** the shutdown caller or another in-flight client does not read response data
- **THEN** acknowledgement/cancellation attempts consume only their respective shared deadlines
- **AND** the daemon continues revocation without waiting indefinitely for those clients

#### Scenario: Existing request framing remains compatible

- **WHEN** clients send exact-limit lines, coalesced lines, valid EOF-terminated final lines, or over-limit frames
- **THEN** the existing 128 MiB request-line policy and parser/dispatch boundaries remain intact
- **AND** connection revocation cannot convert a partial cancelled frame into a new handler invocation

## MODIFIED Requirements

### Requirement: Daemon run cleanup is generation owned

The outer Server SHALL bind startup, shutdown hooks, listener notifications, watchdog decisions, resource handles, and stop waiters to a Run identity. Connections SHALL capture their shutdown generation and hook when admitted; a shutdown request suspended across stop/start SHALL NOT obtain the replacement run's hook, in-flight snapshot, or process watchdog. Each new run SHALL begin a fresh idle interval. Concurrent starts SHALL share the same startup operation. A new start during teardown SHALL wait for that teardown before binding paths. Concurrent stops SHALL share one cleanup operation. Startup failures and listener failures SHALL clean the owning run without waiting for its accept loop or diagnostic writer. PID cleanup SHALL remove only an entry whose captured device/inode still matches; replaced or unconfirmed entries SHALL be retained.

#### Scenario: Failure before startup completes

- **WHEN** a listener fails before the startup operation returns
- **THEN** startup does not later restore running state, the owning pid and socket are cleaned, and the failure remains observable

#### Scenario: Concurrent stop and restart

- **WHEN** two stop callers and a subsequent start overlap
- **THEN** both stop callers await the same old cleanup, and the new run binds its paths only after that cleanup finishes
- **AND** delayed old listener, shutdown, or watchdog callbacks cannot stop the new run

#### Scenario: Shutdown resumes after a replacement run starts

- **WHEN** an accepted shutdown request is paused in logging while its run stops and a replacement run starts
- **THEN** the old transport is revoked and the resumed request cannot invoke a shutdown hook or process watchdog for the replacement run
- **AND** a missing or partial reply remains an outcome-unknown result without replay; a complete cancelled envelope retains its domain-error meaning
- **AND** a hook-free embedded instance applies the same generation guard before fallback stop

#### Scenario: PID entry replaced before old cleanup

- **WHEN** the recorded pid entry is replaced after its identity was captured
- **THEN** cleanup retains the replacement rather than unlinking by path alone

---
