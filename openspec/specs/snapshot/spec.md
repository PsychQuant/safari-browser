# snapshot Specification

## Purpose

TBD - created by archiving change 'snapshot-refs'. Update Purpose after archive.

## Requirements

### Requirement: Scan interactive elements and assign refs

The system SHALL scan the current page's DOM for interactive elements and assign sequential ref IDs (`@e1`, `@e2`, ...). The element references SHALL be stored in `window.__sbRefs` as an array. The output SHALL list each element with its ref ID, tag, type, and descriptive text.

#### Scenario: Snapshot a login form

- **WHEN** user runs `safari-browser snapshot` on a page with an email input, password input, and submit button
- **THEN** stdout contains lines like:
  ```
  @e1  input[type="email"]  placeholder="Email"
  @e2  input[type="password"]  placeholder="Password"
  @e3  button  "Sign In"
  ```
  and `window.__sbRefs` contains the 3 DOM elements

#### Scenario: Snapshot empty page

- **WHEN** user runs `safari-browser snapshot` on a page with no interactive elements
- **THEN** stdout is empty and `window.__sbRefs` is an empty array


<!-- @trace
source: snapshot-refs
updated: 2026-03-28
code:
  - README.md
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Sources/SafariBrowser/SafariBrowser.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Commands/CheckCommand.swift
-->

---
### Requirement: Interactive-only filter

The system SHALL scan only interactive elements by default: `input`, `button`, `a`, `select`, `textarea`, `[role="button"]`, `[role="link"]`, `[role="menuitem"]`, `[role="tab"]`, `[contenteditable]`, and elements with `onclick` attribute.

#### Scenario: Non-interactive elements excluded

- **WHEN** user runs `safari-browser snapshot` on a page with divs, spans, and paragraphs alongside a button
- **THEN** only the button appears in the output


<!-- @trace
source: snapshot-refs
updated: 2026-03-28
code:
  - README.md
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Sources/SafariBrowser/SafariBrowser.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Commands/CheckCommand.swift
-->

---
### Requirement: Scope snapshot to selector

The system SHALL support `--selector` (`-s`) option to limit scanning to descendants of the first element matching the given CSS selector.

#### Scenario: Scoped snapshot

- **WHEN** user runs `safari-browser snapshot -s "form.login"`
- **THEN** only interactive elements within `form.login` are listed


<!-- @trace
source: snapshot-refs
updated: 2026-03-28
code:
  - README.md
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Sources/SafariBrowser/SafariBrowser.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Commands/CheckCommand.swift
-->

---
### Requirement: Re-snapshot replaces refs

The system SHALL clear and replace `window.__sbRefs` on each snapshot invocation. Previous refs become invalid.

#### Scenario: Re-snapshot after navigation

- **WHEN** user runs `safari-browser snapshot`, then navigates to another page, then runs `safari-browser snapshot` again
- **THEN** the new snapshot replaces all previous refs

<!-- @trace
source: snapshot-refs
updated: 2026-03-28
code:
  - README.md
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Sources/SafariBrowser/SafariBrowser.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Commands/CheckCommand.swift
-->

---
### Requirement: Compact snapshot mode

The system SHALL support `--compact` (`-c`) flag that excludes hidden elements (display:none, visibility:hidden, zero dimensions) from the snapshot output.

#### Scenario: Compact snapshot

- **WHEN** user runs `safari-browser snapshot -c` on a page with hidden inputs and visible buttons
- **THEN** only visible interactive elements appear in the output


<!-- @trace
source: parity-with-agent-browser
updated: 2026-03-28
code:
  - Sources/SafariBrowser/Commands/TabsCommand.swift
  - Tests/SafariBrowserTests/CommandParsingTests.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/ConsoleCommand.swift
  - Sources/SafariBrowser/Commands/CookiesCommand.swift
  - Sources/SafariBrowser/SafariBrowser.swift
  - README.md
  - Tests/Fixtures/test-page.html
  - Makefile
  - Sources/SafariBrowser/Commands/DragCommand.swift
  - Sources/SafariBrowser/Commands/SetCommand.swift
  - Sources/SafariBrowser/Commands/PdfCommand.swift
  - Tests/SafariBrowserTests/E2E/E2ETests.swift
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Tests/SafariBrowserTests/ErrorsTests.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
  - Tests/e2e-test.sh
  - LICENSE
  - Sources/SafariBrowser/Commands/JSCommand.swift
  - Tests/SafariBrowserTests/StringExtensionsTests.swift
-->

---
### Requirement: Depth-limited snapshot

The system SHALL support `--depth` (`-d`) option that limits scanning to elements within N levels of DOM depth from the scope root.

#### Scenario: Depth 3 snapshot

- **WHEN** user runs `safari-browser snapshot -d 3`
- **THEN** only interactive elements within 3 levels of nesting from body are listed


