## ADDED Requirements

### Requirement: Permanent listener failure terminates its owning run

An accept or poll error classified as permanently invalid by the existing accept disposition policy SHALL end that listener generation without retry or automatic replacement. The listener owner SHALL close its listener and wake-read descriptors before failure delivery. Notification SHALL carry only a typed operation (accept or poll) and integer errno. A blocked diagnostic writer SHALL NOT delay failure delivery. Wake, cancellation, and recoverable errors SHALL NOT be reported as permanent listener failure.

#### Scenario: Permanent accept or poll error

- **WHEN** a running listener receives an injected EBADF from accept or EINVAL from poll
- **THEN** it stops using that listener, closes its descriptors, and notifies the owning generation with the matching operation and errno
- **AND** it does not restart the listener or replay any request

#### Scenario: Normal cancellation while a callback is delayed

- **WHEN** a listener generation has been stopped and a previous failure callback is delivered later
- **THEN** the callback cannot stop or clean resources of a newer generation

### Requirement: Daemon run cleanup is generation owned

The outer Server SHALL bind startup, shutdown hooks, listener notifications, watchdog decisions, resource handles, and stop waiters to a Run identity. Concurrent starts SHALL share the same startup operation. A new start during teardown SHALL wait for that teardown before binding paths. Concurrent stops SHALL share one cleanup operation. Startup failures and listener failures SHALL clean the owning run without waiting for its accept loop or diagnostic writer. PID cleanup SHALL remove only an entry whose captured device/inode still matches; replaced or unconfirmed entries SHALL be retained.

#### Scenario: Failure before startup completes

- **WHEN** a listener fails before the startup operation returns
- **THEN** startup does not later restore running state, the owning pid and socket are cleaned, and the failure remains observable

#### Scenario: Concurrent stop and restart

- **WHEN** two stop callers and a subsequent start overlap
- **THEN** both stop callers await the same old cleanup, and the new run binds its paths only after that cleanup finishes
- **AND** delayed old listener, shutdown, or watchdog callbacks cannot stop the new run

#### Scenario: PID entry replaced before old cleanup

- **WHEN** the recorded pid entry is replaced after its identity was captured
- **THEN** cleanup retains the replacement rather than unlinking by path alone

### Requirement: Stop completion preserves a typed reason

Stop completion SHALL distinguish requested stop, idle timeout, startup failure, and permanent listener failure. Every waiter registered to a run SHALL receive that run's first accepted stop reason after cleanup. A later run SHALL NOT change an earlier waiter's result. The daemon __serve command SHALL exit nonzero with a fixed operation/errno diagnostic after permanent listener failure; ordinary stop and idle timeout SHALL keep normal exit behavior.

#### Scenario: Multiple stop waiters

- **WHEN** multiple callers wait for a run that ends with a listener failure
- **THEN** all receive the same typed listener failure after its cleanup

#### Scenario: Normal and failure process outcomes

- **WHEN** __serve completes after a requested or idle stop
- **THEN** it completes normally
- **WHEN** __serve completes after permanent listener failure
- **THEN** it reports only the listener operation and errno and exits nonzero
