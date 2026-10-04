## ADDED Requirements

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
