# js-execution Specification

## Purpose

TBD - created by archiving change 'phase1-core-cli'. Update Purpose after archive.

## Requirements

### Requirement: Execute inline JavaScript

The system SHALL execute a JavaScript string in the target Safari document using AppleScript `do JavaScript ... in <document reference>` and print the result to stdout. The default target SHALL be `document 1`. Global targeting flags (`--url`, `--window`, `--tab`, `--document`) SHALL redirect JavaScript execution to the resolved document. Execution SHALL use document-scoped AppleScript reference so modal file dialog sheets on the front window do NOT block the query.

#### Scenario: Simple JS expression with default target

- **WHEN** user runs `safari-browser js "document.title"`
- **THEN** stdout contains the page title of `document 1` as a string

#### Scenario: JS returning object

- **WHEN** user runs `safari-browser js "JSON.stringify({a:1})"`
- **THEN** stdout contains `{"a":1}`

#### Scenario: JS in targeted document by URL

- **WHEN** Safari has two documents and user runs `safari-browser js --url plaud "window.location.href"`
- **THEN** stdout contains the URL of the document whose URL contains `plaud`
- **AND** SHALL NOT return the URL of any other document

#### Scenario: JS in targeted document by window

- **WHEN** user runs `safari-browser js --window 2 "document.title"`
- **THEN** stdout contains the title of the document belonging to window 2

#### Scenario: JS execution error in targeted document

- **WHEN** user runs `safari-browser js --url plaud "undefinedVar.prop"`
- **AND** the matched document evaluates the script and raises a reference error
- **THEN** the CLI exits with non-zero status and stderr contains the JavaScript error message
- **AND** SHALL NOT leak errors from any other document

#### Scenario: JS while front window has modal sheet

- **WHEN** Safari's front window has an open modal file dialog sheet
- **AND** user runs `safari-browser js "1+1"`
- **THEN** the command SHALL return `2` within the default process timeout
- **AND** SHALL NOT hang


<!-- @trace
source: multi-document-targeting
updated: 2026-04-13
code:
-->

---
### Requirement: Execute JavaScript from file

The system SHALL read a JavaScript file and execute its contents in the target document when `--file` flag is provided. Target resolution rules SHALL be identical to `js <code>` — the default target is `document 1`, and global targeting flags redirect to the resolved document.

#### Scenario: Execute from file with default target

- **WHEN** user runs `safari-browser js --file script.js` where `script.js` contains `document.title`
- **THEN** stdout contains the title of `document 1`

#### Scenario: Execute from file in targeted document

- **WHEN** user runs `safari-browser js --file script.js --url plaud`
- **THEN** the script runs against the document whose URL contains `plaud`

#### Scenario: File not found

- **WHEN** user runs `safari-browser js --file nonexistent.js`
- **THEN** the CLI exits with non-zero status and stderr contains a file-not-found error

<!-- @trace
source: multi-document-targeting
updated: 2026-04-13
code:
-->

---
### Requirement: Per-call result slot

A result that is not returned inline, whether from `js --large`, `js --output`, a `js` result over the inline limit, `get text`, `get html`, `snapshot`, or an `exec` step, SHALL be parked in the page in a slot named for that call alone and read back from it. Two calls on one page SHALL NOT read each other's result. When the call ends, whether it succeeded, found nothing, or failed, it SHALL try to remove the slot it made. The removal is best effort: a failed removal SHALL NOT change what the call reports, and none is tried after a timeout. The call SHALL remove nothing it did not make.

#### Scenario: Another call stores in the middle of a read
- **GIVEN** call A has stored its result and is reading it back in chunks
- **WHEN** call B stores a different result in the same page before A's second chunk is read
- **THEN** A SHALL return its own result

#### Scenario: Two large results from the inline path
- **WHEN** two `js` calls on one page each produce a result over the inline limit
- **THEN** each SHALL be parked under a different name
- **AND** each call SHALL read only its own

#### Scenario: Nothing is left behind
- **WHEN** a large read succeeds, returns an empty result, or fails
- **THEN** the page SHALL hold no slot that call made
- **AND** the only property a call leaves on `window` SHALL be the counter `__sbn`, and only when it named a slot itself

