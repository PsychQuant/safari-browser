## ADDED Requirements

### Requirement: Invocation-owned JavaScript result transfer

The CLI `js` result paths and the shared large-result bridge SHALL associate result state, errors and transfer frames with a fresh identity for each invocation. They SHALL NOT accept another invocation's result or an earlier invocation's transfer frame. State SHALL be prepared before execution, marked running before user code starts, and marked completed or failed after evaluation. The CLI SHALL publish an output file only after receiving and validating the complete result.

#### Scenario: Interleaved same-length result
- **GIVEN** invocation A evaluates `'new-batch'` and invocation B evaluates `'old-batch'` in the same page
- **WHEN** B stores its result between A's store and read operations
- **THEN** A SHALL return `new-batch` or an explicit transfer error
- **AND** A SHALL NOT successfully publish `old-batch`

#### Scenario: Stale response frame
- **WHEN** a read for invocation B receives a frame carrying invocation A's identity
- **THEN** the operation SHALL fail without publishing that frame's payload

#### Scenario: Missing or truncated chunk
- **GIVEN** an existing output file containing `keep-me`
- **WHEN** a required chunk is absent or its payload length disagrees with its declared range
- **THEN** the command SHALL fail and leave the file containing `keep-me`

#### Scenario: Unicode across a chunk boundary
- **WHEN** a result includes `A😀B` with a proposed chunk boundary between the emoji's UTF-16 surrogate units
- **THEN** the reader SHALL preserve `A😀B` without splitting the surrogate pair across transported chunks

#### Scenario: Payload contains framing punctuation and newlines
- **WHEN** the result is `:start:\nend:\n`
- **THEN** stdout or the output file SHALL contain exactly that result apart from the CLI's existing print newline behavior
- **AND** protocol prefixes and suffixes SHALL NOT appear in the published result

#### Scenario: Empty completed result
- **WHEN** user code evaluates to the empty string and completion state declares length zero
- **THEN** the operation SHALL succeed with an empty result without rerunning user code

#### Scenario: Statement fallback only before execution
- **WHEN** `var x = 2; return x + 3` cannot parse as an expression and the same prepared state remains present
- **THEN** the CLI SHALL evaluate it as a function body and return `5`

#### Scenario: Runtime error after a side effect
- **WHEN** user code increments a page counter once and then throws an error
- **THEN** the CLI SHALL report a JavaScript error and SHALL NOT increment the counter a second time

#### Scenario: Page state lost after execution
- **WHEN** the invocation state disappears after user code starts, including a same-URL page replacement
- **THEN** the CLI SHALL NOT retry the user code as another form
- **AND** it SHALL report unavailable result state unless an actual changed URL establishes the existing navigation-success outcome

#### Scenario: Large fallback reads the captured value
- **WHEN** the ordinary result read returns empty because its completed payload exceeds the transport limit
- **THEN** the CLI SHALL read chunks from the same captured value without evaluating the user code again

#### Scenario: Cleanup cannot erase another call
- **WHEN** invocation A finishes or fails while invocation B still owns page state
- **THEN** cleanup for A SHALL only address A's unique property

#### Scenario: Existing shared bridge callers
- **WHEN** GetText, GetHTML or SnapshotCommand reads a large result through the shared bridge
- **THEN** the result SHALL use the same invocation ownership and complete-transfer checks
- **AND** GetText and GetHTML SHALL NOT stage results through a shared `window.__sbResult` property

#### Scenario: Preparation failure during an unrelated navigation
- **WHEN** initialization returns a stale identity before user code is dispatched and the page URL changes
- **THEN** the command SHALL fail rather than claim that user code executed successfully

#### Scenario: Contradictory execution evidence
- **WHEN** a current executed receipt is followed by prepared metadata
- **THEN** the CLI SHALL reject the inconsistent response without dispatching a second form

#### Scenario: Cooperative cancellation at protocol boundaries
- **WHEN** the task is cancelled during preparation, execution, frame read, or cleanup
- **THEN** the session SHALL throw cancellation instead of returning a publishable result
- **AND** cancellation observed after preparation SHALL prevent dispatch of user code
- **AND** cleanup SHALL only attempt removal of this invocation's state

#### Scenario: Unpaired UTF-16 result
- **WHEN** user code returns a string containing an unpaired high surrogate U+D800
- **THEN** the operation SHALL fail with an explicit UTF-16 lossless-transfer diagnostic rather than substitute U+FFFD

#### Scenario: Runtime error followed by page replacement
- **WHEN** the evaluation receipt reports error and navigation removes the error detail before readback
- **THEN** the CLI SHALL report failure rather than successful navigation
- **AND** it SHALL NOT evaluate the user code again
