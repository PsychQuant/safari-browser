## ADDED Requirements

### Requirement: Daemon process is passively interfering and user-terminable

When the user opts into daemon mode, the resulting long-running `safari-browser` daemon process SHALL be classified as "passively interfering" — the daemon MUST NOT control HID input, MUST NOT open system dialogs, MUST NOT emit sounds, and MUST NOT steal window focus. The user MUST be able to terminate the daemon at any time through at least two mechanisms: (a) running `safari-browser daemon stop`, and (b) waiting out the idle timeout defined in the `persistent-daemon` capability.

#### Scenario: Daemon does not steal focus on startup

- **WHEN** the user runs `safari-browser daemon start` from a Terminal while working in another application
- **THEN** no window or dialog comes to the foreground and the user's current application retains focus

#### Scenario: Explicit stop terminates daemon immediately

- **WHEN** the user runs `safari-browser daemon stop` while a daemon is running
- **THEN** the daemon process exits within 5 seconds, removes its socket and pid files, and further CLI invocations without `--daemon` behave identically to pre-daemon state

#### Scenario: Idle timeout terminates daemon without user action

- **WHEN** no request reaches the daemon for the configured idle timeout duration
- **THEN** the daemon exits on its own, restoring the non-interference default state automatically

---

### Requirement: Daemon mode does not lower the default non-interference guarantees

Enabling daemon mode MUST NOT cause any individual command to perform a more interfering action than the same command would perform in stateless mode. Specifically, daemon mode MUST NOT: cache stale window state that causes the daemon to raise a window the user has since backgrounded, skip the spatial-gradient layering defined in the `human-emulation` capability, or perform any pre-emptive tab activation in the absence of an explicit command.

#### Scenario: Daemon respects Layer 1 noop

- **WHEN** daemon mode is enabled and a command targets the tab that is already the front tab of the front window
- **THEN** the daemon performs the same noop as the stateless path — no `activate window` AppleScript is issued
