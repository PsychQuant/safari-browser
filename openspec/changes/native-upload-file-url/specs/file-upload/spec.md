## MODIFIED Requirements

### Requirement: Upload file via file dialog

The system SHALL use the native macOS file dialog by default when Accessibility permission is granted, and SHALL retain the JS DataTransfer fallback without that grant. Native upload SHALL place one caller-specified file URL on the pasteboard and use named AX Paste and, when the owned sheet remains open, named initial Upload/Open confirmation. It SHALL NOT dispatch keyboard or mouse events or open Go-to-Folder. The --js, --native and --allow-hid flags SHALL preserve their routing and compatibility behavior; the JS size cap and navigation checks SHALL remain unchanged.

The native operation SHALL preserve a complete bounded snapshot of readable pasteboard items/types before changing it, refuse unreadable or oversized snapshots, restore on success/error/timeout while its changeCount still matches, and preserve observed newer content. It SHALL warn on retained newer content or restoration failure. It SHALL NOT promise restoration after forced process termination or atomicity against other processes.

The native operation SHALL capture the intended window ID, document nonce/URL and input identity before opening a chooser in the same bounded script. It SHALL refuse pre-existing sheets, changed ownership, lost focus, changed pasteboard ownership, unexpected nested sheets, ambiguous/disabled confirmation, or timeout without a keyboard fallback or replay. Success SHALL require evidence of a new input change for this operation and sheet completion and one actual File matching the caller file's normalized name, size and modification time within 1 ms.

#### Scenario: Hidden and special paths
- **WHEN** native upload receives a hidden file with Chinese characters, spaces or quotes in its path from an unrelated chooser directory
- **THEN** it SHALL use file URL Paste and named confirmation without HID and verify the actual selected file metadata

#### Scenario: Error or newer clipboard contents
- **WHEN** the native script fails or times out
- **THEN** the captured clipboard SHALL be restored if still owned, and observed newer contents SHALL be retained

#### Scenario: Wrong selection or changed page
- **WHEN** the sheet disappears but the input or selected File does not match the captured target
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
