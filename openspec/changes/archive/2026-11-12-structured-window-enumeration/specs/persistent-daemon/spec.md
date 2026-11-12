## ADDED Requirements

### Requirement: Daemon announces its capabilities in the handshake

The daemon SHALL list the features a client can depend on in an optional `capabilities` array of strings inside the `protocol` object of its existing v2 handshake. A daemon of this change SHALL list `"sourceForm"`: its `applescript.execute` accepts `resultForm: "sourceForm"`, and its `exec.runScript` enumerates windows as a structured list. A handshake without the field SHALL mean that the daemon announces nothing. A present field that is not an array of strings SHALL invalidate the handshake. Unknown entries SHALL be ignored. The field SHALL NOT add a handshake round trip, and the version-only legacy decoder SHALL still decode a handshake that carries it. The list announces daemon features; it is not caller authentication, it authorizes nothing, and it is not the caller-identity "capability handshake" that the requirement "IPC trust model — filesystem permissions only" rules out.

#### Scenario: A current daemon announces source form

- **WHEN** a daemon of this change accepts a connection
- **THEN** its handshake's `protocol.capabilities` contains `"sourceForm"`
- **AND** the version-only legacy decoder decodes the same version

#### Scenario: An invalid capabilities field

- **WHEN** the handshake carries `capabilities` as a string, a boolean, null or an array holding a number
- **THEN** the client sends no request bytes on that connection and reports the invalid-handshake protocol error

### Requirement: Client requires a capability before sending a request that needs it

The client SHALL check, after the version check and before writing any request byte, that the daemon announced every capability the request needs: `"sourceForm"` for an `applescript.execute` request that carries `resultForm: "sourceForm"`, and for every `exec.runScript` request. The check SHALL come before the request-size check of "Client rejects known oversize requests before transmission": against a daemon without the capability, an oversize `exec` script runs step by step instead of failing with `requestTooLarge`. Without the capability the client SHALL raise a pre-send error whose fallback line says that the running daemon predates the feature and to run `safari-browser daemon stop` and then `safari-browser daemon start` (nothing starts a daemon on its own); the router SHALL print that line and run the request on the stateless path, and `exec` SHALL run the script step by step. Each step then runs as its own command, which checks the capability again for its own requests, so an `exec` script prints one line for the withheld `exec.runScript` and one more for each step that enumerates windows, plus one when `exec --window N --profile P` resolves the window in the parent before routing (`pinWindowAtStart`). This covers every daemon from before this change that passes the version check: unstamped builds (#320), and installed releases from before #304, which announce the same unstamped identity. The client SHALL NOT rerun a request after it was sent: an empty answer from a daemon that announced the capability SHALL be returned as it is.

#### Scenario: A daemon from before this change is not asked

- **WHEN** daemon mode is on and the daemon's handshake has no `capabilities` field
- **THEN** a source form request sends zero request bytes to it, and so does the `exec.runScript` request of an `exec` script
- **AND** each withheld request prints one `[daemon fallback: …]` line naming `safari-browser daemon stop` and `safari-browser daemon start`
- **AND** the source form request runs with `osascript -s s`, and the `exec` script runs step by step; each step is its own command, which sends its own requests and prints its own line when it enumerates windows

#### Scenario: an oversize exec script and a daemon without the capability

- **WHEN** the daemon announces a request-line limit smaller than an `exec` script's request but does not announce `"sourceForm"`
- **THEN** the client raises the missing-capability error first, prints its fallback line, and runs the script step by step, instead of failing with `requestTooLarge`

#### Scenario: A daemon that announced the capability answers with nothing

- **WHEN** a daemon whose handshake lists `"sourceForm"` answers the enumeration with an empty output
- **THEN** no fallback line is printed and the enumeration fails with `windowEnumerationCorrupt`