<!-- @trace
source: parity-with-agent-browser
updated: 2026-03-28
code:
  - Sources/SafariBrowser/Commands/TabsCommand.swift
  - Tests/SafariBrowserTests/CommandParsingTests.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/ConsoleCommand.swift
  - Sources/SafariBrowser/Commands/CookiesCommand.swift
  - Sources/SafariBrowser/SafariBrowser.swift
  - README.md
  - Tests/Fixtures/test-page.html
  - Makefile
  - Sources/SafariBrowser/Commands/DragCommand.swift
  - Sources/SafariBrowser/Commands/SetCommand.swift
  - Sources/SafariBrowser/Commands/PdfCommand.swift
  - Tests/SafariBrowserTests/E2E/E2ETests.swift
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Tests/SafariBrowserTests/ErrorsTests.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
  - Tests/e2e-test.sh
  - LICENSE
  - Sources/SafariBrowser/Commands/JSCommand.swift
  - Tests/SafariBrowserTests/StringExtensionsTests.swift
-->

---
### Requirement: Improved element descriptions

The snapshot output SHALL include element id (if present), first 3 CSS classes (if present), and disabled state.

#### Scenario: Element with id and classes

- **WHEN** an input has `id="email"` and `class="form-input lg primary"`
- **THEN** the snapshot line shows `@eN  input[type="email"]  #email .form-input.lg.primary  placeholder="Email"`

#### Scenario: Disabled element

- **WHEN** a button has the `disabled` attribute
- **THEN** the snapshot line includes `[disabled]`

<!-- @trace
source: parity-with-agent-browser
updated: 2026-03-28
code:
  - Sources/SafariBrowser/Commands/TabsCommand.swift
  - Tests/SafariBrowserTests/CommandParsingTests.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/ConsoleCommand.swift
  - Sources/SafariBrowser/Commands/CookiesCommand.swift
  - Sources/SafariBrowser/SafariBrowser.swift
  - README.md
  - Tests/Fixtures/test-page.html
  - Makefile
  - Sources/SafariBrowser/Commands/DragCommand.swift
  - Sources/SafariBrowser/Commands/SetCommand.swift
  - Sources/SafariBrowser/Commands/PdfCommand.swift
  - Tests/SafariBrowserTests/E2E/E2ETests.swift
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Tests/SafariBrowserTests/ErrorsTests.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
  - Tests/e2e-test.sh
  - LICENSE
  - Sources/SafariBrowser/Commands/JSCommand.swift
  - Tests/SafariBrowserTests/StringExtensionsTests.swift
-->

---
### Requirement: Page flag for full page state

The `snapshot` command SHALL accept a `--page` flag. When provided, the command SHALL execute the full page state scan (as defined in the `snapshot-page` spec) instead of the default interactive-only scan. All existing flags (`-c`, `-s`, `-d`, `--json`) SHALL remain functional and combinable with `--page`.

#### Scenario: Snapshot with --page flag

- **WHEN** user runs `safari-browser snapshot --page`
- **THEN** the output is a full page state scan (accessibility tree + metadata) instead of the default interactive element list

#### Scenario: Snapshot without --page flag unchanged

- **WHEN** user runs `safari-browser snapshot` (no `--page`)
- **THEN** the output is the existing interactive element list with `@ref` IDs, identical to current behavior