#### Scenario: A timeout
- **WHEN** a step of a large read times out
- **THEN** the command SHALL report the timeout
- **AND** SHALL NOT make another round trip to remove the slot, because the page's main thread is busy and the removal would wait out a timeout of its own

#### Scenario: A call that is killed
- **WHEN** the process is killed, or a call is cancelled, before it removes its slot
- **THEN** the slot stays in the page until the page is left; this is known and tracked in #193

#### Scenario: The wrappers do not hide page globals
- **GIVEN** a page with globals named `s`, `r` and `k`
- **WHEN** the code of `js --large`, of a `js` whose result is parked in a slot, or of the fallback of `get text` reads them
- **THEN** it SHALL read the page's values, because the forms of this change declare no variable in the scope of the user's code
- **AND** the inline wrappers of #255 declare `r` and `m` and still hide page globals of those names (not changed here)

#### Scenario: A page that stubs its clock or random source
- **WHEN** the page's `Date.now` and `Math.random` are replaced by constants, or its counter `__sbn` is set to a negative or non-numeric value
- **THEN** a result parked by the inline wrapper SHALL still be named uniquely and in the accepted shape

#### Scenario: A slot name that is not the expected shape
- **WHEN** an inline wrapper's reply names a slot with anything other than `__sbr_` followed by 8 to 64 characters of `[0-9a-z]`
- **THEN** the CLI SHALL NOT use the name in any script
- **AND** SHALL report an error without running the code again

---
### Requirement: Checked chunk transfer

Each chunk of a result read from a slot SHALL carry the position at which it ends and SHALL end in a marker that is not whitespace. The CLI SHALL accept a chunk only if the reply has that shape, the position lies after the chunk's start and not beyond the announced total, and the text has exactly the announced number of UTF-16 units. Anything else SHALL be an error, never a shorter result.

#### Scenario: The slot is gone
- **WHEN** the slot is removed or replaced between the length read and a chunk read, and the tab's URL is the one it had before the code ran
- **THEN** the command SHALL fail with a message that the transfer was incomplete and that the code was not run again
- **AND** SHALL NOT print the chunks read so far as the result

