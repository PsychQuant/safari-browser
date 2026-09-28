## ADDED Requirements

### Requirement: Request payload logs identify prepared responses
Request payload log records SHALL retain the existing ts, method, requestId, durationMs, params, result and error fields and existing redaction/truncation behavior. They SHALL additionally identify event as request_response_prepared, requestToken as the server-generated request-work UUID, and peerReceipt as unconfirmed. A result field SHALL describe the existing redacted or truncated preview of a prepared result value, not a complete wire envelope, not business success, completed shutdown, transmitted bytes or peer receipt. Consumers SHALL filter payload records by event and correlate related records by requestToken, not by client-controlled requestId alone.

#### Scenario: Existing payload content remains private
- **WHEN** an admitted request prepares a response with logging enabled
- **THEN** its payload record SHALL have the prepared event and UUID token while preserving the configured source redaction, result truncation and malformed-frame marker
- **AND** peerReceipt SHALL be unconfirmed in both normal and logFull modes

#### Scenario: Reused client identifiers do not merge operations
- **WHEN** two admitted operations use requestId 7
- **THEN** their requestToken values SHALL differ and each operation's related events SHALL use its own token

### Requirement: Operation candidate logs reflect reply arbitration
After the original operation offers its Reply to the single-completion arbiter, it SHALL emit a request_response_candidate record using the actual offer result. This record SHALL contain only ts, event, requestToken, peerReceipt=unconfirmed, outcome from result/parse_error/method_not_found/handler_error/cancelled, and selection from selected/not_selected/not_offered. An operation whose initial cancellation check observes cancellation SHALL cancel its pending gate before recording cancelled/not_offered. This event SHALL describe the original operation's candidate, not an exhaustive trace of other cancellation producers or a guarantee that a selected frame was written. A losing candidate SHALL NOT be reported as selected or replayed.

#### Scenario: Shutdown revoked during prepared logging
- **WHEN** shutdown prepared logging is blocked and the instance stops and restarts before the writer returns
- **THEN** the old operation SHALL report cancelled/not_selected after its existing generation guard rejects the plan
- **AND** its prepared result SHALL remain explicitly labelled as prepared while the actual post-send client outcome remains unknown

#### Scenario: Late handler result loses arbitration
- **WHEN** a noncooperative admitted handler returns a result after its transport was cancelled
- **THEN** its candidate record SHALL report result/not_selected and SHALL NOT claim the side effect was undone or a peer received that result

### Requirement: Shutdown handoff logs report the final guarded handoff
A shutdown with an authorized plan SHALL emit request_shutdown_handoff only after its final guarded handoff returns. Its outcome SHALL be rejected when its generation is no longer authorized, hook_returned when the captured hook returns, or instance_stopped when the instance's own stop path runs. The record SHALL contain only ts, event, requestToken, outcome and peerReceipt=unconfirmed. It SHALL NOT claim that an arbitrary hook stopped all operations or that an ACK reached its peer. Existing post-logging and final generation guards SHALL remain effective.

#### Scenario: Normal shutdown completes its own stop path
- **WHEN** a current shutdown has no external hook and reaches its final guarded handoff
- **THEN** the instance SHALL stop before recording instance_stopped
- **AND** its ACK attempt SHALL retain the existing bounded-write and no-replay semantics

#### Scenario: A prepared plan loses authority before handoff
- **WHEN** the old shutdown has prepared its plan but a replacement instance starts before the final handoff
- **THEN** the old event SHALL report rejected without invoking a replacement hook or stopping the replacement instance

### Requirement: Outcome logging preserves lifecycle and logger ownership
Every new request event SHALL use the writer captured when its work was admitted. Candidate writers SHALL run in the original operation outside the Instance actor after arbitration; handoff writers SHALL run in that same tracked operation after a fixed outcome is reported by the transport. Transport completion SHALL NOT wait for a handoff writer. A selected shutdown plan SHALL report its handoff outcome even when its original operation task has been cancelled; unrelated request-result cancellation semantics SHALL remain unchanged. Stop SHALL NOT wait for these writers. New events SHALL NOT allocate independent logger tasks or an unbounded queue. A request SHALL emit at most one prepared record and one original-candidate record, plus at most one handoff record for a shutdown plan. Event persistence SHALL remain best-effort: missing records SHALL NOT imply success or non-execution, and physical line order across requests SHALL NOT establish lifecycle ordering. Disabled logging SHALL remain silent.

#### Scenario: Replacement logger cannot receive old events
- **WHEN** an admitted request completes after logger replacement and stop/start
- **THEN** all of its emitted records SHALL use its captured writer and token while the replacement logger receives only newly admitted work

#### Scenario: Candidate writer blocks after selection
- **WHEN** the candidate-event writer blocks after the reply arbiter accepts a response
- **THEN** the transport SHALL still be able to complete its response and stop SHALL return without awaiting the blocked writer

#### Scenario: Handoff writer blocks after stop
- **WHEN** the handoff-event writer blocks after the instance stop path has returned
- **THEN** the instance SHALL already be stopped and a replacement instance SHALL remain independently usable

### Requirement: Captured file log writers retain their owned append sink
A Run SHALL release its own file-sink ownership during teardown without closing a sink still owned by captured request or diagnostic writers and without awaiting those writers. The final owner SHALL close the descriptor. File sinks SHALL append through O_APPEND and use close-on-exec descriptors, preserving existing contents across late old-run and new-run writes without reopening the current pathname for old events. New log files SHALL use mode 0600 subject to the process umask. This ownership SHALL prevent deterministic teardown-induced loss of late records while retaining best-effort behavior for I/O errors and process termination; it SHALL NOT guarantee durable storage or peer receipt.

#### Scenario: Normal production file logger records the handoff
- **WHEN** an in-process production Server using a writable owned log file completes daemon.shutdown and the process remains alive
- **THEN** the captured writer SHALL remain usable for its candidate and hook_returned records after Run teardown returns
- **AND** the socket and PID cleanup SHALL not wait for those writes

#### Scenario: An old writer appends after a replacement Run
- **WHEN** a captured old writer is delayed across stop/start while the replacement Run writes to the same log path
- **THEN** releasing the old writer SHALL append its old-token records without overwriting the new-token records
- **AND** releasing the final captured writer SHALL close the old sink

#### Scenario: Rotation preserves the old sink identity
- **WHEN** the old log path is renamed and replaced while an old writer remains captured
- **THEN** its late records SHALL target its original descriptor rather than the replacement path
