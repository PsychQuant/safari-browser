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

---
### Requirement: Crop Safari chrome with --content-only flag

The `screenshot` command SHALL accept a `--content-only` flag. When this flag is supplied, after capturing the Safari window, the system SHALL crop the output PNG so that only the Safari web content area (AXWebArea) is retained, excluding URL bar, tab bar, toolbar, and any other window chrome. The cropped PNG SHALL be written to the same output path the user specified.

The system SHALL locate the web content area by reading the `kAXWebAreaRole` child element of the resolved `AXUIElement` Safari window, recursively searching up to depth 3 and selecting the first matching element. The system SHALL read that element's `kAXPositionAttribute` and `kAXSizeAttribute` to obtain a screen-coordinate `CGRect` for the web content area.

When the AXWebArea cannot be located within depth 3, the system SHALL throw a `webAreaNotFound` error with guidance pointing the user to re-run without `--content-only`.

#### Scenario: Screenshot with --content-only crops chrome

- **WHEN** Safari has a window showing `https://example.com/` with a visible URL bar, tab bar, and toolbar
- **AND** Accessibility permission is granted
- **AND** the user runs `safari-browser screenshot /tmp/page.png --content-only`
- **THEN** the system SHALL capture the window
- **AND** SHALL crop the output to the AXWebArea rectangle
- **AND** SHALL write the cropped PNG to `/tmp/page.png`
- **AND** the output PNG SHALL NOT contain URL bar, tab bar, or toolbar pixels

#### Scenario: AXWebArea cannot be located

- **WHEN** the user runs `safari-browser screenshot /tmp/out.png --content-only` on a Safari window where the AXWebArea role is not reachable within depth 3 (e.g., private window with restricted AX tree, PDF preview tab)
- **THEN** the system SHALL throw `webAreaNotFound`
- **AND** the error message SHALL suggest re-running the command without `--content-only`


<!-- @trace
source: screenshot-content-only
updated: 2026-04-18
code:
  - Tests/SafariBrowserTests/ErrorsTests.swift
  - Tests/SafariBrowserTests/ImageCroppingTests.swift
  - Sources/SafariBrowser/Utilities/ImageCropping.swift
  - Sources/SafariBrowser/Utilities/Errors.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/ScreenshotCommand.swift
-->

---
### Requirement: --content-only requires Accessibility permission

When the user supplies `--content-only` and `AXIsProcessTrusted()` returns false, the system SHALL reject the command with an `accessibilityRequired` error before capturing. The error message SHALL describe that Accessibility permission is required for `--content-only`, the path to grant it (System Settings → Privacy & Security → Accessibility), and the alternative of re-running without `--content-only` to receive a chrome-included screenshot.

The system SHALL NOT fall back to a JavaScript-based viewport measurement path when Accessibility is missing. The system SHALL NOT emit a best-effort cropped PNG when the web content bounds cannot be measured via Accessibility APIs.

#### Scenario: --content-only without Accessibility is rejected

- **WHEN** `AXIsProcessTrusted()` returns false
- **AND** the user runs `safari-browser screenshot /tmp/out.png --content-only`
- **THEN** the system SHALL exit with `accessibilityRequired` error
- **AND** the error message SHALL include the path to grant Accessibility permission
- **AND** the error message SHALL mention the `--content-only`-free alternative
- **AND** the system SHALL NOT write any file to `/tmp/out.png`

#### Scenario: --content-only without AX does not fall back to JS viewport

- **WHEN** `AXIsProcessTrusted()` returns false
- **AND** the user runs `safari-browser screenshot /tmp/out.png --content-only`
- **THEN** the system SHALL NOT execute JavaScript to read `window.innerWidth` or `window.innerHeight`
- **AND** the system SHALL NOT write a chrome-stripped PNG based on a heuristic assumption


<!-- @trace
source: screenshot-content-only
updated: 2026-04-18
code:
  - Tests/SafariBrowserTests/ErrorsTests.swift
  - Tests/SafariBrowserTests/ImageCroppingTests.swift
  - Sources/SafariBrowser/Utilities/ImageCropping.swift
  - Sources/SafariBrowser/Utilities/Errors.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/ScreenshotCommand.swift
