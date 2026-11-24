## MODIFIED Requirements

### Requirement: save-pdf saves the displayed PDF without any request

The `safari-browser` CLI SHALL provide a `save-pdf <path>` subcommand that writes the PDF document displayed by the targeted tab to `<path>`. It SHALL obtain the bytes only through one in-page `fetch` of the document's own URL with `cache: 'only-if-cached'` and `mode: 'same-origin'`. The page script SHALL contain no other network API, and the command itself SHALL open no network connection. When that fetch fails, the command SHALL fail and SHALL NOT retry with any other cache mode, request, or dialog. An answer with a status other than 200 SHALL fail the command with nothing saved. The command saves what that fetch answers, which is what the tab holds: a server that sent part of a document gives that part, and the page check refuses most such files but not all (a PDF with incremental updates cut at an earlier revision is a complete PDF with fewer pages). It does not look at the server's status, which that answer does not show on WebKit: a PDF document answers 200 whatever the server sent, and a tab that arrived through a redirect is not refused. When a service worker controls the tab, whether that fetch reached the service worker SHALL be checked after the read, as the requirement "Only a PDF document is read, and a service worker's part is checked" states; a read the service worker handled SHALL be kept only with `--allow-service-worker`. When WebKit does not hold the document of a tab a service worker controls, the fetch is handed to the service worker like any fetch of the page, before any check and also without the flag, and the service worker can answer it from the network; an error after the fetch SHALL NOT say that no request was sent without naming that exception.

#### Scenario: a no-store PDF is saved with no new request

- **WHEN** a tab displays a PDF served with `Cache-Control: no-store`
- **AND** no service worker controls the tab, or WebKit holds the document
- **AND** the user runs `safari-browser save-pdf out.pdf --url "example.org/paper.pdf"`
- **THEN** `out.pdf` holds the same bytes the server sent
- **AND** the server receives no request for the document during the read

##### Example: a no-store PDF in a tab no service worker controls

- **GIVEN** a tab displays a PDF served with `Cache-Control: no-store` and no service worker controls the tab
- **WHEN** `save-pdf` reads it
- **THEN** the file is byte-identical to what the server sent, the server log gains no request for the document during the read, and the read reports the verdict `none`

#### Scenario: bytes WebKit does not hold are not fetched

- **WHEN** the in-page fetch rejects on a tab no service worker controls
- **THEN** the command exits 1 with an error saying WebKit does not hold the whole document or the page's policy blocked the read, and that no request for the document was sent unless a service worker controls the tab
- **AND** the server receives no request

#### Scenario: bytes WebKit does not hold, on a tab a service worker controls

- **WHEN** a service worker controls the tab and WebKit does not hold the document at the tab's address
- **THEN** the read is handed to the service worker, which can answer it from the network, and the command saves nothing it did not confirm

##### Example: a controlled PDF tab whose address was never loaded

- **GIVEN** a local server that logs requests, and a service worker that answers every fetch from the network and reports each fetch event to that server, controlling a PDF tab whose address was changed with `history.replaceState` to a URL in its scope that was never loaded (the server answers 404 for it)
- **WHEN** `save-pdf` reads the tab without `--allow-service-worker`
- **THEN** the server log gains the service worker's report and a request for that URL, the command fails with the HTTP 404 error, whose message says a service worker that controls the tab can answer from the network, and no file is written

##### Example: a controlled PDF tab whose document is not held and the service worker answers it

- **GIVEN** the same service worker, controlling a PDF tab whose address was changed with `history.replaceState` to `doc.pdf?v=2`, which WebKit never loaded and which the server answers with the PDF
- **WHEN** `save-pdf` reads the tab without `--allow-service-worker`, and again with it
- **THEN** the server log gains a request for that URL, the first run fails with the `seen` error and writes no file, and the second saves the PDF the server sent and reports the verdict `seen`

#### Scenario: an answer that is not 200

- **WHEN** the fetch answers with a status other than 200
- **THEN** the command exits 1 and no file is written

#### Scenario: a tab that arrived through a redirect

- **WHEN** a tab displays a PDF it reached through a redirect
- **THEN** the file holds the PDF the tab displays

---
### Requirement: Only a PDF document is read, and a service worker's part is checked

The page script SHALL fail with a not-a-PDF error, naming the content type, when `document.contentType` is neither `application/pdf` nor `text/pdf`, the two types WebKit displays as a PDF, and SHALL NOT call `fetch` in that case.

