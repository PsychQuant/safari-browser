## MODIFIED Requirements

### Requirement: Upload file via file dialog

The system SHALL use the native macOS file dialog by default when Accessibility permission is granted. When Accessibility permission is NOT granted, the system SHALL automatically fall back to JS DataTransfer injection with a stderr warning.

The native file dialog path SHALL:
1. Use clipboard paste (`Cmd+V`) instead of `keystroke` for path input
2. Save and restore the user's clipboard content before and after the paste
3. Use `repeat until exists` polling instead of fixed `delay` for all dialog state transitions
4. Use `AXDefault` button attribute to click the confirm button (locale-independent), with `keystroke return` as fallback

The `--js` flag SHALL force JS DataTransfer regardless of permission state. The `--native` and `--allow-hid` flags SHALL be kept for backward compatibility.

When using the `--js` path, the system SHALL check `window.location.href` every 10 chunks (not every chunk) to detect page navigation, comparing only the portion before the `#` fragment. On navigation detection, the system SHALL clean up `window.__sbUpload` before aborting.

#### Scenario: Upload with Accessibility permission

- **WHEN** user runs `safari-browser upload "input[type=file]" "/path/to/file"` and Accessibility permission is granted
- **THEN** the system uses native file dialog with clipboard path input, completing in under 2 seconds of keyboard control

#### Scenario: Upload without Accessibility permission

- **WHEN** user runs `safari-browser upload "input[type=file]" "/path/to/file"` and Accessibility permission is NOT granted
- **THEN** the system falls back to JS DataTransfer with a stderr message indicating how to enable native upload via System Settings

#### Scenario: Clipboard preserved during upload

- **WHEN** user has text "important data" in clipboard and runs upload
- **THEN** after upload completes, the clipboard contains "important data" (restored)

#### Scenario: JS upload detects navigation

- **WHEN** user runs `safari-browser upload --js "input" "/path"` and navigates away during chunking
- **THEN** the system cleans up `window.__sbUpload` and aborts with error message showing old and new URLs (ignoring fragment differences)
