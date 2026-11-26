# save-pdf Specification

## Purpose

`save-pdf` saves the PDF a targeted tab is displaying to a file, using only the bytes WebKit already holds; a tab a service worker controls is read only with `--allow-service-worker`, and then the service worker can answer the read from the network. It exists for PDFs that never reached the disk cache read by `pdf-cache`, such as responses marked `Cache-Control: no-store`.

## Requirements

### Requirement: save-pdf saves the displayed PDF without a request of its own

The `safari-browser` CLI SHALL provide a `save-pdf <path>` subcommand that writes the PDF document displayed by the targeted tab to `<path>`. It SHALL obtain the bytes only through one in-page `fetch` of the document's own URL with `cache: 'only-if-cached'` and `mode: 'same-origin'`. The page script SHALL contain no other network API, and the command itself SHALL open no network connection. When that fetch fails, the command SHALL fail and SHALL NOT retry with any other cache mode, request, or dialog. An answer with a status other than 200 SHALL fail the command with nothing saved. The command saves what that fetch answers, which is what the tab holds: a server that sent part of a document gives that part, and the page check refuses most such files but not all (a PDF with incremental updates cut at an earlier revision is a complete PDF with fewer pages). It does not look at the server's status, which that answer does not show on WebKit: a PDF document answers 200 whatever the server sent, and a tab that arrived through a redirect is not refused. When a service worker controls the tab, the page script SHALL NOT call `fetch` unless `--allow-service-worker` is given, as the requirement "Only a PDF document is read, and a service worker's part is checked" states. With the flag, when WebKit does not hold the document of a tab a service worker controls, the fetch is handed to the service worker like any fetch of the page, and the service worker can answer it from the network; an error after the fetch SHALL NOT say that no request was sent without naming that exception.

#### Scenario: a no-store PDF is saved with no new request

- **WHEN** a tab displays a PDF served with `Cache-Control: no-store`
- **AND** no service worker controls the tab, or one does, `--allow-service-worker` is given and WebKit holds the document
- **AND** the user runs `safari-browser save-pdf out.pdf --url "example.org/paper.pdf"`, with `--allow-service-worker` when a service worker controls the tab
- **THEN** `out.pdf` holds the same bytes the server sent
- **AND** the server receives no request for the document during the read

##### Example: a no-store PDF in a tab no service worker controls

- **GIVEN** a tab displays a PDF served with `Cache-Control: no-store` and no service worker controls the tab
- **WHEN** `save-pdf` reads it
- **THEN** the file is byte-identical to what the server sent, the server log gains no request for the document during the read, and the read reports the verdict `none`

#### Scenario: bytes WebKit does not hold are not fetched

- **WHEN** the in-page fetch rejects on a tab no service worker controls
- **THEN** the command exits 1 with an error saying WebKit does not hold the whole document or the page's policy blocked the read, and that no request for the document was sent unless `--allow-service-worker` was given and a service worker controls the tab
- **AND** the server receives no request

#### Scenario: bytes WebKit does not hold, on a tab a service worker controls

- **WHEN** a service worker controls the tab, WebKit does not hold the document at the tab's address, and `--allow-service-worker` is given
- **THEN** the read is handed to the service worker, which can answer it from the network, and a file is written only when that answer is a PDF, with the output reporting the verdict
- **AND** without the flag the tab is not read and the service worker receives nothing

##### Example: a controlled PDF tab whose address was never loaded

- **GIVEN** a local server that logs requests, and a service worker that answers every fetch from the network and reports each fetch event to that server, controlling a PDF tab whose address was changed with `history.replaceState` to a URL in its scope that was never loaded (the server answers 404 for it)
- **WHEN** `save-pdf` reads the tab without `--allow-service-worker`, and again with it
- **THEN** the first run fails with the service-worker error and, during it, the server log gains neither the service worker's report nor a request for that URL
- **AND** during the second run the server log gains the service worker's report and a request for that URL, and the run fails with the HTTP 404 error, whose message says a service worker that controls the tab can answer from the network, and writes no file

##### Example: a controlled PDF tab whose document is not held and the service worker answers it

- **GIVEN** the same service worker, controlling a PDF tab whose address was changed with `history.replaceState` to `doc.pdf?v=2`, which WebKit never loaded and which the server answers with the PDF
- **WHEN** `save-pdf` reads the tab without `--allow-service-worker`, and again with it
- **THEN** the first run fails with the service-worker error, writes no file, and the server log gains no request for that URL during it
- **AND** during the second run the server log gains a request for that URL, and the run saves the PDF the server sent and reports the verdict `seen`