-->

---
### Requirement: --content-only combines with --full via resize-then-remeasure

When the user supplies both `--full` and `--content-only`, the system SHALL execute the existing `--full` resize-capture-restore flow and, after capturing the resized window, re-read the AXWebArea bounds on the resized window before cropping. The crop rectangle SHALL be computed from the post-resize AXWebArea bounds, not the pre-resize bounds.

The system SHALL restore the original window bounds after capture and crop, regardless of whether the crop step succeeded.

#### Scenario: --full --content-only crops chrome from scrollable capture

- **WHEN** Safari has a window showing a long scrollable page
- **AND** Accessibility permission is granted
- **AND** the user runs `safari-browser screenshot /tmp/long.png --full --content-only`
- **THEN** the system SHALL resize the window to the scrollable dimensions
- **AND** SHALL capture the resized window
- **AND** SHALL re-read the AXWebArea bounds on the resized window
- **AND** SHALL crop the captured PNG using the post-resize AXWebArea rectangle
- **AND** SHALL restore the original window bounds
- **AND** the output PNG SHALL NOT contain URL bar, tab bar, or toolbar pixels
- **AND** the output PNG SHALL contain the full scrollable content

#### Scenario: Window bounds restored even if crop fails

- **WHEN** the user runs `safari-browser screenshot /tmp/long.png --full --content-only`
- **AND** the crop step throws an error after capture succeeds
- **THEN** the system SHALL still restore the original window bounds
- **AND** SHALL propagate the crop error as the final command error


<!-- @trace
source: screenshot-content-only
updated: 2026-04-18
code:
  - Tests/SafariBrowserTests/ErrorsTests.swift
  - Tests/SafariBrowserTests/ImageCroppingTests.swift
  - Sources/SafariBrowser/Utilities/ImageCropping.swift
  - Sources/SafariBrowser/Utilities/Errors.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/ScreenshotCommand.swift
-->

---
### Requirement: --content-only skips crop when viewport matches window

The system SHALL detect the case where the AXWebArea bounds match the window bounds and skip the crop operation, writing the captured PNG unchanged. The system SHALL define "match" as: the AXWebArea width equals the window width exactly, AND the absolute difference between the window height and the AXWebArea height is less than 4 points.

The system SHALL NOT use percentage-based similarity thresholds for this detection.

#### Scenario: Fullscreen Safari with --content-only writes uncropped PNG

- **WHEN** Safari is in fullscreen mode with no visible chrome
- **AND** the AXWebArea bounds equal the window bounds within the tolerance
- **AND** the user runs `safari-browser screenshot /tmp/full.png --content-only`
- **THEN** the system SHALL NOT invoke the cropping logic
- **AND** SHALL write the captured PNG to `/tmp/full.png` as-is

#### Scenario: Reader Mode with --content-only writes uncropped PNG

- **WHEN** Safari is showing a page in Reader Mode, which hides most chrome
- **AND** the AXWebArea height is within 4 points of the window height
- **AND** the AXWebArea width equals the window width
- **AND** the user runs `safari-browser screenshot /tmp/reader.png --content-only`
- **THEN** the system SHALL skip the crop step
- **AND** SHALL write the captured PNG to `/tmp/reader.png` as-is


<!-- @trace
source: screenshot-content-only
updated: 2026-04-18
code:
  - Tests/SafariBrowserTests/ErrorsTests.swift
  - Tests/SafariBrowserTests/ImageCroppingTests.swift
  - Sources/SafariBrowser/Utilities/ImageCropping.swift
  - Sources/SafariBrowser/Utilities/Errors.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/ScreenshotCommand.swift
-->

---
### Requirement: HiDPI scale computed dynamically from captured image

When cropping, the system SHALL compute the points-to-pixels scale factor dynamically as `CGImage.width / windowBounds.width` (using the width in pixels of the captured PNG divided by the window width in points). The system SHALL multiply the viewport rectangle (in points) by this scale factor to obtain the crop rectangle in image-space pixels.

The system SHALL NOT use `NSScreen.backingScaleFactor` or any other static scale source for this calculation.

