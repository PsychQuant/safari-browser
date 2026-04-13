# screenshot Specification

## Purpose

TBD - created by archiving change 'phase2-advanced-features'. Update Purpose after archive.

## Requirements

### Requirement: Take window screenshot

The system SHALL capture the Safari front window using `screencapture -l <windowID>` and save it to the specified path (default: `screenshot.png`).

#### Scenario: Screenshot with default path

- **WHEN** user runs `safari-browser screenshot`
- **THEN** a PNG file is saved to `screenshot.png` in the current directory

#### Scenario: Screenshot with custom path

- **WHEN** user runs `safari-browser screenshot /tmp/page.png`
- **THEN** a PNG file is saved to `/tmp/page.png`

---
### Requirement: Take full page screenshot

The system SHALL capture the full scrollable page content when `--full` flag is provided. This is achieved by using JavaScript to get the full page dimensions, resizing the window temporarily, capturing, then restoring.

#### Scenario: Full page screenshot

- **WHEN** user runs `safari-browser screenshot --full /tmp/full.png`
- **THEN** a PNG capturing the entire scrollable page is saved to `/tmp/full.png`

---
### Requirement: Screenshot command accepts full TargetOptions

The `screenshot` command SHALL accept `--url <pattern>`, `--window <n>`, `--tab <n>`, and `--document <n>` targeting flags. When targeting flags are supplied, the system SHALL resolve the target to a physical window index via the native path resolver. The subsequent capture behavior depends on whether the system has Accessibility permission, per the Hidden window capture requirement below.

The `screenshot` command SHALL NOT reject `--url`, `--tab`, or `--document` at validation time.

#### Scenario: screenshot --url resolves target window

- **WHEN** Safari has two windows, one showing `https://web.plaud.ai/`
- **AND** user runs `safari-browser screenshot --url plaud /tmp/plaud.png`
- **THEN** the system SHALL resolve `--url plaud` to the plaud window index
- **AND** SHALL capture that window's content
- **AND** SHALL save the PNG to `/tmp/plaud.png`

#### Scenario: screenshot --document maps to owning window

- **WHEN** Safari has three documents across two windows
- **AND** user runs `safari-browser screenshot --document 3 /tmp/third.png`
- **THEN** the system SHALL identify which window owns the third document
- **AND** SHALL capture that window's content

---
### Requirement: Hidden window capture via Accessibility bounds does not raise

When the system has Accessibility permission (`AXIsProcessTrusted()` returns true) and the user supplies a targeting flag that resolves to a window that is not currently frontmost, the screenshot command SHALL capture that window using the Accessibility bounds path (`_AXUIElementGetWindow` + `kAXPositionAttribute` + `kAXSizeAttribute` + `screencapture -R`) WITHOUT raising the window to the front. This SHALL apply to background windows, minimized windows, and windows on non-active Spaces.

When Accessibility permission is NOT granted, the screenshot command SHALL fall back to the legacy `screencapture -l <windowID>` path, which requires the window to be visible. In that case, the command SHALL emit a stderr warning indicating that enabling Accessibility permission would allow hidden-window capture.

#### Scenario: Screenshot captures background window without raising

- **WHEN** Safari has two windows, window 1 (focused) showing `https://github.com/` and window 2 (background) showing `https://web.plaud.ai/`
- **AND** Accessibility permission is granted
- **AND** user runs `safari-browser screenshot --url plaud /tmp/plaud.png`
- **THEN** the system SHALL capture window 2's content into `/tmp/plaud.png`
- **AND** window 1 SHALL remain the frontmost window
- **AND** window 2 SHALL NOT be raised or brought to the active Space

#### Scenario: Screenshot without Accessibility falls back with warning

- **WHEN** Accessibility permission is NOT granted
- **AND** user runs `safari-browser screenshot --url plaud /tmp/plaud.png` while the plaud window is a background window
- **THEN** the system SHALL emit a stderr warning describing how to enable Accessibility permission
- **AND** SHALL attempt the legacy `screencapture -l` path against the resolved window ID
