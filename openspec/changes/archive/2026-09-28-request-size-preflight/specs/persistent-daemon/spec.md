## ADDED Requirements

### Requirement: Daemon advertises an optional request line limit
The daemon SHALL include protocol.maxRequestLineBytes in its existing v2 handshake, as a canonical positive decimal ASCII string equal to the active instance request-line reader limit. The value SHALL count the complete encoded JSON line excluding its LF delimiter. This field SHALL describe a transport limit, not caller authorization, and SHALL NOT add a handshake round trip.

#### Scenario: Configured server limit
- **WHEN** an instance with a 1024-byte reader limit accepts a connection
- **THEN** its handshake SHALL declare maxRequestLineBytes equal to "1024"
- **AND** the version-only legacy decoder SHALL still decode the same version

#### Scenario: Production default
- **WHEN** the daemon uses its default request-line limit
- **THEN** it SHALL advertise "134217728" bytes

### Requirement: Client validates request limit advertisements
The client SHALL decode the version and optional limit from one typed handshake interpretation. An absent limit SHALL represent a legacy peer. A present limit SHALL be a string matching [1-9][0-9]* whose value fits the platform Int range. Null, booleans, JSON numbers, empty strings, signs, whitespace, leading zeros, fractions, exponents, non-ASCII digits and overflow SHALL invalidate the handshake. Unknown additional fields SHALL remain ignorable.

#### Scenario: Invalid limit is rejected before transmission
- **WHEN** the handshake includes maxRequestLineBytes as null, true, 1024, 1.5, "0", "-1", "01", "1.0", "1e3" or an out-of-range decimal string
- **THEN** the client SHALL send zero request bytes on that connection and report the existing invalid-handshake protocol error

#### Scenario: Large integer precision is preserved
- **WHEN** maxRequestLineBytes is "9007199254740993"
- **THEN** the decoded limit SHALL equal exactly 9007199254740993 without floating-point rounding

### Requirement: Client rejects known oversize requests before transmission
After successful handshake and version validation, the client SHALL compare the full serialized request envelope byte count excluding LF with the advertised limit before writing any bytes for that RPC. A greater count SHALL produce a dedicated local request-too-large error containing only counts and fixed guidance to reduce the request. The error SHALL state that no request bytes were sent for that RPC, SHALL NOT claim earlier command steps did not execute, and SHALL NOT authorize stateless fallback.

#### Scenario: Exact boundary is accepted
- **WHEN** the encoded method, params and requestId envelope contains exactly 1024 bytes and the peer limit is 1024
- **THEN** the client SHALL send the request plus LF and the server SHALL dispatch its handler once

#### Scenario: Encoded overhead exceeds the boundary
- **WHEN** JSON escaping, UTF-8 bytes or envelope overhead makes the serialized line greater than the declared limit
- **THEN** the peer SHALL receive zero request bytes, its handler SHALL not execute and the router SHALL not invoke stateless fallback
- **AND** the diagnostic SHALL NOT include request source, URL, path or requestId

### Requirement: Legacy request and post-send semantics remain compatible
A client SHALL preserve existing request behavior when the peer omits the optional limit and SHALL NOT infer a limit from matching version metadata. The server SHALL independently enforce its reader limit. A failure after partial or complete request transmission SHALL preserve requestOutcomeUnknown and SHALL NOT authorize replay.

#### Scenario: Legacy peer omits the limit
- **WHEN** a valid same-version handshake omits maxRequestLineBytes
- **THEN** the client SHALL transmit a request that exceeds a limit known only to a newer server implementation
- **AND** no new local request-limit rejection SHALL occur

#### Scenario: Legacy or inaccurate peer rejects a transmitted request
- **WHEN** a peer without an accurate limit declaration rejects the request after the client sends request bytes
- **THEN** the client SHALL report an unknown request outcome and the router SHALL not replay the request through stateless execution