The system SHALL round the resulting crop rectangle to integer pixel coordinates using `CGRect.integral` before passing it to `CGImage.cropping(to:)`.

#### Scenario: Retina display window is cropped correctly

- **WHEN** Safari is on a retina display with `backingScaleFactor` = 2.0
- **AND** the window bounds are 1200 × 900 points
- **AND** the captured PNG is 2400 × 1800 pixels
- **AND** the AXWebArea is at (0, 100) points with size 1200 × 800 points
- **AND** the user runs `safari-browser screenshot /tmp/out.png --content-only`
- **THEN** the system SHALL compute scale = 2400 / 1200 = 2.0
- **AND** SHALL crop the captured PNG to the pixel rectangle (0, 200, 2400, 1600)

#### Scenario: Non-integer display scaling is cropped correctly

- **WHEN** Safari is on a display with macOS Display Scaling 1.5×
- **AND** the window bounds are 1600 × 1000 points
- **AND** the captured PNG is 2400 × 1500 pixels
- **AND** the AXWebArea is at (0, 130) points with size 1600 × 870 points
- **AND** the user runs `safari-browser screenshot /tmp/out.png --content-only`
- **THEN** the system SHALL compute scale = 2400 / 1600 = 1.5
- **AND** SHALL compute the unrounded crop rectangle (0, 195, 2400, 1305)
- **AND** SHALL round the crop rectangle to integer pixels via `CGRect.integral`
- **AND** SHALL crop the captured PNG to the integral rectangle

<!-- @trace
source: screenshot-content-only
updated: 2026-04-18
code:
  - Tests/SafariBrowserTests/ErrorsTests.swift
  - Tests/SafariBrowserTests/ImageCroppingTests.swift
  - Sources/SafariBrowser/Utilities/ImageCropping.swift
  - Sources/SafariBrowser/Utilities/Errors.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/ScreenshotCommand.swift
-->

---
### Requirement: Crop to element bounding box with --element flag

The `screenshot` command SHALL accept an `--element <selector>` option. When this option is supplied, after capturing the Safari window the system SHALL crop the output PNG to the bounding rectangle of the matched DOM element, excluding everything else in the window (Safari chrome and other page content).

The system SHALL resolve the element via `document.querySelectorAll(selector)` on the resolved target document (light DOM only; Shadow DOM is out of scope). The element's bounding rectangle SHALL be read via `getBoundingClientRect()`, which returns viewport-relative points. The system SHALL translate the viewport-relative rectangle to a window-relative rectangle by adding the AXWebArea origin (obtained via `getAXWebAreaBounds`) to the element's viewport-space origin, then pass the result to the existing `cropPNG` helper.

The `--element` option SHALL require Accessibility permission (for `getAXWebAreaBounds`). When `AXIsProcessTrusted()` returns false, the system SHALL throw `accessibilityRequired(flag: "--element")` before capturing.

#### Scenario: Screenshot with --element crops to element rectangle

- **WHEN** Safari has a window showing a page with `<div id="target">` at viewport coordinates (50, 100) with size 200×150 points
- **AND** Accessibility permission is granted
- **AND** the user runs `safari-browser screenshot /tmp/target.png --element "#target"`
- **THEN** the system SHALL capture the window
- **AND** SHALL translate the element's viewport rectangle to window-relative coordinates using the AXWebArea origin
- **AND** SHALL crop the output PNG to the element's window-relative rectangle
- **AND** the output PNG dimensions SHALL match the element's size (200×150 points) scaled by the HiDPI factor

#### Scenario: --element without Accessibility is rejected

- **WHEN** `AXIsProcessTrusted()` returns false
- **AND** the user runs `safari-browser screenshot /tmp/out.png --element "#target"`
- **THEN** the system SHALL exit with `accessibilityRequired(flag: "--element")` error
- **AND** the error's errorDescription SHALL include an alternative suggesting to re-run with `--window N` / `--url <pattern>` and crop externally
- **AND** the system SHALL NOT write any file to `/tmp/out.png`


