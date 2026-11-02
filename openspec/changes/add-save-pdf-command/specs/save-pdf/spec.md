## Purpose

`save-pdf` saves the PDF a targeted tab is displaying to a file, using only the bytes WebKit already holds. It exists for PDFs that never reached the disk cache read by `pdf-cache`, such as responses marked `Cache-Control: no-store`.

## ADDED Requirements

### Requirement: save-pdf saves the displayed PDF without any request

The `safari-browser` CLI SHALL provide a `save-pdf <path>` subcommand that writes the PDF document displayed by the targeted tab to `<path>`. It SHALL obtain the bytes only through one in-page `fetch` of the document's own URL with `cache: 'only-if-cached'` and `mode: 'same-origin'`. The page script SHALL contain no other network API, and the command itself SHALL open no network connection. When that fetch fails, the command SHALL fail and SHALL NOT retry with any other cache mode, request, or dialog. An answer with a status other than 200 SHALL fail the command with nothing saved. The command saves what that fetch answers. It does not look at the server's status, which that answer does not show on WebKit: a PDF document answers 200 whatever the server sent, and a tab that arrived through a redirect is not refused.

#### Scenario: a no-store PDF is saved with no new request

- **WHEN** a tab displays a PDF served with `Cache-Control: no-store`
- **AND** the user runs `safari-browser save-pdf out.pdf --url "example.org/paper.pdf"`
- **THEN** `out.pdf` holds the same bytes the server sent
- **AND** the server receives no request after the one that displayed the PDF

#### Scenario: bytes WebKit does not hold are not fetched

- **WHEN** the in-page fetch rejects
- **THEN** the command exits 1 with an error saying WebKit no longer holds the document or the page's policy blocked the read, and that nothing was requested
- **AND** the server receives no request

#### Scenario: an answer that is not 200

- **WHEN** the fetch answers with a status other than 200
- **THEN** the command exits 1 and no file is written

#### Scenario: a tab that arrived through a redirect

- **WHEN** a tab displays a PDF it reached through a redirect
- **THEN** the file holds the PDF the tab displays

### Requirement: The target tab must be named explicitly

