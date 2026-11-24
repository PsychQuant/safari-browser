## MODIFIED Requirements

### Requirement: save-pdf is non-interfering and sends no request

`save-pdf` SHALL be classified as **Non-interfering**. It evaluates JavaScript in the targeted tab and writes only the destination file the caller named. It SHALL NOT control input devices, display system dialogs, produce sound, switch tabs, or change window focus, and SHALL work on a background tab. It SHALL NOT need Accessibility permission or Full Disk Access, and SHALL NOT open Safari's own folders unless the caller names a destination in one.

The in-page read SHALL NOT itself send a request for the document: `only-if-cached` fails instead of reaching the network. When a service worker controls the page, the read is sent the same way and checked afterwards, as the save-pdf specification states: without `--allow-service-worker`, a read the service worker handled, or one that cannot be confirmed, is not kept, and with the flag such a read is kept although the service worker could have answered it from the network. When WebKit no longer holds the document (it was dropped, or the page changed its address), the read of a tab a service worker controls reaches the service worker like any fetch of the page, also without the flag and before the check, and the service worker can answer it from the network; save-pdf still saves nothing it did not confirm. Besides the service worker cases above, there is one more exception, which the page cannot prevent because it cannot read the policy beforehand: when the document's Content-Security-Policy blocks the fetch and names a report endpoint, the browser itself posts a violation report containing the address. The command is recorded as JavaScript-evaluating, which `pdf-cache` is not.

#### Scenario: saving from a background tab

- **WHEN** `safari-browser save-pdf out.pdf --url "example.org/a.pdf"` targets a tab that is not the current tab of its window
- **THEN** the file is written and the window's current tab and the frontmost application are unchanged

#### Scenario: no Full Disk Access

- **WHEN** the process cannot read Safari's cache folder and the destination is elsewhere
- **THEN** the file is written, and that folder was not opened

#### Scenario: no request during the read

- **WHEN** `save-pdf` runs against a local server that logs requests, the document has no policy naming a report endpoint, and either no service worker controls the tab or WebKit holds the document
- **THEN** the log gains no entry during the read

#### Scenario: a page a service worker controls

- **WHEN** a service worker controls the targeted PDF tab and does not handle the read
- **THEN** the file is written and, during the read, the server log gains no entry and the service worker records no fetch event

##### Example: a controlled PDF tab read with no request

- **GIVEN** a local server that logs requests, and a service worker that answers every fetch from the network and reports each fetch event to that server, controlling a tab that displays a PDF served with `Cache-Control: no-store`
- **WHEN** `save-pdf` reads the tab without `--allow-service-worker`
- **THEN** the file is written and the server log gains no entry during the read

#### Scenario: a page a service worker controls whose document is not held

- **WHEN** a service worker controls the targeted tab and WebKit does not hold the document at the tab's address
- **THEN** the read reaches the service worker, the server can receive a request from it, and no file is written

##### Example: a controlled PDF tab whose document is not held

- **GIVEN** a local server that logs requests, and a service worker that answers every fetch from the network, controlling a PDF tab whose address was changed with `history.replaceState` to a URL that was never loaded
- **WHEN** `save-pdf` reads the tab without `--allow-service-worker`
- **THEN** the server log gains a request for that URL during the read, and no file is written
