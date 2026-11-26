## RENAMED Requirements

FROM: ### Requirement: save-pdf saves the displayed PDF without any request
TO: ### Requirement: save-pdf saves the displayed PDF without a request of its own

## MODIFIED Requirements

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
