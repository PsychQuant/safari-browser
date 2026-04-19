## ADDED Requirements

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