#### Scenario: an answer that is not 200

- **WHEN** the fetch answers with a status other than 200
- **THEN** the command exits 1 and no file is written

#### Scenario: a tab that arrived through a redirect

- **WHEN** a tab displays a PDF it reached through a redirect
- **THEN** the file holds the PDF the tab displays

---
### Requirement: The target tab must be named explicitly

`save-pdf` SHALL require a tab-targeting flag (`--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--window` or `--window-id`, each with optional `--tab-in-window`, `--document`, or `--tab`). Without one it SHALL fail with a usage error before contacting Safari. `--first-match` alone is not a target. It SHALL accept `--profile`. The target SHALL be resolved once at the start. From the moment the page script runs, every step SHALL be tied to that document by its slot, which exists only there: when the tab shows another document afterwards, the command SHALL fail and SHALL NOT read it. Before that moment a position names whatever is at that position and a pattern whatever matches it, as for every command, and the output names the address read. When the tab vanishes, the error SHALL name the target and SHALL NOT list other tabs.

#### Scenario: no target

- **WHEN** the user runs `safari-browser save-pdf out.pdf`
- **THEN** the command exits 64 and no AppleScript is run

#### Scenario: first-match alone is not a target

- **WHEN** the user runs `safari-browser save-pdf out.pdf --first-match`
- **THEN** the command exits 64 and no AppleScript is run

#### Scenario: the tab vanishes during the read

- **WHEN** the targeted tab is closed after the command resolved it
- **THEN** the command exits 1 with an error naming the target, and the error lists no other tab

---
### Requirement: Only a PDF document is read, and a service worker's part is checked

The page script SHALL fail with a not-a-PDF error, naming the content type, when `document.contentType` is neither `application/pdf` nor `text/pdf`, the two types WebKit displays as a PDF, and SHALL NOT call `fetch` in that case.

Before the fetch the page script SHALL record whether `navigator.serviceWorker.controller` is set. When it is set and `--allow-service-worker` is not given, the script SHALL fail with a service-worker error before calling `fetch`, and SHALL NOT call `performance`; that error SHALL name the flag and say that nothing was read and no request was sent. When no service worker controls the tab, the verdict SHALL be `none` and the script SHALL NOT call `performance` at all. When one does and the flag is given, the script SHALL read `location.href` once before the fetch and fetch that address, SHALL take `performance.now()` as the read's start before the fetch, and, after the body has been read and before its size is checked or it is encoded, SHALL look up the `PerformanceResourceTiming` entries whose `name` without its fragment equals that address without its fragment, whose `initiatorType` is `fetch`, and whose `startTime` is not earlier than the read's start. The verdict SHALL be `seen` when the largest `workerStart` among those entries is greater than 0. Otherwise it SHALL be `unconfirmed` when there is no such entry, when an entry's `workerStart` is not a number of at least 0, or when `performance.now` or `performance.getEntriesByType` is not a function or throws, and `not-seen` when there is at least one entry and every `workerStart` is 0.

With `--allow-service-worker` the bytes SHALL be kept for every verdict, and the output names the verdict. The flag SHALL NOT change the fetch, its cache mode, or the path for a tab no service worker controls. The verdict comes from the tab's own JavaScript environment: a service worker cannot change it, and a script of the same origin that tampers with the tab can. Without the flag, a success reply whose verdict is not `none` SHALL be a damaged reply, found before any byte of the result is transferred, because the page script answers that call with success only for a tab no service worker controls.

#### Scenario: an HTML page embedding a PDF

- **WHEN** the targeted tab's document has content type `text/html`
- **THEN** the command exits 1 naming that content type, and `fetch` is not called

#### Scenario: a PDF tab a service worker controls, without the flag

- **WHEN** a service worker controls the targeted PDF tab and `--allow-service-worker` is not given
- **THEN** the command exits 1 with the service-worker error, which names the flag, `fetch` is not called, and no file is written

##### Example: a controlled PDF tab without the flag

- **GIVEN** a service worker that answers every fetch from the network and reports each fetch event to a local server that logs requests controls a tab displaying a PDF served with `Cache-Control: no-store`
- **WHEN** `save-pdf` reads it without `--allow-service-worker`
- **THEN** the read fails with the service-worker error, no file is written, and during the read the server log gains no entry

