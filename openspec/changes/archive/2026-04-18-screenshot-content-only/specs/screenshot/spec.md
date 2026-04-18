## ADDED Requirements

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