<!-- @trace
source: screenshot-element-crop
updated: 2026-04-19
code:
  - Sources/SafariBrowser/Commands/ScreenshotCommand.swift
  - Tests/SafariBrowserTests/ElementCropTests.swift
  - Sources/SafariBrowser/Utilities/Errors.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Tests/SafariBrowserTests/ErrorsTests.swift
  - Tests/Fixtures/element-crop-test.html
-->

---
### Requirement: --element fails closed on no match, multi-match, zero-size, outside-viewport, and invalid selector

The system SHALL define six distinct fail-closed error paths for `--element`, each throwing a specific error case with a recovery hint:

1. When `querySelectorAll(selector).length == 0`, the system SHALL throw `elementNotFound(selector:)`.
2. When length > 1 AND `--element-index` is not supplied, the system SHALL throw `elementAmbiguous(selector:, matches:)` where `matches` contains, for each match in document order, the bounding rectangle, a compact attribute string (`tag.class#id`), and a text snippet (first 60 characters, whitespace-trimmed, or nil if no text content).
3. When `--element-index N` is supplied but N exceeds the match count OR N < 1, the system SHALL throw `elementIndexOutOfRange(selector:, index:, matchCount:)`.
4. When the selected element's `getBoundingClientRect()` returns width ≤ 0 OR height ≤ 0, the system SHALL throw `elementZeroSize(selector:)`.
5. When the selected element's rectangle extends beyond `window.innerWidth` or `window.innerHeight` (partially or fully outside the viewport), the system SHALL throw `elementOutsideViewport(selector:, rect:, viewport:)`. The system SHALL NOT automatically scroll the element into view.
6. When `querySelectorAll` raises a `SyntaxError` due to an invalid CSS selector, the system SHALL throw `elementSelectorInvalid(selector:, reason:)` where `reason` contains the JavaScript error message.

For each error path the system SHALL NOT write any file to the output path.

#### Scenario: --element with no match fails closed

- **WHEN** the user runs `safari-browser screenshot /tmp/out.png --element "#does-not-exist"`
- **AND** the selector matches no elements on the page
- **THEN** the system SHALL throw `elementNotFound(selector: "#does-not-exist")`
- **AND** SHALL NOT write any file to `/tmp/out.png`

#### Scenario: --element with multi-match and no index fails closed with rich error

- **WHEN** the user runs `safari-browser screenshot /tmp/out.png --element ".card"`
- **AND** the page contains 3 elements matching `.card`
- **THEN** the system SHALL throw `elementAmbiguous(selector: ".card", matches: [...])`
- **AND** the error's `matches` array SHALL contain 3 entries in document order
- **AND** each entry SHALL include the element's bounding rectangle, a `tag.class#id` attribute string, and a text snippet of up to 60 characters
- **AND** the errorDescription SHALL suggest both refining the selector and using `--element-index N`

#### Scenario: --element-index out of range fails closed

- **WHEN** the page contains 2 elements matching `.card`
- **AND** the user runs `safari-browser screenshot /tmp/out.png --element ".card" --element-index 3`
- **THEN** the system SHALL throw `elementIndexOutOfRange(selector: ".card", index: 3, matchCount: 2)`
- **AND** SHALL NOT write any file

#### Scenario: --element on hidden element fails closed

- **WHEN** the page contains `<div id="hidden" style="display:none;">`
- **AND** the user runs `safari-browser screenshot /tmp/out.png --element "#hidden"`
- **THEN** `getBoundingClientRect()` SHALL return width 0 and height 0
- **AND** the system SHALL throw `elementZeroSize(selector: "#hidden")`
- **AND** SHALL NOT write any file

#### Scenario: --element on element outside viewport fails closed

- **WHEN** the page contains an element positioned at (0, 5000) and the viewport height is 1080
- **AND** the user runs `safari-browser screenshot /tmp/out.png --element "#below-fold"`
- **THEN** the system SHALL throw `elementOutsideViewport(selector: "#below-fold", rect:, viewport:)`
- **AND** the system SHALL NOT scroll the page
- **AND** SHALL NOT write any file

#### Scenario: --element with invalid selector fails closed

- **WHEN** the user runs `safari-browser screenshot /tmp/out.png --element "div[unclosed-attr"`
- **AND** `querySelectorAll` raises a `SyntaxError`
- **THEN** the system SHALL throw `elementSelectorInvalid(selector:, reason:)` with `reason` containing the JavaScript error message
- **AND** SHALL NOT write any file