Before the fetch the page script SHALL record whether `navigator.serviceWorker.controller` is set. When no service worker controls the tab, the verdict SHALL be `none` and the script SHALL NOT call `performance` at all. When one does, the script SHALL take `performance.now()` as the read's start before the fetch, SHALL send the same fetch and, after the body has been read and before its size is checked or it is encoded, SHALL look up the `PerformanceResourceTiming` entries whose `name` without its fragment equals `location.href` without its fragment, whose `initiatorType` is `fetch`, and whose `startTime` is not earlier than the read's start. The verdict SHALL be `seen` when the largest `workerStart` among those entries is greater than 0. Otherwise it SHALL be `unconfirmed` when there is no such entry, when an entry's `workerStart` is not a number of at least 0, or when `performance.now` or `performance.getEntriesByType` is not a function or throws, and `not-seen` when there is at least one entry and every `workerStart` is 0.

Without `--allow-service-worker`, the verdicts `seen` and `unconfirmed` SHALL fail the command with a service-worker error that names the verdict and the flag and does not say that no request was sent; the bytes SHALL NOT be encoded or transferred, and no file SHALL be written. With `--allow-service-worker` the bytes SHALL be kept for every verdict. The flag SHALL NOT change the fetch, its cache mode, or the path for a tab no service worker controls.

#### Scenario: an HTML page embedding a PDF

- **WHEN** the targeted tab's document has content type `text/html`
- **THEN** the command exits 1 naming that content type, and `fetch` is not called

#### Scenario: a PDF tab a service worker controls, read without it

- **WHEN** a service worker controls the targeted PDF tab and the read's entries all have `workerStart` 0
- **THEN** the file is written and the output reports the verdict `not-seen`

##### Example: a controlled PDF tab whose read the service worker did not handle

- **GIVEN** a service worker that answers every fetch from the network controls a tab displaying a PDF served with `Cache-Control: no-store`
- **WHEN** `save-pdf` reads it without `--allow-service-worker`
- **THEN** the file is byte-identical to the served PDF, during the read the server receives no request and the service worker records no fetch event, and the read reports the verdict `not-seen`

#### Scenario: a read the service worker handled, or one that cannot be confirmed

- **WHEN** a service worker controls the tab and the verdict is `seen` or `unconfirmed`
- **THEN** without `--allow-service-worker` the command exits 1 with the service-worker error for that verdict, no file is written, and the bytes are not transferred
- **AND** with `--allow-service-worker` the file is written and the output reports the verdict

##### Example: verdicts and the flag

| Service worker controls the tab | Entries for the read (`workerStart`) | `--allow-service-worker` | Result |
| --- | --- | --- | --- |
| no | not read | off | saved, verdict `none` |
| yes | 0 | off | saved, verdict `not-seen` |
| yes | 0 and 12 | off | exit 1, `seen` error, no file |
| yes | 12 | on | saved, verdict `seen` |
| yes | none | off | exit 1, `unconfirmed` error, no file |
| yes | none | on | saved, verdict `unconfirmed` |

##### Example: which entries count for the read

| Entry | Counts | Why |
| --- | --- | --- |
| `name` `https://x/doc.pdf`, tab at `https://x/doc.pdf#page=2`, `initiatorType` `fetch`, started after the read's start | yes | names compare without the fragment |
| same, `initiatorType` `navigation` | no | not a fetch |
| same, started before the read's start, `workerStart` 1 | no | an earlier load, not this read |
| `name` `https://x/doc.pdf?v=2` | no | another URL |

##### Example: a full resource timing buffer

- **GIVEN** a service worker controls a PDF tab whose page called `performance.setResourceTimingBufferSize(0)` and `performance.clearResourceTimings()` before the read
- **WHEN** `save-pdf` reads it without `--allow-service-worker`, and again with it
- **THEN** the first run exits 1 with the `unconfirmed` error and writes no file, and the second saves the PDF and reports the verdict `unconfirmed`

##### Example: an uncontrolled tab never reads resource timing

- **GIVEN** a PDF tab no service worker controls, whose `performance.now` and `performance.getEntriesByType` throw when called
- **WHEN** `save-pdf` reads it without `--allow-service-worker`
- **THEN** the file is written with the verdict `none`

##### Example: an entry above 0 outweighs one without a number

| Entries for the read (`workerStart`) | `--allow-service-worker` | Result |
| --- | --- | --- |
| `NaN` and 12 | on | saved, verdict `seen` |
| `NaN` and 0 | on | saved, verdict `unconfirmed` |
| `NaN` and 12 | off | exit 1, `seen` error, no file |
