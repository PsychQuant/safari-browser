## MODIFIED Requirements

### Requirement: Silent fallback to stateless path on daemon failure

The client SHALL fall back to the stateless path with a single stderr warning prefixed `[daemon fallback: <reason>]` only when no complete request was transmitted, the handshake is incompatible, or the daemon rejects an unknown method before execution. Domain errors and handler errors SHALL propagate. After a complete request was transmitted, timeout, EOF, malformed response, or mismatched requestId SHALL report an unknown execution outcome and MUST NOT automatically retry.

#### Scenario: Dead daemon does not break CLI
- **WHEN** connection to a stale daemon socket is refused before request transmission
- **THEN** the client prints a fallback warning and executes the stateless path.

#### Scenario: Domain errors are not treated as daemon failures
- **WHEN** the daemon reports ambiguousWindowMatch
- **THEN** the client surfaces the error without retrying.

#### Scenario: Lost response after a side effect
- **WHEN** a complete request was sent and the connection closes without a complete correlated response
- **THEN** the client reports an unknown outcome and does not execute the operation again.

## ADDED Requirements

### Requirement: Absolute request deadline
The client SHALL bound connect, handshake, write, and full response read by one monotonic deadline. Ordinary bridge requests SHALL use a maximum of 15 seconds; exec requests SHALL use 60 seconds. Partial progress and EINTR MUST NOT extend the deadline. Invalid timeout values SHALL be rejected. Timeout SHALL NOT be reported as an empty response or successful truncated JSON.

#### Scenario: Trickle cannot keep a request alive
- **WHEN** a peer sends one byte every 30 ms under a 100 ms deadline
- **THEN** the client stops waiting at that deadline even though no individual read was idle for 100 ms.

### Requirement: Request diagnostics remain visible
A completed response SHALL include captured diagnostics when nonempty on both success and handler failure. The client SHALL validate correlation and forward diagnostics to stderr before returning the result or error. Each request SHALL have its own dialog state and diagnostic collector.

#### Scenario: Concurrent requests remain isolated
- **WHEN** two interleaved handlers discover different dialogs
- **THEN** each client receives only its own warning and the stdout result shape remains unchanged.

### Requirement: Cached scripts execute on the main thread
Creation, compilation, and execution of cached NSAppleScript instances SHALL occur on the main thread. Identical source SHALL continue to reuse its compiled handle.

#### Scenario: Repeated delay after arithmetic
- **WHEN** the daemon executes return 42 and then a 0.3 second delay repeatedly
- **THEN** each completes normally, and repeated identical sources do not increase the cache count.