#### Scenario: a PDF tab a service worker controls, with the flag

- **WHEN** a service worker controls the targeted PDF tab, `--allow-service-worker` is given, and the read's entries all have `workerStart` 0
- **THEN** the file is written and the output reports the verdict `not-seen`

##### Example: a controlled PDF tab whose read the service worker did not handle

- **GIVEN** a service worker that answers every fetch from the network controls a tab displaying a PDF served with `Cache-Control: no-store`
- **WHEN** `save-pdf` reads it with `--allow-service-worker`
- **THEN** the file is byte-identical to the served PDF, during the read the server receives no request and the service worker records no fetch event, and the read reports the verdict `not-seen`

#### Scenario: a read the service worker handled, or one that cannot be confirmed

- **WHEN** a service worker controls the tab, `--allow-service-worker` is given, and the verdict is `seen` or `unconfirmed`
- **THEN** the file is written and the output reports the verdict

##### Example: verdicts and the flag

| Service worker controls the tab | Entries for the read (`workerStart`) | `--allow-service-worker` | Result |
| --- | --- | --- | --- |
| no | not read | off | saved, verdict `none` |
| no | not read | on | saved, verdict `none` |
| yes | not read | off | exit 1, service-worker error, `fetch` not called, no file |
| yes | 0 | on | saved, verdict `not-seen` |
| yes | 0 and 12 | on | saved, verdict `seen` |
| yes | none | on | saved, verdict `unconfirmed` |

##### Example: which entries count for the read

| Entry | Counts | Why |
| --- | --- | --- |
| `name` `https://x/doc.pdf`, tab at `https://x/doc.pdf#page=2`, `initiatorType` `fetch`, started after the read's start | yes | names compare without the fragment |
| same, `initiatorType` `navigation` | no | not a fetch |
| same, started before the read's start, `workerStart` 1 | no | an earlier load, not this read |
| `name` `https://x/doc.pdf?v=2` | no | another URL |
| `name` `https://x/doc.pdf`, the tab's address changed to `https://x/other.pdf` while the read ran | yes | the address the read fetched |

##### Example: a full resource timing buffer

- **GIVEN** a service worker controls a PDF tab whose page called `performance.setResourceTimingBufferSize(0)` and `performance.clearResourceTimings()` before the read
- **WHEN** `save-pdf` reads it with `--allow-service-worker`
- **THEN** it saves the PDF and reports the verdict `unconfirmed`

##### Example: an uncontrolled tab never reads resource timing

- **GIVEN** a PDF tab no service worker controls, whose `performance.now` and `performance.getEntriesByType` throw when called
- **WHEN** `save-pdf` reads it without `--allow-service-worker`
- **THEN** the file is written with the verdict `none`

##### Example: an entry above 0 outweighs one without a number

| Entries for the read (`workerStart`) | `--allow-service-worker` | Result |
| --- | --- | --- |
| `NaN` and 12 | on | saved, verdict `seen` |
| `NaN` and 0 | on | saved, verdict `unconfirmed` |

##### Example: a verdict the call could not produce

- **GIVEN** a call made without `--allow-service-worker`
- **WHEN** the status script answers `ok:3:4:not-seen`
- **THEN** the command fails with a damaged reply and reads no chunk of the result

---
### Requirement: The transfer belongs to one call and one document

The page script SHALL park the result in a slot made for this call by `ResultSlot.make()`, and the command SHALL read it through the verified chunked read of `SafariBridge.readResultSlot`. The size and length the page reports SHALL be checked before they are used: the size SHALL NOT exceed `TabPDFReader.maxBytes`, and the length SHALL be the base64 length of that size. The decoded byte count SHALL equal the size the page reported, or the command SHALL fail. When the slot is gone (the page was replaced), the command SHALL fail with a page-replaced error. When the page reports a size above `TabPDFReader.maxBytes` (268,435,456 bytes), the command SHALL fail before encoding the bytes. When the page does not report a result within `TabPDFReader.deadlineSeconds` (60 seconds, counted from before the read is started), the command SHALL fail; a result arriving after that is not taken. The transfer back is not under this deadline. When the page script does not run, because the document is still loading or its policy forbids scripts, the command SHALL say that and not report a damaged reply. The command SHALL remove its slot when it finishes, unless the tab has stopped answering. The status script SHALL answer one of `gone`, `wait`, `ok:<bytes>:<len>:<verdict>` with `<verdict>` one of `none`, `not-seen`, `seen` and `unconfirmed`, or `fail:<code>:<detail>`; any other answer, including `ok:<bytes>:<len>` without a verdict, SHALL be a damaged reply.

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

