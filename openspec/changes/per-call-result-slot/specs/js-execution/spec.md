## ADDED Requirements

### Requirement: Per-call result slot

A result that is not returned inline, whether from `js --large`, `js --output`, a `js` result over the inline limit, `get text`, `get html`, `snapshot`, or an `exec` step, SHALL be parked in the page in a slot named for that call alone and read back from it. Two calls on one page SHALL NOT read each other's result. A slot a call made SHALL be removed when the call ends, whether it succeeded, found nothing, or failed, and SHALL be the only thing that call removes.

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

#### Scenario: A slot name that is not the expected shape
- **WHEN** an inline wrapper's reply names a slot with anything other than `__sbr_` followed by 8 to 64 characters of `[0-9a-z]`
- **THEN** the CLI SHALL NOT use the name in any script
- **AND** SHALL report an error without running the code again

### Requirement: Checked chunk transfer

Each chunk of a result read from a slot SHALL carry the position at which it ends and SHALL end in a marker that is not whitespace. The CLI SHALL accept a chunk only if the reply has that shape, the position is within the range expected, and the text has exactly the announced number of UTF-16 units. Anything else SHALL be an error, never a shorter result.

#### Scenario: The slot is gone
- **WHEN** the page navigates, or the slot is removed, between two chunk reads
- **THEN** the command SHALL fail with a message that the transfer was incomplete and that the code was not run again
- **AND** SHALL NOT print the chunks read so far as the result

#### Scenario: A chunk boundary falls between the halves of a surrogate pair
- **WHEN** a chunk would end between a high and a low surrogate
- **THEN** it SHALL end one unit earlier and the next chunk SHALL start at the pair
- **AND** the result SHALL contain the character intact

#### Scenario: Whitespace at the end of a chunk
- **WHEN** a chunk ends in spaces or newlines
- **THEN** they SHALL be part of the result, whether the answer travels through `osascript` or through the daemon

#### Scenario: The result's last newline
- **WHEN** a large result ends in one newline
- **THEN** the printed output SHALL equal what it was before this requirement: that newline is not part of the output

#### Scenario: A lone surrogate
- **WHEN** a result contains an unpaired UTF-16 surrogate
- **THEN** it SHALL be replaced by U+FFFD before the result is stored
- **AND** the command SHALL NOT fail for it

#### Scenario: A frame whose text is not the announced length
- **WHEN** a reply's text has a different number of UTF-16 units than its position announces
- **THEN** the command SHALL fail
