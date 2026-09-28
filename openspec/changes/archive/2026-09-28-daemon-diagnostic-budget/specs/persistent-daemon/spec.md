## ADDED Requirements

### Requirement: Bounded daemon diagnostic events

Each Instance logging session SHALL share one diagnostic token bucket with capacity 8 and refill rate 2 tokens per second of monotonic elapsed time. Every admitted diagnostic line, including suppression summaries, SHALL consume one token at admission. The bound SHALL apply to admission, not to downstream writer or disk flush timing. Ordinary events SHALL leave at least one token reserved for terminal evidence; terminal events and summaries containing terminal evidence SHALL consume that reserved token when needed. No event SHALL bypass the bucket. Incident recovery, quiet gaps, and stop/start SHALL NOT reset the bucket. An explicit writer replacement SHALL begin a new logging session.

#### Scenario: Alternating failures cannot replenish the burst

- **WHEN** 100 ordinary diagnostic candidates alternate between failures and recovery at one clock instant
- **THEN** only the first 7 lines are emitted and 93 candidates are retained in suppression accounting
- **AND** a following terminal candidate consumes the reserved token and carries the pending suppression summary

#### Scenario: Monotonic refill and clock regression

- **WHEN** ordinary events exhaust their available burst and 500 ms elapses
- **THEN** one further ordinary line can be emitted while preserving the terminal reserve
- **WHEN** the injected clock moves backwards
- **THEN** no additional credit is granted

### Requirement: Bounded and private suppression summaries

Suppression SHALL retain a saturating total and counters for a fixed set of seven event kinds: accept_error, accept_wait_error, accept_recovered, connection_setup_failed, connection_setup_recovered, request_too_long, and request_read_failed. It SHALL also retain saturating counts for the five fixed dispositions retry, backoff, stop, closed, and recovered, so an intervening backoff does not disappear when later recovery evidence replaces it. It SHALL retain the first suppressed candidate and the latest suppressed recovery and terminal evidence. Evidence SHALL contain only fixed event and disposition values plus integer errno and count. Suppressed counts SHALL count eligible log candidates, not underlying syscall failures. No payload, URL, requestId, source, or request prefix SHALL enter diagnostic records, including when full request logging is enabled.

#### Scenario: Summary without new clients

- **WHEN** suppressed candidates remain while logging stays enabled and the writer is available
- **THEN** a single periodic flusher attempts an aggregate diagnostics_suppressed line every 500 ms until credit allows emission
- **AND** the aggregate consumes the same bucket and carries the withheld counts and retained evidence

#### Scenario: Aggregate alongside a later event

- **WHEN** a new candidate is admitted after suppression
- **THEN** its single JSON line includes the pending suppressed object and the pending state is cleared
- **AND** concurrent preparation cannot emit the same withheld counters twice

### Requirement: Diagnostic logging preserves daemon lifecycle behavior

Diagnostic state preparation SHALL run on the Instance actor, and writer invocation SHALL run outside that actor. Stop SHALL NOT wait for refill, flusher completion, or a diagnostic writer. Stop and writer disablement SHALL invalidate stale timers and discard unsent pending summaries; the daemon SHALL NOT claim durable delivery for those summaries. Already prepared emissions SHALL retain their original writer and SHALL NOT be redirected to a replacement writer. At most one flusher task SHALL remain owned by an Instance at a time, including while its writer is blocked; restarting or replacing a writer SHALL NOT create another flusher before the existing one completes.

A failed scheduling source SHALL end that flush attempt without self-rescheduling in the same logging generation. A later diagnostic candidate or replacement logging session SHALL permit a fresh attempt.

#### Scenario: Failed scheduler does not spin

- **WHEN** the scheduling source throws while a summary remains pending
- **THEN** that attempt ends without an automatic retry loop, the pending state remains bounded, and RPC behavior is unchanged

#### Scenario: Stop while a writer is blocked

- **WHEN** an admitted diagnostic writer is blocked
- **THEN** Instance.stop completes its existing cancellation and socket cleanup without awaiting that writer
- **AND** no stale timer delivers old suppressed state to a subsequently installed writer

#### Scenario: Logger disabled with pending suppression

- **WHEN** the writer is disabled before a summary is admitted
- **THEN** no later timer emission is prepared for that pending summary and no suppression state leaks into a new logging session

### Requirement: Private request rejection diagnostics

Oversized request lines and non-EINTR read failures SHALL produce eligible fixed diagnostic candidates using the shared bucket. The server SHALL close the rejected client connection and release its request buffer before diagnostic writer invocation. Diagnostics SHALL NOT parse the rejected frame or alter dispatch, client responses, or post-send no-replay classification. Normal EOF SHALL NOT be reported as a read failure.

#### Scenario: Rejection under diagnostic backpressure

- **WHEN** a client exceeds the request line limit while the diagnostic writer is blocked or its budget is exhausted
- **THEN** the client connection closes without dispatch or replay and the diagnostic candidate contains no request prefix
- **AND** another valid client retains the existing RPC result behavior