- **WHEN** the status script answers anything other than `gone`, `wait`, `ok:<bytes>:<len>:<verdict>` with one of the four verdicts, or `fail:<code>:<detail>` with a known code
- **THEN** the command exits 1 reporting a damaged reply

##### Example: the closed status format

| Status answer | Read as |
| --- | --- |
| `ok:3:4:none` | success, 3 bytes in 4 characters, verdict `none` |
| `ok:3:4:not-seen` | success, verdict `not-seen` |
| `ok:3:4:unconfirmed` | success, verdict `unconfirmed` |
| `ok:3:4` | damaged reply |
| `ok:3:4:maybe` | damaged reply |
| `fail:service-worker:` | the service-worker error |
| `fail:sw-seen:` | damaged reply |
| `fail:sw-unconfirmed:` | damaged reply |

---
### Requirement: The file is published through the verified path

The decoded bytes SHALL be written to an owner-only file inside a private temporary folder and published with `PDFCacheOutput.copyVerified`, which requires the `%PDF-` header and readable pages, refuses an existing destination unless `--force`, and leaves no destination on failure. An existing destination, and a destination whose parent is not a folder, SHALL be refused before the bytes are transferred when that can be seen. The temporary folder SHALL be removed when the command finishes. A destination inside Safari's cache folder SHALL be refused by comparing paths. The command SHALL NOT open or list that folder or anything else in Safari's container, unless the caller names a destination inside it: without Full Disk Access that is another application's data, and touching it can raise a permission dialog.

#### Scenario: an existing destination

- **WHEN** `out.pdf` exists and `--force` is not given
- **THEN** the command fails before any in-page fetch and `out.pdf` is unchanged

#### Scenario: bytes that are not a PDF

- **WHEN** the bytes read do not start with `%PDF-`
- **THEN** the command fails with an error that does not name the temporary file, no file appears at the destination, and the temporary folder is gone

#### Scenario: no access to Safari's cache folder

- **WHEN** the process cannot read Safari's cache folder and the destination is elsewhere
- **THEN** the file is published and that folder was not opened

---
### Requirement: Output shows the URL without its secrets

On success the command SHALL print one line with the destination path, size, page count, and the tab's URL, followed by `  service worker: <verdict>` when the verdict is not `none`, or with `--json` one object with `path`, `size`, `pages`, `source` (`"tab"`), `url`, and `service_worker` (the verdict). The scripts this command writes SHALL NOT contain the address, because a script is a process argument, part of a timeout message and a daemon log entry, and the page SHALL report back only the protocol, host and path. That SHALL pass through `URLText.redactURL`, so a path parameter does not appear either. Finding the tab is outside this: a target flag's guard contains what the caller typed, and `--url` reads the tabs' URLs as every command does. A failure inside the page SHALL report the error's name and not its message, whose text is WebKit's and can carry the URL.

#### Scenario: a signed URL

- **WHEN** the tab's URL is `https://cdn.example.org/main.pdf?X-Amz-Signature=SECRET` and the target flag does not name the query
- **THEN** neither the output, nor any error message, nor any script sent to Safari contains `SECRET`

#### Scenario: a rejection whose message carries the URL

- **WHEN** the fetch rejects with `new TypeError('Load failed for https://x/?SECRET')`
- **THEN** the error reports `TypeError` and does not contain `SECRET`

#### Scenario: the verdict in the output

- **WHEN** a save succeeds
- **THEN** the text line ends with the service-worker verdict only when it is not `none`, and the JSON object always has `service_worker`

##### Example: the verdict in the text and JSON output

| Verdict | Text line ends with | JSON `service_worker` |
| --- | --- | --- |
| `none` | `from tab https://x/doc.pdf` | `"none"` |
| `not-seen` | `from tab https://x/doc.pdf  service worker: not-seen` | `"not-seen"` |
| `seen` | `from tab https://x/doc.pdf  service worker: seen` | `"seen"` |
| `unconfirmed` | `from tab https://x/doc.pdf  service worker: unconfirmed` | `"unconfirmed"` |