<!-- @trace
source: screenshot-element-crop
updated: 2026-04-19
code:
  - Sources/SafariBrowser/Commands/ScreenshotCommand.swift
  - Tests/SafariBrowserTests/ElementCropTests.swift
  - Sources/SafariBrowser/Utilities/Errors.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Tests/SafariBrowserTests/ErrorsTests.swift
  - Tests/Fixtures/element-crop-test.html
-->

---
### Requirement: --element-index disambiguates multi-match deterministically

The `screenshot` command SHALL accept an `--element-index <N>` option (1-indexed, positive integer). When both `--element` and `--element-index N` are supplied:

- If the selector matches at least N elements, the system SHALL select the Nth element in document order (the order returned by `querySelectorAll`) and proceed with the crop.
- If the match count is below N, the system SHALL throw `elementIndexOutOfRange` per the previous requirement.
- If the match count is exactly 1 AND N equals 1, the system SHALL accept this as a valid assertion (no error) and proceed.

The system SHALL reject `--element-index` when `--element` is not supplied, with a validation error at argument parsing time.

The system SHALL NOT support a silent first-match fallback. There is no `--first-match`-style flag for `--element` — the only disambiguation paths are refining the selector or supplying `--element-index`.

#### Scenario: --element-index picks the Nth match in document order

- **WHEN** the page contains 3 elements matching `.card` in document order at y=100, y=320, y=540
- **AND** the user runs `safari-browser screenshot /tmp/out.png --element ".card" --element-index 2`
- **THEN** the system SHALL select the element at y=320 (the 2nd match)
- **AND** SHALL crop the output PNG to that element's bounding rectangle

#### Scenario: --element-index 1 on unique match is accepted

- **WHEN** the page contains exactly 1 element matching `#target`
- **AND** the user runs `safari-browser screenshot /tmp/out.png --element "#target" --element-index 1`
- **THEN** the system SHALL accept the command
- **AND** SHALL crop the output PNG to the element's bounding rectangle

#### Scenario: --element-index without --element is rejected at validation

- **WHEN** the user runs `safari-browser screenshot /tmp/out.png --element-index 2`
- **AND** does NOT supply `--element`
- **THEN** the argument parser SHALL reject the command with a validation error
- **AND** SHALL NOT attempt a capture


<!-- @trace
source: screenshot-element-crop
updated: 2026-04-19
code:
  - Sources/SafariBrowser/Commands/ScreenshotCommand.swift
  - Tests/SafariBrowserTests/ElementCropTests.swift
  - Sources/SafariBrowser/Utilities/Errors.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Tests/SafariBrowserTests/ErrorsTests.swift
  - Tests/Fixtures/element-crop-test.html
-->

---
### Requirement: --element combines with --content-only and --full

The `--element` option SHALL combine legally with `--content-only` and `--full` in any pairing (including all three together). The system SHALL NOT reject these combinations at validation time.

Combination semantics:

- `--element` alone: measure element at current viewport, crop to element
- `--element --content-only`: semantically equivalent to `--element` alone because element coordinates are already viewport-relative (chrome-excluded); no validation error, no redundant operation penalty
- `--element --full`: resize the window to the scrollable page dimensions (existing `--full` flow), capture the resized window, measure the element rect **against the post-resize viewport**, then crop. The element rect SHALL be read AFTER resize, not before, because `getBoundingClientRect` coordinates change with viewport dimensions.
- `--element --full --content-only`: same as `--element --full`; chrome-stripping is implicit in the element crop math.

When `--element` is combined with `--full`, the system SHALL call `getElementBoundsInViewport` after the resize-settle phase, as part of the same post-resize measurement step that reads `getAXWebAreaBounds`. If the element lies outside the post-resize viewport (still possible for fixed-position elements at extreme offsets), the system SHALL throw `elementOutsideViewport` per the fail-closed requirement.

#### Scenario: --element --full crops to element when page fits within display

