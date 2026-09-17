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