#### Scenario: The page was left
- **WHEN** the slot is gone because the code navigated the page, so the tab's URL is not the one it had before
- **THEN** the command SHALL report the navigation on stderr and succeed without a value, as it does for every other navigation (#82)
- **AND** a target chosen with `--url` whose pattern the new page no longer matches is reported by the identity guard (#79) as before this change

#### Scenario: A chunk boundary falls between the halves of a surrogate pair
- **WHEN** a chunk would end between a high and a low surrogate
- **THEN** it SHALL end one unit earlier and the next chunk SHALL start at the pair
- **AND** the result SHALL contain the character intact

#### Scenario: Whitespace at the edge of a chunk
- **WHEN** a chunk starts or ends in spaces or newlines
- **THEN** they SHALL be part of the result, whether the answer travels through `osascript` or through the daemon

#### Scenario: The result's last newline
- **WHEN** a large result ends in one newline
- **THEN** the printed output SHALL equal what the stateless path printed before this requirement: that newline is not part of the output

#### Scenario: A lone surrogate
- **WHEN** a result contains an unpaired UTF-16 surrogate
- **THEN** it SHALL be replaced by U+FFFD before the result is stored
- **AND** the command SHALL NOT fail for it

#### Scenario: A frame whose text is not the announced length
- **WHEN** a reply's text has a different number of UTF-16 units than its position announces
- **THEN** the command SHALL fail

---
### Requirement: --output keeps its file when there is no result

`js --output <file>` SHALL write the file only when there is a result to write. When the code navigated the page away, so that there is none, the command SHALL fail, name the file in its message, and leave the file as it was.

#### Scenario: The code navigates and the file already exists
- **GIVEN** `<file>` holds earlier content
- **WHEN** `js --output <file>` runs code that navigates the page
- **THEN** the command SHALL exit non-zero after reporting the navigation
- **AND** `<file>` SHALL still hold the earlier content (before this requirement it was truncated to zero bytes and the command exited 0)

#### Scenario: The code navigates and nothing is written to the screen either
- **WHEN** `js --large` (without `--output`) runs code that navigates the page
- **THEN** the command SHALL report the navigation and exit 0 with no value, as before

---
### Requirement: Execution evidence for the code `--large` and `--output` run

For `js --large` and `js --output`, the slot SHALL also say whether the user's code started. The wrapper SHALL mark the slot before it evaluates the code and SHALL mark only a slot that exists. Whether to try the other form, and whether to run anything again, SHALL be decided from the slot (not marked; marked; gone), never from the absence of a result.

#### Scenario: The expression form does not parse
- **WHEN** the code is a statement and the expression form of the wrapper does not parse
- **THEN** the slot SHALL still be there and unmarked
- **AND** the statement form SHALL be tried, and the code SHALL run once

#### Scenario: Neither form parses
- **WHEN** the slot is unmarked after both forms
- **THEN** the command SHALL report a syntax error and the code SHALL NOT have run

#### Scenario: The page is replaced by a reload of the same address
- **WHEN** the code started and the page was replaced, so the slot is gone, and the tab's address is the one it had before the code ran
- **THEN** the command SHALL fail with a message that it cannot be known whether the code ran and that it was not run again
- **AND** SHALL NOT try the other form
- **AND** `--output` SHALL leave its file as it was

#### Scenario: The page is replaced by a navigation
- **WHEN** the slot is gone and the tab's address is not the one it had before
- **THEN** the command SHALL report the navigation and succeed without a value (#82)

#### Scenario: What was thrown, whatever it is
- **WHEN** the code throws a string, `null`, `undefined`, a number, a symbol, an object without `message`, an object without a prototype, or an `Error`
- **THEN** the command SHALL fail with `JavaScript error: <text>`, the same text the plain path reports
- **AND** an error whose message is empty SHALL still be an error
- **AND** the code SHALL have run once

#### Scenario: An answer that is not understood
- **WHEN** the read of how far the call got comes back empty, lost, with a tail that is neither `undefined` nor a length, or in a form the CLI does not know
- **THEN** it SHALL be treated as a page that was replaced, and the code SHALL NOT be run again
- **AND** only the exact answer for a slot that is there and unmarked SHALL let the other form be sent

#### Scenario: A message that cannot be read back
- **WHEN** the code throws and the message is too long to read in one answer, starts with a combining mark, or cannot be turned into text
- **THEN** the message SHALL be cut, read by Unicode scalar, or replaced by a fixed text, so that it is reported
- **AND** if it still cannot be read, the command SHALL fail saying that the code threw and what it threw could not be read back, never exit 0 with an empty result

#### Scenario: A result that was recorded and not read back
- **WHEN** the slot holds a result of two or more units and nothing came back (a read was lost)
- **THEN** the command SHALL fail with a transfer-incomplete message and SHALL NOT print nothing and exit 0

#### Scenario: A result that is one newline
- **WHEN** the code returns exactly one newline
- **THEN** the command SHALL succeed and print nothing, as the one newline the output has always lost

#### Scenario: Only the form that compiles is sent
- **WHEN** the code compiles as exactly one of the two forms in the command's own JavaScript engine
- **THEN** only that form SHALL be sent
- **AND** when neither compiles there, or the code is longer than 1,000,000 units, both SHALL be tried, expression first, the second only if the slot shows the first never started

#### Scenario: A read that fails
- **WHEN** the read of the length, the error or the progress fails or times out
- **THEN** the command SHALL fail with that error and SHALL NOT run the code again

#### Scenario: Code that throws and then navigates
- **WHEN** the code throws and the page is replaced at another address before the error is read
- **THEN** the command SHALL report the navigation and succeed without a value (the error went with the old document)

#### Scenario: Started, no result, no error
- **WHEN** the slot is marked, holds no result and no error
- **THEN** the command SHALL fail and SHALL NOT run the code again
