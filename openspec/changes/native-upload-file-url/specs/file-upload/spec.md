## MODIFIED Requirements

### Requirement: Upload file via file dialog

The system SHALL use the native macOS file dialog by default when Accessibility permission is granted, and SHALL retain the JS DataTransfer fallback without that grant. Native upload SHALL place one caller-specified file URL on the pasteboard and use named AX Paste and, when the owned sheet remains open, named initial Upload/Open confirmation. It SHALL NOT dispatch keyboard or mouse events or open Go-to-Folder. The --js, --native and --allow-hid flags SHALL preserve their routing and compatibility behavior; the JS size cap and navigation checks SHALL remain unchanged.

The native operation SHALL preserve a complete bounded snapshot of readable pasteboard items/types before changing it, refuse unreadable or oversized snapshots, restore on success/error/timeout while its changeCount still matches, and preserve observed newer content. It SHALL warn on retained newer content or restoration failure. It SHALL NOT promise restoration after forced process termination or atomicity against other processes.

The native operation SHALL capture the intended window ID, document nonce/URL and input identity before opening a chooser in the same bounded script. Before delivery it SHALL refuse pre-existing sheets, changed ownership, lost focus, changed pasteboard ownership, unexpected nested sheets, ambiguous/disabled confirmation, or timeout without a keyboard fallback or replay. Success SHALL require evidence of a new input change for this operation and sheet completion and an event-time snapshot of one actual File matching the caller file's normalized name, size and modification time either within 1 ms of the expected millisecond value or exactly equal to that value truncated toward zero to whole seconds. It SHALL NOT accept an arbitrary one-second tolerance.

#### Scenario: Hidden and special paths
- **WHEN** native upload receives a hidden file with Chinese characters, spaces or quotes in its path from an unrelated chooser directory
- **THEN** it SHALL use file URL Paste and named confirmation without HID and verify the actual selected file metadata

#### Scenario: Error or newer clipboard contents
- **WHEN** the native script fails or times out
- **THEN** the captured clipboard SHALL be restored if still owned, and observed newer contents SHALL be retained

#### Scenario: Wrong selection or changed page
- **WHEN** the sheet disappears but no trusted event-time snapshot matches the captured target
- **THEN** upload SHALL fail instead of reporting success or retrying confirmation

### Requirement: Upload command accepts full TargetOptions on all execution paths

The upload command SHALL accept --url, --window, --tab and --document on both JS and native execution paths. Native targeting SHALL resolve the existing concrete target, switch to its requested tab if required, and bind the ensuing AX operation to the captured window ID and page identity. It SHALL NOT reject targeting flags merely because --native or --allow-hid is present.

#### Scenario: Targeted native upload
- **WHEN** a unique target matches --url
- **THEN** only that target SHALL receive the file chooser and verified file selection

#### Scenario: Missing or ambiguous target
- **WHEN** target resolution is missing or ambiguous
- **THEN** the command SHALL preserve existing resolution errors and SHALL NOT modify the clipboard or open a chooser

## ADDED Requirements

### Requirement: Native upload does not mistake existing selection for completion
The command SHALL preserve the pre-existing input selection while opening the chooser. A cancelled chooser or unchanged pre-existing matching File SHALL NOT establish a new successful upload. An unobserved new change SHALL fail explicitly without clearing the input or retrying confirmation.

#### Scenario: Cancel with an already matching file
- **WHEN** the original input already contains matching metadata and the chooser is cancelled
- **THEN** the command SHALL fail for missing new-selection evidence and SHALL preserve the previous selection

### Requirement: Native file timestamp representation is verified with WebKit
The timestamp validator SHALL accept the exact millisecond representation and the measured whole-second truncation representation of a native WebKit File. Names, sizes and fresh-selection evidence SHALL remain required. Tests SHALL exercise real WebKit File objects through an owned public open-panel delegate without displaying a chooser; this SHALL NOT be treated as Safari AX acceptance.

#### Scenario: Native timestamp loses fractional seconds
- **WHEN** a file has modification time 1700000000627 ms and WebKit exposes 1700000000000 ms
- **THEN** metadata validation SHALL accept that exact whole-second representation
- **AND** it SHALL reject 1700000001000 ms and 1700000000100 ms for that expected time

#### Scenario: Pre-epoch native timestamp
- **WHEN** a file has modification time -1999 ms and WebKit exposes -1000 ms
- **THEN** validation SHALL use truncation toward zero and SHALL NOT construct invalid JavaScript by joining two minus signs

