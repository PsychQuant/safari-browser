## ADDED Requirements

### Requirement: Embedded shutdown isolation
Embedded Instance and Server SHALL NOT terminate their host process on daemon.shutdown. The production __serve entry SHALL retain a five-second forced-exit watchdog independent of graceful teardown.
#### Scenario: Embedded shutdown survives
- **WHEN** an embedded server receives shutdown and the host continues beyond five seconds
- **THEN** the host SHALL remain alive and finish its test suite.
#### Scenario: Production watchdog
- **WHEN** production graceful shutdown stalls
- **THEN** the independent watchdog SHALL force process exit after five seconds.

### Requirement: Complete test evidence
The standard test runner SHALL require successful exit and a final XCTest suite completion summary with a positive test count. Exit zero with truncated output SHALL fail.
#### Scenario: Early process exit
- **WHEN** output contains started tests but no final suite completion
- **THEN** the runner SHALL return nonzero even if the child returned zero.

### Requirement: Request-local probe options
New exec clients SHALL send only disabled and debug booleans in dialogProbe. The server SHALL apply them to that request, including explicit false values. Missing dialogProbe SHALL preserve the legacy daemon-environment default; malformed present options SHALL fail before steps execute.
#### Scenario: Client overrides daemon
- **WHEN** the daemon started with disabled=true and the client sends disabled=false, debug=true
- **THEN** that request SHALL probe and emit debug diagnostics; the following legacy request SHALL still use the daemon default.

### Requirement: GUI session evidence
Dialog listing, dismissal and window capture SHALL distinguish locked/unavailable GUI sessions from no dialog/window. They SHALL refuse before AX actions and SHALL give actionable session guidance. The scoped probe SHALL remain unprobed in those sessions.
#### Scenario: Locked session
- **WHEN** the session dictionary reports screen locked despite AX permission
- **THEN** dialog and capture commands SHALL report locked session rather than no dialog or no Safari window; no button SHALL be pressed.
#### Scenario: Unavailable session
- **WHEN** no session dictionary is available
- **THEN** commands SHALL report inspection unavailable, preserving unknown status.
