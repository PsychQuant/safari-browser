## Purpose

`save-pdf` saves the PDF a targeted tab is displaying to a file, using only the bytes WebKit already holds. It exists for PDFs that never reached the disk cache read by `pdf-cache`, such as responses marked `Cache-Control: no-store`.

## ADDED Requirements

### Requirement: save-pdf saves the displayed PDF without any request

The `safari-browser` CLI SHALL provide a `save-pdf <path>` subcommand that writes the PDF document displayed by the targeted tab to `<path>`. It SHALL obtain the bytes only through one in-page `fetch` of the document's own URL with `cache: 'only-if-cached'` and `mode: 'same-origin'`. The page script SHALL contain no other network API, and the command itself SHALL open no network connection. When that fetch fails, the command SHALL fail and SHALL NOT retry with any other cache mode, request, or dialog.

#### Scenario: a no-store PDF is saved with no new request

- **WHEN** a tab displays a PDF served with `Cache-Control: no-store`
- **AND** the user runs `safari-browser save-pdf out.pdf --url "example.org/paper.pdf"`
- **THEN** `out.pdf` holds the same bytes the server sent
- **AND** the server receives no request after the one that displayed the PDF

#### Scenario: bytes WebKit does not hold are not fetched

- **WHEN** the in-page fetch rejects
- **THEN** the command exits 1 with an error saying WebKit no longer holds the document or the page's policy blocked the read, and that nothing was requested
- **AND** the server receives no request

### Requirement: The target tab must be named explicitly

`save-pdf` SHALL require a tab-targeting flag (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--window` with optional `--tab-in-window`, `--document`, or `--tab`). Without one it SHALL fail with a usage error before contacting Safari. `--first-match` alone is not a target. It SHALL accept `--profile`. The target SHALL be resolved once at the start and every later step SHALL address that same tab; when the tab changes, the command SHALL fail and SHALL NOT read another tab.

#### Scenario: no target

- **WHEN** the user runs `safari-browser save-pdf out.pdf`
- **THEN** the command exits 64 and no AppleScript is run

#### Scenario: first-match alone is not a target

- **WHEN** the user runs `safari-browser save-pdf out.pdf --first-match`
- **THEN** the command exits 64 and no AppleScript is run

### Requirement: Only a PDF document outside a service worker is read

The page script SHALL fail with a not-a-PDF error, naming the content type, when `document.contentType` is not `application/pdf`. It SHALL fail with a service-worker error when `navigator.serviceWorker.controller` is set, because a service worker's answer can come from the network. Neither case SHALL call `fetch`.

#### Scenario: an HTML page embedding a PDF

- **WHEN** the targeted tab's document has content type `text/html`
- **THEN** the command exits 1 naming that content type, and `fetch` is not called

#### Scenario: a page controlled by a service worker

- **WHEN** `navigator.serviceWorker.controller` is set in the targeted tab
- **THEN** the command exits 1 with the service-worker error, and `fetch` is not called

### Requirement: The transfer belongs to one call and one document

The page script SHALL park the result in a slot made for this call by `ResultSlot.make()`, and the command SHALL read it through the verified chunked read of `SafariBridge.readResultSlot`. The decoded byte count SHALL equal the size the page reported, or the command SHALL fail. When the slot is gone (the page was replaced), the command SHALL fail with a page-replaced error. When the page reports a size above `TabPDFReader.maxBytes` (268,435,456 bytes), the command SHALL fail before encoding the bytes. When the page does not finish within `TabPDFReader.deadlineSeconds` (60 seconds), the command SHALL fail. The command SHALL remove its slot when it finishes, except after a timeout.

#### Scenario: the page is replaced during the read

- **WHEN** the slot disappears after the page reported success and before the last chunk is read
- **THEN** the command exits 1, no file is written at the destination, and no temporary file remains

#### Scenario: two calls on one page

- **WHEN** two `save-pdf` calls run on the same tab at the same time
- **THEN** each reads its own slot and each file holds the complete document

#### Scenario: a reply outside the closed format

- **WHEN** the status script answers anything other than `gone`, `wait`, `ok:<bytes>:<len>` or `fail:<code>:<detail>`
- **THEN** the command exits 1 reporting a damaged reply

### Requirement: The file is published through the verified path

The decoded bytes SHALL be written to an owner-only file inside a private temporary folder and published with `PDFCacheOutput.copyVerified`, which requires the `%PDF-` header and readable pages, refuses an existing destination unless `--force`, and leaves no destination on failure. An existing destination SHALL be refused before the bytes are transferred when `--force` is not given. The temporary folder SHALL be removed when the command finishes.

#### Scenario: an existing destination

- **WHEN** `out.pdf` exists and `--force` is not given
- **THEN** the command fails before any in-page fetch and `out.pdf` is unchanged

#### Scenario: bytes that are not a PDF

- **WHEN** the bytes read do not start with `%PDF-`
- **THEN** the command fails, no file appears at the destination, and the temporary folder is gone

### Requirement: Output shows the URL without its query

On success the command SHALL print one line with the destination path, size, page count, and the tab's URL, or with `--json` one object with `path`, `size`, `pages`, `source` (`"tab"`), and `url`. Every URL in output and in error messages SHALL pass through `PDFCacheURL.redact`, so a signed query string never appears.

#### Scenario: a signed URL

- **WHEN** the tab's URL is `https://cdn.example.org/main.pdf?X-Amz-Signature=SECRET`
- **THEN** neither the output nor any error message contains `SECRET`

### Requirement: pdf-cache names save-pdf when a tab has no cached copy

When `pdf-cache get` with a tab flag finds no cached record, its error SHALL add a line naming `safari-browser save-pdf`. `pdf-cache` SHALL NOT call it or read the tab's bytes.

#### Scenario: no cached record for the tab

- **WHEN** `pdf-cache get out.pdf --url "example.org/a.pdf"` finds no matching record
- **THEN** the error names `save-pdf`, and no JavaScript is evaluated