`save-pdf` SHALL require a tab-targeting flag (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--window` with optional `--tab-in-window`, `--document`, or `--tab`). Without one it SHALL fail with a usage error before contacting Safari. `--first-match` alone is not a target. It SHALL accept `--profile`. The target SHALL be resolved once at the start. From the moment the page script runs, every step SHALL be tied to that document by its slot, which exists only there: when the tab shows another document afterwards, the command SHALL fail and SHALL NOT read it. Before that moment a position names whatever is at that position and a pattern whatever matches it, as for every command, and the output names the address read. When the tab vanishes, the error SHALL name the target and SHALL NOT list other tabs.

#### Scenario: no target

- **WHEN** the user runs `safari-browser save-pdf out.pdf`
- **THEN** the command exits 64 and no AppleScript is run

#### Scenario: first-match alone is not a target

- **WHEN** the user runs `safari-browser save-pdf out.pdf --first-match`
- **THEN** the command exits 64 and no AppleScript is run

#### Scenario: the tab vanishes during the read

- **WHEN** the targeted tab is closed after the command resolved it
- **THEN** the command exits 1 with an error naming the target, and the error lists no other tab

### Requirement: Only a PDF document outside a service worker is read

The page script SHALL fail with a not-a-PDF error, naming the content type, when `document.contentType` is neither `application/pdf` nor `text/pdf`, the two types WebKit displays as a PDF. It SHALL fail with a service-worker error when `navigator.serviceWorker.controller` is set, because a service worker's answer can come from the network. Neither case SHALL call `fetch`.

#### Scenario: an HTML page embedding a PDF

- **WHEN** the targeted tab's document has content type `text/html`
- **THEN** the command exits 1 naming that content type, and `fetch` is not called

#### Scenario: a page controlled by a service worker

- **WHEN** `navigator.serviceWorker.controller` is set in the targeted tab
- **THEN** the command exits 1 with the service-worker error, and `fetch` is not called

### Requirement: The transfer belongs to one call and one document

The page script SHALL park the result in a slot made for this call by `ResultSlot.make()`, and the command SHALL read it through the verified chunked read of `SafariBridge.readResultSlot`. The size and length the page reports SHALL be checked before they are used: the size SHALL NOT exceed `TabPDFReader.maxBytes`, and the length SHALL be the base64 length of that size. The decoded byte count SHALL equal the size the page reported, or the command SHALL fail. When the slot is gone (the page was replaced), the command SHALL fail with a page-replaced error. When the page reports a size above `TabPDFReader.maxBytes` (268,435,456 bytes), the command SHALL fail before encoding the bytes. When the page does not report a result within `TabPDFReader.deadlineSeconds` (60 seconds, counted from before the read is started), the command SHALL fail; a result arriving after that is not taken. The transfer back is not under this deadline. When the page script does not run, because the document is still loading or its policy forbids scripts, the command SHALL say that and not report a damaged reply. The command SHALL remove its slot when it finishes, unless the tab has stopped answering.

#### Scenario: the page is replaced during the read

- **WHEN** the slot disappears after the page reported success and before the last chunk is read
- **THEN** the command exits 1, no file is written at the destination, and no temporary file remains

#### Scenario: two calls on one page

- **WHEN** two `save-pdf` calls run on the same tab at the same time
- **THEN** each reads its own slot and each file holds the complete document

#### Scenario: a tab that runs no scripts

- **WHEN** the start script does not answer `started`
- **THEN** the command exits 1 saying the tab is not running scripts, and no file is written

#### Scenario: a reply outside the closed format

- **WHEN** the status script answers anything other than `gone`, `wait`, `ok:<bytes>:<len>` or `fail:<code>:<detail>`
- **THEN** the command exits 1 reporting a damaged reply

### Requirement: The file is published through the verified path

The decoded bytes SHALL be written to an owner-only file inside a private temporary folder and published with `PDFCacheOutput.copyVerified`, which requires the `%PDF-` header and readable pages, refuses an existing destination unless `--force`, and leaves no destination on failure. An existing destination, and a destination whose parent is not a folder, SHALL be refused before the bytes are transferred when that can be seen. The temporary folder SHALL be removed when the command finishes. A destination inside Safari's cache folder SHALL be refused by comparing paths. The command SHALL NOT open or list that folder or anything else in Safari's container: without Full Disk Access that is another application's data, and touching it can raise a permission dialog.

#### Scenario: an existing destination

- **WHEN** `out.pdf` exists and `--force` is not given
- **THEN** the command fails before any in-page fetch and `out.pdf` is unchanged

#### Scenario: bytes that are not a PDF

- **WHEN** the bytes read do not start with `%PDF-`
- **THEN** the command fails with an error that does not name the temporary file, no file appears at the destination, and the temporary folder is gone

#### Scenario: no access to Safari's cache folder

- **WHEN** the process cannot read Safari's cache folder and the destination is elsewhere
- **THEN** the file is published and that folder was not opened

### Requirement: Output shows the URL without its secrets

On success the command SHALL print one line with the destination path, size, page count, and the tab's URL, or with `--json` one object with `path`, `size`, `pages`, `source` (`"tab"`), and `url`. The address SHALL stay in the page: no script the command sends SHALL contain it, because a script is a process argument, part of a timeout message and a daemon log entry, and the page SHALL report back only the protocol, host and path. That SHALL pass through `URLText.redactURL`, so a path parameter does not appear either. A failure inside the page SHALL report the error's name and not its message, whose text is WebKit's and can carry the URL.

#### Scenario: a signed URL

- **WHEN** the tab's URL is `https://cdn.example.org/main.pdf?X-Amz-Signature=SECRET`
- **THEN** neither the output, nor any error message, nor any script sent to Safari contains `SECRET`

#### Scenario: a rejection whose message carries the URL

- **WHEN** the fetch rejects with `new TypeError('Load failed for https://x/?SECRET')`
- **THEN** the error reports `TypeError` and does not contain `SECRET`