<!-- @trace
source: snapshot-page
updated: 2026-04-08
code:
  - .remember/logs/autonomous/save-072336.log
  - .remember/logs/autonomous/save-072327.log
  - .remember/logs/autonomous/save-234440.log
  - .remember/logs/autonomous/save-124458.log
  - .remember/logs/autonomous/save-110646.log
  - .remember/logs/autonomous/save-165358.log
  - .remember/logs/autonomous/save-113350.log
  - .remember/logs/autonomous/save-113536.log
  - .remember/logs/autonomous/save-152446.log
  - .remember/logs/autonomous/save-070256.log
  - .remember/logs/autonomous/save-165744.log
  - .remember/logs/autonomous/save-165821.log
  - .remember/logs/autonomous/save-114028.log
  - .remember/logs/autonomous/save-113251.log
  - .remember/logs/autonomous/save-114104.log
  - .remember/logs/autonomous/save-154345.log
  - .remember/logs/autonomous/save-124725.log
  - .remember/logs/autonomous/save-124835.log
  - .remember/logs/autonomous/save-154945.log
  - .remember/logs/autonomous/save-234906.log
  - .remember/logs/autonomous/save-070253.log
  - .remember/logs/autonomous/save-165747.log
  - .remember/logs/autonomous/save-070452.log
  - .remember/logs/autonomous/save-065854.log
  - .remember/logs/autonomous/save-153328.log
  - .remember/logs/autonomous/save-160544.log
  - .remember/logs/autonomous/save-112510.log
  - .remember/logs/autonomous/save-115901.log
  - .remember/logs/autonomous/save-170605.log
  - .remember/logs/autonomous/save-110552.log
  - .remember/logs/autonomous/save-152138.log
  - .remember/logs/autonomous/save-170514.log
  - .remember/logs/autonomous/save-011546.log
  - .remember/logs/autonomous/save-113256.log
  - .remember/logs/autonomous/save-065917.log
  - .remember/logs/autonomous/save-110257.log
  - .remember/logs/autonomous/save-235002.log
  - .remember/logs/autonomous/save-113109.log
  - .remember/logs/autonomous/save-135614.log
  - .remember/logs/autonomous/save-012233.log
  - .remember/logs/autonomous/save-114217.log
  - .remember/logs/autonomous/save-012321.log
  - .remember/logs/autonomous/save-151024.log
  - .remember/logs/autonomous/save-012240.log
  - .remember/logs/autonomous/save-152305.log
  - .remember/logs/autonomous/save-115814.log
  - .remember/logs/autonomous/save-122807.log
  - .remember/logs/autonomous/save-143827.log
  - .remember/logs/autonomous/save-165753.log
  - .remember/logs/autonomous/save-125008.log
  - .remember/logs/autonomous/save-114304.log
  - .remember/logs/autonomous/save-112248.log
  - .remember/logs/autonomous/save-143841.log
  - .remember/logs/autonomous/save-165749.log
  - .remember/logs/autonomous/save-143906.log
  - .remember/logs/autonomous/save-115944.log
  - .remember/logs/autonomous/save-152257.log
  - .remember/logs/autonomous/save-112315.log
  - .remember/logs/autonomous/save-165947.log
  - .remember/logs/autonomous/save-092031.log
  - .remember/logs/autonomous/save-115936.log
  - .remember/logs/autonomous/save-115737.log
  - .remember/logs/autonomous/save-113919.log
  - .remember/logs/autonomous/save-110316.log
  - .remember/logs/autonomous/save-011600.log
  - .remember/logs/autonomous/save-111718.log
  - .remember/logs/autonomous/save-113022.log
  - .remember/logs/autonomous/save-113529.log
  - .remember/logs/autonomous/save-114249.log
  - .remember/logs/autonomous/save-124453.log
  - .remember/logs/autonomous/save-070304.log
  - .remember/logs/autonomous/save-235010.log
  - .remember/logs/autonomous/save-070529.log
  - .remember/logs/autonomous/save-124709.log
  - .remember/logs/autonomous/save-152125.log
  - .remember/logs/autonomous/save-135653.log
  - .remember/logs/autonomous/save-155133.log
  - .remember/logs/autonomous/save-110322.log
  - .remember/logs/autonomous/save-115849.log
  - .remember/logs/autonomous/save-135851.log
  - .remember/logs/autonomous/save-070258.log
  - .remember/logs/autonomous/save-160521.log
  - .remember/logs/autonomous/save-160539.log
  - .remember/logs/autonomous/save-070344.log
  - .remember/logs/autonomous/save-112422.log
  - .remember/logs/autonomous/save-154258.log
  - .remember/logs/autonomous/save-112346.log
  - .remember/logs/autonomous/save-124650.log
  - .remember/logs/autonomous/save-165154.log
  - .remember/logs/autonomous/save-114907.log
  - .remember/logs/autonomous/save-160332.log
  - .remember/logs/autonomous/save-113608.log
  - .remember/logs/autonomous/save-012226.log
  - .remember/logs/autonomous/save-114206.log
  - .remember/logs/autonomous/save-072311.log
  - .remember/logs/autonomous/save-110404.log
  - .remember/logs/autonomous/save-135928.log
  - .remember/logs/autonomous/save-151042.log
  - .remember/logs/autonomous/save-155058.log
  - .remember/logs/autonomous/save-135547.log
  - .remember/logs/autonomous/save-110453.log
  - .remember/logs/autonomous/save-070959.log
  - .remember/logs/autonomous/save-114132.log
  - .remember/logs/autonomous/save-065832.log
  - .remember/logs/autonomous/save-112301.log
  - .remember/logs/autonomous/save-113056.log
  - .remember/logs/autonomous/save-072341.log
  - .remember/logs/autonomous/save-152317.log
  - .remember/logs/autonomous/save-160623.log
  - .remember/logs/autonomous/save-165816.log
  - .remember/logs/autonomous/save-234915.log
  - .remember/logs/autonomous/save-160528.log
  - .remember/logs/autonomous/save-165810.log
  - .remember/logs/autonomous/save-234940.log
  - .remember/logs/autonomous/save-152820.log
  - .remember/logs/autonomous/save-124404.log
  - .remember/logs/autonomous/save-170627.log
  - .remember/logs/autonomous/save-110531.log
  - .remember/logs/autonomous/save-135619.log
  - .remember/logs/autonomous/save-165249.log
  - .remember/logs/autonomous/save-165802.log
  - .remember/logs/autonomous/save-234732.log
  - .remember/logs/autonomous/save-165324.log
  - .remember/logs/autonomous/save-152507.log
  - .remember/logs/autonomous/save-113323.log
  - .remember/logs/autonomous/save-012305.log
  - .remember/logs/autonomous/save-122740.log
  - .remember/logs/autonomous/save-165236.log
  - .remember/logs/autonomous/save-234813.log
  - .remember/logs/autonomous/save-110609.log
  - .remember/logs/autonomous/save-154404.log
  - .remember/logs/autonomous/save-160846.log
  - .remember/logs/autonomous/save-165758.log
  - .remember/logs/autonomous/save-112206.log
  - .remember/logs/autonomous/save-113951.log
  - .remember/logs/autonomous/save-114020.log
  - .remember/logs/autonomous/save-160409.log
  - .remember/logs/autonomous/save-113119.log
  - .remember/logs/autonomous/save-165805.log
  - .remember/logs/autonomous/save-114154.log
  - .remember/logs/autonomous/save-165844.log
  - .remember/logs/autonomous/save-012139.log
  - .remember/logs/autonomous/save-065627.log
  - .remember/logs/autonomous/save-110909.log
  - .remember/logs/autonomous/save-113940.log
  - .remember/logs/autonomous/save-112400.log
  - .remember/logs/autonomous/save-150933.log
  - .remember/logs/autonomous/save-112441.log
  - .remember/logs/autonomous/save-165804.log
  - .remember/logs/autonomous/save-012358.log
  - .remember/logs/autonomous/save-155051.log
  - .remember/logs/autonomous/save-070707.log
  - .remember/logs/autonomous/save-160307.log
  - .remember/logs/autonomous/save-110628.log
  - .remember/logs/autonomous/save-070356.log
  - .remember/logs/autonomous/save-124623.log
  - .remember/logs/autonomous/save-110016.log
  - .remember/logs/autonomous/save-065835.log
  - .remember/logs/autonomous/save-124434.log
  - .remember/logs/autonomous/save-110312.log
  - .remember/logs/autonomous/save-124941.log
  - .remember/logs/autonomous/save-122738.log
  - .remember/logs/autonomous/save-234951.log
  - .remember/logs/autonomous/save-150753.log
  - .remember/logs/autonomous/save-150715.log
  - .remember/logs/autonomous/save-114051.log
  - .remember/logs/autonomous/save-165148.log
  - .remember/logs/autonomous/save-110528.log
  - .remember/logs/autonomous/save-113117.log
  - .remember/logs/autonomous/save-110148.log
  - .remember/logs/autonomous/save-152500.log
  - .remember/logs/autonomous/save-160404.log
  - .remember/logs/autonomous/save-160618.log
  - .remember/logs/autonomous/save-070421.log
  - .remember/logs/autonomous/save-115708.log
  - .remember/logs/autonomous/save-124415.log
  - .remember/logs/autonomous/save-154926.log
  - .remember/logs/autonomous/save-235039.log
  - .remember/logs/autonomous/save-235111.log
  - .remember/logs/autonomous/save-114353.log
  - .remember/logs/autonomous/save-072424.log
  - .remember/logs/autonomous/save-113052.log
  - .remember/logs/autonomous/save-113127.log
  - .remember/logs/autonomous/save-111709.log
  - .remember/logs/autonomous/save-124419.log
  - .remember/logs/autonomous/save-065859.log
  - .remember/logs/autonomous/save-165845.log
  - .remember/logs/autonomous/save-234859.log
  - .remember/logs/autonomous/save-012406.log
  - .remember/logs/autonomous/save-012230.log
  - .remember/logs/autonomous/save-115827.log
  - .remember/logs/autonomous/save-065813.log
  - .remember/logs/autonomous/save-072241.log
  - .remember/logs/autonomous/save-072416.log
  - .remember/logs/autonomous/save-170242.log
  - .remember/logs/autonomous/save-154938.log
  - .remember/logs/autonomous/save-110246.log
  - .remember/logs/autonomous/save-114312.log
  - .remember/logs/autonomous/save-160217.log
  - .remember/logs/autonomous/save-112553.log
  - .remember/logs/autonomous/save-065827.log
  - .remember/logs/autonomous/save-105921.log
  - .remember/logs/autonomous/save-012505.log
  - .remember/logs/autonomous/save-152133.log
  - .remember/logs/autonomous/save-152440.log
  - .remember/logs/autonomous/save-160419.log
  - .remember/logs/autonomous/save-160559.log
  - .remember/logs/autonomous/save-170523.log
  - .remember/logs/autonomous/save-165817.log
  - .remember/logs/autonomous/save-165221.log
  - .remember/logs/autonomous/save-152204.log
  - .remember/logs/autonomous/save-234744.log
  - .remember/logs/autonomous/save-151344.log
  - .remember/logs/autonomous/save-012320.log
  - .remember/logs/autonomous/save-065944.log
  - .remember/logs/autonomous/save-152443.log
  - .remember/logs/autonomous/save-165141.log
  - .remember/logs/autonomous/save-170604.log
  - .remember/logs/autonomous/save-234727.log
  - .remember/logs/autonomous/save-113059.log
  - .remember/logs/autonomous/save-065808.log
  - .remember/logs/autonomous/save-112242.log
  - .remember/logs/autonomous/save-113135.log
  - .remember/logs/autonomous/save-110918.log
  - .remember/logs/autonomous/save-110516.log
  - .remember/logs/autonomous/save-115724.log
  - .remember/logs/autonomous/save-112520.log
  - .remember/logs/autonomous/save-154418.log
  - .remember/logs/autonomous/save-110536.log
  - .remember/logs/autonomous/save-011515.log
  - .remember/logs/autonomous/save-070349.log
  - .remember/logs/autonomous/save-113703.log
  - .remember/logs/autonomous/save-160534.log
  - .remember/logs/autonomous/save-165723.log
  - .remember/logs/autonomous/save-113144.log
  - .remember/logs/autonomous/save-112540.log
  - .remember/logs/autonomous/save-012736.log
  - .remember/logs/autonomous/save-135604.log
  - .remember/logs/autonomous/save-110618.log
  - .remember/logs/autonomous/save-115621.log
  - .remember/logs/autonomous/save-114122.log
  - .remember/logs/autonomous/save-110043.log
  - .remember/logs/autonomous/save-110329.log
  - .remember/logs/autonomous/save-160451.log
  - .remember/logs/autonomous/save-114258.log
  - .remember/logs/autonomous/save-143756.log
  - .remember/logs/autonomous/save-152218.log
  - .remember/logs/autonomous/save-165311.log
  - .remember/logs/autonomous/save-124511.log
  - .remember/logs/autonomous/save-115731.log
  - .remember/logs/autonomous/save-120617.log
  - .remember/logs/autonomous/save-154434.log
  - .remember/logs/autonomous/save-012950.log
  - .remember/logs/autonomous/save-105928.log
  - .remember/logs/autonomous/save-110218.log
  - .remember/logs/autonomous/save-065954.log
  - .remember/logs/autonomous/save-012343.log
  - .remember/logs/autonomous/save-110355.log
  - .remember/logs/autonomous/save-110116.log
  - .remember/logs/autonomous/save-012926.log
  - .remember/logs/autonomous/save-112451.log
  - .remember/logs/autonomous/save-155116.log
  - .remember/logs/autonomous/save-113910.log
  - .remember/logs/autonomous/save-115702.log
  - .remember/logs/autonomous/save-160515.log
  - .remember/logs/autonomous/save-012513.log
  - .remember/logs/autonomous/save-110348.log
  - .remember/logs/autonomous/save-152439.log
  - .remember/logs/autonomous/save-065817.log
  - .remember/logs/autonomous/save-112308.log
  - .remember/logs/autonomous/save-160503.log
  - .remember/logs/autonomous/save-110518.log
  - .remember/logs/autonomous/save-065846.log
  - .remember/logs/autonomous/save-152245.log
  - .remember/logs/autonomous/save-135634.log
  - .remember/logs/autonomous/save-065822.log
  - .remember/logs/autonomous/save-110335.log
  - .remember/logs/autonomous/save-114034.log
  - .remember/logs/autonomous/save-124420.log
  - .remember/logs/autonomous/save-165807.log
  - .remember/logs/autonomous/save-160251.log
  - .remember/logs/autonomous/save-012331.log
  - .remember/logs/autonomous/save-110030.log
  - .remember/logs/autonomous/save-152707.log
  - .remember/logs/autonomous/save-012308.log
  - .remember/logs/autonomous/save-072234.log
  - .remember/logs/autonomous/save-160314.log
  - .remember/logs/autonomous/save-113851.log
  - .remember/logs/autonomous/save-070245.log
  - .remember/logs/autonomous/save-070748.log
  - .remember/logs/autonomous/save-124548.log
  - .remember/logs/autonomous/save-110031.log
  - .remember/logs/autonomous/save-125031.log
  - .remember/logs/autonomous/save-235052.log
  - .remember/logs/autonomous/save-140115.log
  - .remember/logs/autonomous/save-165832.log
  - .remember/logs/autonomous/save-065840.log
  - .remember/logs/autonomous/save-070330.log
  - .remember/logs/autonomous/save-234432.log
  - .remember/logs/autonomous/save-011537.log
  - .remember/logs/autonomous/save-072357.log
  - .remember/logs/autonomous/save-122736.log
  - .remember/logs/autonomous/save-113958.log
  - .remember/logs/autonomous/save-165716.log
  - .remember/logs/autonomous/save-105905.log
  - .remember/logs/autonomous/save-110235.log
  - .remember/logs/autonomous/save-110428.log
  - .remember/logs/autonomous/save-070157.log
  - .remember/logs/autonomous/save-070230.log
  - .remember/logs/autonomous/save-113128.log
  - .remember/logs/autonomous/save-165245.log
  - .remember/logs/autonomous/save-165754.log
  - .remember/logs/autonomous/save-065950.log
  - .remember/logs/autonomous/save-070343.log
  - .remember/logs/autonomous/save-124539.log
  - .remember/logs/autonomous/save-120618.log
  - .remember/logs/autonomous/save-160513.log
  - .remember/logs/autonomous/save-165759.log
  - .remember/logs/autonomous/save-124712.log
  - .remember/logs/autonomous/save-110637.log
  - .remember/logs/autonomous/save-113110.log
  - .remember/logs/autonomous/save-113902.log
  - .remember/logs/autonomous/save-160508.log
  - .remember/logs/autonomous/save-070325.log
  - .remember/logs/autonomous/save-155123.log
  - .remember/logs/autonomous/save-160516.log
  - .remember/logs/autonomous/save-160512.log
  - .remember/logs/autonomous/save-154500.log
  - .remember/logs/autonomous/save-113058.log
  - .remember/logs/autonomous/save-110435.log
  - .remember/logs/autonomous/save-114235.log
  - .remember/logs/autonomous/save-165111.log
  - .remember/logs/autonomous/save-154951.log
  - .remember/logs/autonomous/save-012304.log
  - .remember/logs/autonomous/save-070235.log
  - .remember/logs/autonomous/save-071019.log
  - .remember/logs/autonomous/save-111750.log
  - .remember/logs/autonomous/save-112325.log
  - .remember/logs/autonomous/save-124719.log
  - .remember/logs/autonomous/save-113645.log
  - .remember/logs/autonomous/save-160219.log
  - .remember/logs/autonomous/save-155121.log
  - .remember/logs/autonomous/save-152224.log
  - .remember/logs/autonomous/save-155007.log
  - .remember/logs/autonomous/save-165225.log
  - .remember/logs/autonomous/save-165803.log
  - .remember/logs/autonomous/save-170439.log
  - .remember/logs/autonomous/save-140044.log
  - .remember/logs/autonomous/save-070308.log
  - .remember/logs/autonomous/save-160243.log
  - .remember/logs/autonomous/save-072239.log
  - .remember/logs/autonomous/save-165818.log
  - .remember/logs/autonomous/save-112413.log
  - .remember/logs/autonomous/save-113116.log
  - .remember/logs/autonomous/save-072439.log
  - .remember/logs/autonomous/save-115805.log
  - .remember/logs/autonomous/save-124553.log
  - .remember/logs/autonomous/save-115923.log
  - .remember/logs/autonomous/save-152038.log
  - .remember/logs/autonomous/save-152619.log
  - .remember/logs/autonomous/save-152116.log
  - .remember/logs/autonomous/save-152743.log
  - .remember/logs/autonomous/save-114011.log
  - .remember/logs/autonomous/save-165850.log
  - .remember/logs/autonomous/save-165757.log
  - .remember/logs/autonomous/save-110525.log
  - .remember/logs/autonomous/save-152045.log
  - .remember/logs/autonomous/save-070651.log
  - .remember/logs/autonomous/save-234934.log
  - .remember/logs/autonomous/save-070629.log
  - .remember/logs/autonomous/save-070307.log
  - .remember/logs/autonomous/save-124928.log
  - .remember/logs/autonomous/save-152233.log
  - .remember/logs/autonomous/save-165342.log
  - .remember/logs/autonomous/save-110413.log
  - .remember/logs/autonomous/save-154441.log
  - .remember/logs/autonomous/save-110339.log
  - .remember/logs/autonomous/save-124639.log
  - .remember/logs/autonomous/save-112212.log
  - .remember/logs/autonomous/save-154338.log
  - .remember/logs/autonomous/save-152149.log
  - .remember/logs/autonomous/save-070603.log
  - .remember/logs/autonomous/save-160231.log
  - .remember/logs/autonomous/save-113322.log
  - .remember/logs/autonomous/save-125025.log
  - .remember/logs/autonomous/save-124827.log
  - .remember/logs/autonomous/save-165348.log
  - .remember/logs/autonomous/save-072236.log
  - .remember/logs/autonomous/save-165838.log
  - .remember/logs/autonomous/save-234452.log
  - .remember/logs/autonomous/save-165828.log
  - .remember/logs/autonomous/save-235022.log
  - .remember/logs/autonomous/save-160227.log
  - .remember/logs/autonomous/save-110324.log
  - .remember/logs/autonomous/save-124425.log
  - .remember/logs/autonomous/save-110416.log
  - .remember/logs/autonomous/save-155003.log
  - .remember/logs/autonomous/save-160535.log
  - .remember/logs/autonomous/save-072227.log
  - .remember/logs/autonomous/save-012626.log
  - .remember/logs/autonomous/save-152412.log
  - .remember/logs/autonomous/save-124919.log
  - .remember/logs/autonomous/save-155035.log
  - .remember/logs/autonomous/save-012311.log
  - .remember/logs/autonomous/save-234834.log
  - .remember/logs/autonomous/save-152212.log
  - .remember/logs/autonomous/save-135624.log
  - .remember/logs/autonomous/save-160337.log
  - .remember/logs/autonomous/save-110853.log
  - .remember/logs/autonomous/save-155027.log
  - .remember/logs/autonomous/save-151840.log
  - .remember/logs/autonomous/save-113840.log
  - .remember/logs/autonomous/save-113541.log
  - .remember/logs/autonomous/save-125847.log
  - .remember/logs/autonomous/save-110104.log
  - .remember/logs/autonomous/save-110522.log
  - .remember/logs/autonomous/save-160431.log
  - .remember/logs/autonomous/save-160458.log
  - .remember/logs/autonomous/save-234921.log
  - .remember/logs/autonomous/save-235016.log
  - .remember/logs/autonomous/save-154333.log
  - .remember/logs/autonomous/save-112220.log
  - .remember/logs/autonomous/save-072333.log
  - .remember/logs/autonomous/save-154248.log
  - .remember/logs/autonomous/save-160504.log
  - .remember/logs/autonomous/save-112433.log
  - .remember/logs/autonomous/save-012313.log
  - .remember/logs/autonomous/save-165208.log
  - .remember/logs/autonomous/save-110600.log
  - .remember/logs/autonomous/save-072320.log
  - .remember/logs/autonomous/save-114044.log
  - .remember/logs/autonomous/save-012602.log
  - .remember/logs/autonomous/save-155041.log
  - .remember/logs/autonomous/save-113057.log
  - .remember/logs/autonomous/save-012236.log
  - .remember/logs/autonomous/save-065740.log
  - .remember/logs/autonomous/save-012251.log
  - .remember/logs/autonomous/save-151218.log
  - .remember/logs/autonomous/save-160220.log
  - .remember/logs/autonomous/save-112503.log
  - .remember/logs/autonomous/save-012402.log
  - .remember/logs/autonomous/save-114358.log
  - .remember/logs/autonomous/save-165836.log
  - .remember/logs/autonomous/save-170546.log
  - .remember/logs/autonomous/save-235044.log
  - .remember/logs/autonomous/save-110305.log
  - .remember/logs/autonomous/save-110901.log
  - .remember/logs/autonomous/save-012354.log
  - .remember/logs/autonomous/save-150946.log
  - .remember/logs/autonomous/save-165405.log
  - .remember/logs/autonomous/save-110127.log
  - .remember/logs/autonomous/save-113200.log
  - .remember/logs/autonomous/save-124957.log
  - .remember/logs/autonomous/save-135629.log
  - .remember/logs/autonomous/save-152523.log
  - .remember/logs/autonomous/save-110927.log
  - .remember/logs/autonomous/save-152157.log
  - .remember/logs/autonomous/save-125013.log
  - .remember/logs/autonomous/save-070217.log
  - .remember/logs/autonomous/save-152451.log
  - .remember/logs/autonomous/save-152427.log
  - .remember/logs/autonomous/save-165823.log
  - .remember/logs/autonomous/save-113123.log
  - .remember/logs/autonomous/save-153329.log
  - .remember/logs/autonomous/save-124644.log
  - .remember/logs/autonomous/save-065701.log
  - .remember/logs/autonomous/save-070012.log
  - .remember/logs/autonomous/save-072326.log
  - .remember/logs/autonomous/save-150909.log
  - .remember/logs/autonomous/save-124739.log
  - .remember/logs/autonomous/save-165240.log
  - .remember/logs/autonomous/save-165751.log
  - .remember/logs/autonomous/save-125001.log
  - .remember/logs/autonomous/save-070254.log
  - .remember/logs/autonomous/save-012850.log
  - .remember/logs/autonomous/save-165827.log
  - .remember/logs/autonomous/save-110317.log
  - .remember/logs/autonomous/save-124948.log
  - .remember/logs/autonomous/save-012504.log
  - .remember/logs/autonomous/save-165116.log
  - .remember/logs/autonomous/save-165815.log
  - .remember/logs/autonomous/save-065626.log
  - .remember/logs/autonomous/save-165801.log
  - .remember/logs/autonomous/save-110406.log
  - .remember/logs/autonomous/save-170508.log
  - .remember/logs/autonomous/save-065929.log
  - .remember/logs/autonomous/save-170321.log
  - .remember/logs/autonomous/save-165254.log
  - .remember/logs/autonomous/save-234800.log
  - .remember/logs/autonomous/save-165317.log
  - .remember/logs/autonomous/save-234806.log
  - .remember/logs/autonomous/save-154958.log
  - .remember/logs/autonomous/save-110109.log
  - .remember/logs/autonomous/save-065843.log
  - .remember/logs/autonomous/save-111739.log
  - .remember/logs/autonomous/save-160456.log
  - .remember/logs/autonomous/save-113112.log
  - .remember/tmp/save-session.pid
  - .remember/logs/autonomous/save-154507.log
  - .remember/logs/autonomous/save-170636.log
  - .remember/logs/autonomous/save-070622.log
  - .remember/logs/autonomous/save-151008.log
  - .remember/logs/autonomous/save-115832.log
  - .remember/logs/autonomous/save-155012.log
  - .remember/logs/autonomous/save-171610.log
  - .remember/logs/autonomous/save-235131.log
  - .remember/logs/autonomous/save-113436.log
  - .remember/logs/autonomous/save-160502.log
  - .remember/logs/autonomous/save-234426.log
  - .remember/logs/autonomous/save-152505.log
  - .remember/logs/autonomous/save-234827.log
  - .remember/logs/autonomous/save-070658.log
  - .remember/logs/autonomous/save-125019.log
  - .remember/logs/autonomous/save-065925.log
  - .remember/logs/autonomous/save-115539.log
  - .remember/logs/autonomous/save-160226.log
  - .remember/logs/autonomous/save-012318.log
  - .remember/logs/autonomous/save-113118.log
  - .remember/logs/autonomous/save-115713.log
  - .remember/logs/autonomous/save-124934.log
  - .remember/logs/autonomous/save-125854.log
  - .remember/logs/autonomous/save-065753.log
  - .remember/logs/autonomous/save-110526.log
  - .remember/logs/autonomous/save-113823.log
  - .remember/logs/autonomous/save-150846.log
  - .remember/logs/autonomous/save-012359.log
  - .remember/logs/autonomous/save-110223.log
  - .remember/logs/autonomous/save-140108.log
  - .remember/logs/autonomous/save-070610.log
  - .remember/logs/autonomous/save-154449.log
  - .remember/logs/autonomous/save-065911.log
  - .remember/logs/autonomous/save-143805.log
  - .remember/logs/autonomous/save-152454.log
  - .remember/logs/autonomous/save-114210.log
  - .remember/logs/autonomous/save-165820.log
  - .remember/logs/autonomous/save-160457.log
  - .remember/logs/autonomous/save-065850.log
  - .remember/logs/autonomous/save-113040.log
  - .remember/logs/autonomous/save-170502.log
  - .remember/logs/autonomous/save-110143.log
  - .remember/logs/autonomous/save-165717.log
  - .remember/logs/autonomous/save-113137.log
  - .remember/logs/autonomous/save-124506.log
  - .remember/logs/autonomous/save-124558.log
  - .remember/logs/autonomous/save-152510.log
  - .remember/logs/autonomous/save-165812.log
  - .remember/logs/autonomous/save-065727.log
  - .remember/logs/autonomous/save-152522.log
  - .remember/logs/autonomous/save-165811.log
  - .remember/logs/autonomous/save-151111.log
  - .remember/logs/autonomous/save-140038.log
  - .remember/logs/autonomous/save-113140.log
  - .remember/logs/autonomous/save-234957.log
  - .remember/logs/autonomous/save-110835.log
  - .remember/logs/autonomous/save-110252.log
  - .remember/logs/autonomous/save-070420.log
  - .remember/logs/autonomous/save-150655.log
  - .remember/logs/autonomous/save-160424.log
  - .remember/logs/autonomous/save-124909.log
  - .remember/logs/autonomous/save-154931.log
  - .remember/logs/autonomous/save-110023.log
  - .remember/logs/autonomous/save-124744.log
  - .remember/logs/autonomous/save-160541.log
  - .remember/logs/autonomous/save-160603.log
  - .remember/logs/autonomous/save-154413.log
  - .remember/logs/autonomous/save-234848.log
  - .remember/logs/autonomous/save-165110.log
  - .remember/logs/autonomous/save-070236.log
  - .remember/logs/autonomous/save-065935.log
  - .remember/logs/autonomous/save-112334.log
  - .remember/logs/autonomous/save-160517.log
  - .remember/logs/autonomous/save-160236.log
  - .remember/logs/autonomous/save-115838.log
  - .remember/logs/autonomous/save-135646.log
  - .remember/logs/autonomous/save-124733.log
  - .remember/logs/autonomous/save-160511.log
  - .remember/logs/autonomous/save-110037.log
  - .remember/logs/autonomous/save-165742.log
  - .remember/logs/autonomous/save-110520.log
  - .remember/logs/autonomous/save-113124.log
  - .remember/logs/autonomous/save-070321.log
  - .remember/logs/autonomous/save-012133.log
  - .remember/logs/autonomous/save-124843.log
  - .remember/logs/autonomous/save-152452.log
  - .remember/logs/autonomous/save-072310.log
  - .remember/logs/autonomous/save-124617.log
  - .remember/logs/autonomous/save-135555.log
  - .remember/logs/autonomous/save-012241.log
  - .remember/logs/autonomous/save-070645.log
  - .remember/logs/autonomous/save-110502.log
  - .remember/logs/autonomous/save-113618.log
  - .remember/logs/autonomous/save-150804.log
  - .remember/logs/autonomous/save-135909.log
  - .remember/logs/autonomous/save-151053.log
  - .remember/logs/autonomous/save-012521.log
  - .remember/logs/autonomous/save-113627.log
  - .remember/logs/autonomous/save-154454.log
  - .remember/logs/autonomous/save-150900.log
  - .remember/logs/autonomous/save-072446.log
  - .remember/logs/autonomous/save-124856.log
  - .remember/logs/autonomous/save-165135.log
  - .remember/logs/autonomous/save-165738.log
  - .remember/logs/autonomous/save-070155.log
  - .remember/logs/autonomous/save-135902.log
  - .remember/logs/autonomous/save-235028.log
  - .remember/logs/autonomous/save-124628.log
  - .remember/logs/autonomous/save-235101.log
  - .remember/logs/autonomous/save-152925.log
  - .remember/logs/autonomous/save-160617.log
  - .remember/logs/autonomous/save-170444.log
  - .remember/logs/autonomous/save-012349.log
  - .remember/logs/autonomous/save-065750.log
  - .remember/logs/autonomous/save-170457.log
  - .remember/logs/autonomous/save-234530.log
  - .remember/logs/autonomous/save-110229.log
  - .remember/logs/autonomous/save-165300.log
  - .remember/logs/autonomous/save-111746.log
  - .remember/logs/autonomous/save-115910.log
  - .remember/logs/autonomous/save-143712.log
  - .remember/logs/autonomous/save-155109.log
  - .remember/logs/autonomous/save-160250.log
  - .remember/logs/autonomous/save-165304.log
  - .remember/logs/autonomous/save-170633.log
  - .remember/logs/autonomous/save-112234.log
  - .remember/logs/autonomous/save-152448.log
  - .remember/logs/autonomous/save-154307.log
-->