### Requirement: Native upload records delivery before page handlers consume the input
The command SHALL capture file count, name, size and modification time on the first trusted input or change event for the original input while its document, URL, selector and file-input mode still match. It SHALL retain the first such snapshot and SHALL NOT replace it with later events. After delivery, same-document URL updates, clearing the input or replacing it SHALL NOT invalidate that snapshot. Completion SHALL still require the captured window and tab, the original document state and a closed chooser; untrusted events or ownership changes before delivery SHALL NOT establish success.

#### Scenario: Application consumes the selected file immediately
- **WHEN** a page change handler clears or replaces the original input or updates its same-document URL after receiving the selected file
- **THEN** verification SHALL use the event-time metadata rather than the subsequent live FileList
- **AND** it SHALL NOT send another file action

#### Scenario: Input event precedes change
- **WHEN** the page consumes the file in its input handler before change fires
- **THEN** the earlier trusted input event SHALL preserve the delivery snapshot

#### Scenario: Delivered chooser remains briefly observable
- **WHEN** the original input has delivered matching file metadata and its sheet remains observable during closure
- **THEN** the command SHALL wait using only completion ownership checks and SHALL NOT send another confirmation
- **AND** success SHALL still require the sheet to disappear

### Requirement: Native upload rejects directory selectors
Native upload SHALL reject a webkitdirectory file input before opening a chooser and SHALL recheck its mode before further file actions. This command authorizes one regular file, not directory selection.

#### Scenario: Directory attribute is present or added before opening
- **WHEN** the selected input has webkitdirectory initially or gains it before click
- **THEN** the command SHALL refuse without opening that directory chooser

### Requirement: Native upload proves the selected path before confirmation

The native upload flow SHALL obtain bounded read-only native AX evidence for the exact requested regular-file path before dispatching its named initial confirmation. It SHALL bind the Safari CGWindowID, unique open-panel, explicit selected leaf and resolved file URL. It SHALL support the measured column, list and icon views, enforce time/node/depth/array limits, and reject missing, ambiguous, mismatched or unknown evidence without confirmation or HID fallback. Existing owner and clipboard checks SHALL surround evidence collection. Observed delivery SHALL enter a read-only completion phase without another confirmation.

#### Scenario: Selected file in a supported view
- **WHEN** a single explicitly selected leaf in ColumnView, ListView or IconView has a file-reference URL resolving to the requested hidden Unicode file
- **THEN** the flow SHALL permit at most one named confirmation after rechecking owner, deadline and clipboard

#### Scenario: Incomplete or conflicting selection evidence
- **WHEN** the AX traversal exceeds a bound, observes an unsupported view, multiple selections, a different file, or changed window/clipboard
- **THEN** the flow SHALL fail without dispatching confirmation

#### Scenario: Paste already delivered the file
- **WHEN** the trusted input/change snapshot records delivery before the named confirmation
- **THEN** the flow SHALL perform only read-only completion checks and SHALL NOT confirm again

### Requirement: Native upload worker accepts only a bound request

The internal worker SHALL accept a versioned bounded structured upload request, verify its parent executable and loaded image identity before UI access, and build only the fixed native upload script on the main thread. It SHALL NOT accept arbitrary script source. The parent SHALL retain clipboard ownership and enforce the existing subprocess watchdog and MCP process-group cancellation. Diagnostics and timing SHALL preserve the bounded stderr contract and existing element-not-found and timeout errors.

#### Scenario: Invalid internal request
- **WHEN** direct invocation, image mismatch, expired deadline or invalid request bounds are detected
- **THEN** the worker SHALL reject the request before clipboard mutation or Safari interaction

#### Scenario: Worker completes or fails
- **WHEN** the bounded worker finishes, fails or times out
- **THEN** the parent SHALL restore its owned clipboard or preserve newer contents and SHALL report the original operation outcome without replay

### Requirement: Native upload completion rejects page state forgery

After initialization with genuine browser intrinsics, direct changes to the page-visible transaction object, replacement of its global binding, or calls to exposed methods SHALL NOT produce an accepted completion receipt before a trusted matching delivery. The receipt SHALL be a fresh secret distinct from the discoverable state key, retained in a private closure and compared outside the page realm. Metadata observed through the captured native getters that differs from the expected metadata SHALL NOT release it. The receipt SHALL identify this observer's result, not an immutable event payload or byte identity. Earlier page capture listeners can replace the genuine FileList before observation; this case is outside the receipt's integrity guarantee. Query scripts and exposed function source SHALL NOT disclose it. Cleanup SHALL remove temporary state and listeners. This requirement SHALL NOT be interpreted as isolated-world execution against a page that replaced browser intrinsics before initialization.

