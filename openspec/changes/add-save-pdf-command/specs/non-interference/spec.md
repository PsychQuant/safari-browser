## ADDED Requirements

### Requirement: save-pdf is non-interfering and sends no request

`save-pdf` SHALL be classified as **Non-interfering**. It evaluates JavaScript in the targeted tab and writes only the destination file the caller named. It SHALL NOT control input devices, display system dialogs, produce sound, switch tabs, or change window focus, and SHALL work on a background tab. It SHALL NOT need Accessibility permission or Full Disk Access.

The in-page read SHALL NOT send a network request: `only-if-cached` fails instead of reaching the network, and a page controlled by a service worker is refused. The command is recorded as JavaScript-evaluating, which `pdf-cache` is not.

#### Scenario: saving from a background tab

- **WHEN** `safari-browser save-pdf out.pdf --url "example.org/a.pdf"` targets a tab that is not the current tab of its window
- **THEN** the file is written and the window's current tab and the frontmost application are unchanged

#### Scenario: no request during the read

- **WHEN** `save-pdf` runs against a local server that logs requests
- **THEN** the log gains no entry