- **WHEN** the page's scrollable height is less than or equal to the display height
- **AND** contains an element `#target` at viewport coordinates (50, 100) with size 200×150
- **AND** the user runs `safari-browser screenshot /tmp/out.png --full --element "#target"`
- **THEN** the system SHALL resize the window to the scrollable page dimensions
- **AND** after resize the element's viewport rectangle SHALL fall within the post-resize viewport
- **AND** SHALL crop the output PNG to the element's rectangle
- **AND** SHALL restore the original window bounds

#### Scenario: --element --full fails closed when element remains outside display-clamped viewport

- **WHEN** the page is taller than the display (e.g., 6000pt page on an 1100pt-tall display)
- **AND** the target element is positioned below the display-clamped height (e.g., `#below-fold` at y=5000)
- **AND** the user runs `safari-browser screenshot /tmp/out.png --full --element "#below-fold"`
- **THEN** Safari SHALL clamp the requested resize height to the display height per macOS window-server rules
- **AND** the element SHALL remain outside the post-resize viewport
- **AND** the system SHALL throw `elementOutsideViewport(selector:, rect:, viewport:)`
- **AND** SHALL restore the original window bounds
- **AND** SHALL NOT write any file to the output path
- **AND** the error message SHALL suggest scroll-into-view as a workaround (automatic scroll is deferred to a follow-up change)

#### Scenario: --element --content-only produces same output as --element alone

- **WHEN** the page has `#target` at (50, 100) with size 200×150
- **AND** the user runs `safari-browser screenshot /tmp/a.png --element "#target"`
- **AND** ALSO runs `safari-browser screenshot /tmp/b.png --element "#target" --content-only`
- **THEN** both output PNGs SHALL have identical dimensions
- **AND** both SHALL contain only the element's pixel content


<!-- @trace
source: screenshot-element-crop
updated: 2026-04-19
code:
  - Sources/SafariBrowser/Commands/ScreenshotCommand.swift
  - Tests/SafariBrowserTests/ElementCropTests.swift
  - Sources/SafariBrowser/Utilities/Errors.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Tests/SafariBrowserTests/ErrorsTests.swift
  - Tests/Fixtures/element-crop-test.html
-->

---
### Requirement: accessibilityRequired errorDescription customizes alternative by flag

The `SafariBrowserError.accessibilityRequired(flag:)` error case's `errorDescription` SHALL produce a message whose alternative-recovery section adapts to the `flag` parameter:

- When `flag` is `"--content-only"`, the alternative SHALL suggest re-running without `--content-only` to receive a chrome-included screenshot that can be cropped externally.
- When `flag` is `"--element"`, the alternative SHALL suggest re-running with explicit `--window N` / `--url <pattern>` to capture the whole window, then cropping externally with tools like ImageMagick or `sips` to the element's bounding box.
- When `flag` is any other value, the alternative SHALL fall back to a generic "re-run without the flag" suggestion.

All message variants SHALL include the flag name verbatim, the System Settings path to grant Accessibility permission, and the rationale that JavaScript-based fallback was rejected during design for precision-sensitive operations.

#### Scenario: accessibilityRequired for --element suggests external crop

- **WHEN** an `accessibilityRequired(flag: "--element")` error is raised
- **THEN** the `errorDescription` SHALL contain the literal string `"--element"`
- **AND** SHALL contain the System Settings path to Privacy & Security → Accessibility
- **AND** SHALL suggest re-running with `--window N` or `--url <pattern>` to capture the whole window
- **AND** SHALL mention an external cropping tool (ImageMagick or `sips`)

#### Scenario: accessibilityRequired for --content-only suggests dropping the flag

- **WHEN** an `accessibilityRequired(flag: "--content-only")` error is raised
- **THEN** the `errorDescription` SHALL contain the literal string `"--content-only"`
- **AND** SHALL suggest re-running without `--content-only` as the alternative

<!-- @trace
source: screenshot-element-crop
updated: 2026-04-19
code:
  - Sources/SafariBrowser/Commands/ScreenshotCommand.swift
  - Tests/SafariBrowserTests/ElementCropTests.swift
  - Sources/SafariBrowser/Utilities/Errors.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Tests/SafariBrowserTests/ErrorsTests.swift
  - Tests/Fixtures/element-crop-test.html
-->