#### Scenario: Forged state followed by cancellation
- **WHEN** page code changes or replaces the exposed state without a trusted matching delivery and the chooser is cancelled
- **THEN** the native flow SHALL reject the forged completion, including a plain OK response

#### Scenario: Correct delivery receipt
- **WHEN** the private listener receives a trusted delivery with the exact expected file metadata
- **THEN** its read function SHALL return the private receipt and the native flow SHALL accept only its exact match

#### Scenario: Wrong file or exposed method inspection
- **WHEN** the observer reads mismatched file metadata or page code inspects exposed function source
- **THEN** the private receipt SHALL remain unavailable

#### Scenario: Earlier capture listener replaces the genuine FileList
- **WHEN** a page capture listener registered earlier replaces the genuine FileList before the upload observer runs
- **THEN** the completion receipt SHALL represent the metadata visible to that observer and SHALL NOT be described as proof of the file bytes originally supplied by the browser
- **AND** native selected-path authorization SHALL remain independent of page receipt data

### Requirement: Native upload preserves requested target constraints

Native upload SHALL retain the original URL matcher and carried profile constraint across native resolution and the fixed worker request. Before treating the current page as its transaction owner or opening its chooser, the worker SHALL verify the original constraint against the bound window/tab candidate. A mismatch SHALL stop without chooser opening, Paste, confirmation, re-resolution or replay. Matcher semantics SHALL reuse UrlMatcher, and unconstrained positional targets SHALL retain existing behavior. The serialized constraint SHALL reject unknown fields and invalid combinations.

#### Scenario: Resolved slot changes to a nonmatching URL
- **WHEN** an exact URL target resolves to window 42 and tab 2, but that slot contains a different URL before worker capture
- **THEN** the worker SHALL reject the candidate before opening the input or sending a file action

#### Scenario: Carried matcher and profile
- **WHEN** a resolvedTab carries a matcher or profile constraint
- **THEN** the fixed worker request SHALL preserve and verify both present constraints using the existing matching semantics

#### Scenario: Positional request without an original matcher
- **WHEN** a native request has no original URL or profile constraint
- **THEN** it SHALL retain the existing window/tab capture and subsequent owner checks without adding a rematch policy

### Requirement: Native upload waits only on proven pending selection

The native selection reader SHALL distinguish MATCH, PENDING and UNAVAILABLE. PENDING SHALL require a supported native file view whose required bounded structure and selection-collection reads all succeed, at least one successful bounded selected-rows or selected-children collection read, and zero entries across those collections, followed by the existing owner and deadline checks. Missing or unreadable required attributes, selected groups without valid leaf evidence, different files, ambiguous selections, unsupported structure and exceeded bounds SHALL remain UNAVAILABLE and SHALL stop the transaction without confirmation. An explicitly empty readable selection SHALL NOT be treated as evidence of a selected file.

After Paste, the command SHALL inspect its completion receipt or selected path immediately without an unconditional settle delay. It SHALL wait only for a proven PENDING selection or for its existing PENDING completion receipt after the chooser disappears. Each observation SHALL preserve the original ownership, clipboard and monotonic deadline guards. Each wait SHALL request at most 100 ms and at most the original remaining time. The command SHALL NOT reset the deadline or repeat Paste, menu cancellation or confirmation while waiting. The immediate MATCH path SHALL reuse its first selected-path read and SHALL retain the second read before confirmation. Observed delivery SHALL enter the existing read-only completion phase.

#### Scenario: Immediate selected path or completed delivery
- **WHEN** the first post-Paste observation returns MATCH or a valid completed receipt
- **THEN** the command SHALL continue without a fixed settle sleep
- **AND** completed delivery SHALL NOT authorize another confirmation

#### Scenario: Empty readable selection becomes ready
- **WHEN** a supported view has an empty readable selection, later returns MATCH, and all ownership guards remain valid
- **THEN** the command SHALL perform bounded read-only rechecks using the original deadline and SHALL NOT repeat Paste

#### Scenario: Unknown evidence is not pending
- **WHEN** a selection read fails, exceeds a bound, encounters a selected group without a valid leaf, or observes a different or ambiguous file
- **THEN** the command SHALL fail without further waiting or confirmation rather than converting UNAVAILABLE to PENDING

#### Scenario: Deadline or ownership expires while pending
- **WHEN** pending persists until the original deadline or the window, page, foreground or clipboard ownership changes
- **THEN** the command SHALL stop without another file action
- **AND** completion SHALL remain unverified

#### Scenario: Selection changes before confirmation
- **WHEN** an earlier MATCH is followed by a nonmatching second selected-path read or a failed final ownership guard
- **THEN** the command SHALL refuse confirmation
