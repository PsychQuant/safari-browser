## MODIFIED Requirements

### Requirement: Per-call result slot

A result that is not returned inline, whether from `js --large`, `js --output`, a `js` result over the inline limit, `get text`, `get html`, `snapshot`, or an `exec` step, SHALL be parked in the page in a slot named for that call alone and read back from it. Two calls on one page SHALL NOT read each other's result. When the call ends, whether it succeeded, found nothing, or failed, it SHALL try to remove the slot it made. The removal is best effort: a failed removal SHALL NOT change what the call reports, and none is tried after a timeout. The call SHALL remove nothing it did not make, except an abandoned slot as described below.

A slot SHALL carry the time of its last use as a number of milliseconds in a property `u`, written when the slot is made and rewritten by every read of it (its length, its recorded error, its progress, each chunk). A call that makes a slot SHALL, in the same script and without an extra round trip, remove every property of `window` whose name starts with `__sbr_`, whose value is an object, and whose `u` is a finite number older than 600000 milliseconds before the time the page's `Date.now` reports. A page whose `Date.now` throws or answers anything but a finite number SHALL make the call remove nothing and stamp nothing. Nothing else SHALL be removed: a slot without `u`, a `u` that is not a number, and a property whose name does not start with `__sbr_` SHALL be left alone. The reclaiming is bounded, not guaranteed: it happens when a later call makes a slot, not on a timer, so abandoned slots stay until then or until the page is left. It also depends on the page's clock: a slot SHALL be treated as unused when the page's clock says so, so a clock moved forward by more than 600000 milliseconds, or a call that stalls that long between two of its round trips, lets another call remove a slot that is still in use.

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
- **THEN** the slot SHALL stay in the page
- **AND** the next call that makes a slot, once the abandoned slot has not been used for more than 600000 milliseconds, SHALL remove it

#### Scenario: An abandoned slot that is still young
- **GIVEN** a slot whose last use was less than 600000 milliseconds ago
- **WHEN** another call makes a slot
- **THEN** the young slot SHALL remain

#### Scenario: A long read keeps its slot
- **GIVEN** a call that reads a slot in many chunks over more than 600000 milliseconds of page time, each read less than 600000 milliseconds after the one before
- **WHEN** another call makes a slot during that time
- **THEN** the slot being read SHALL remain and the read SHALL return the whole result

#### Scenario: Two calls at the same moment
- **GIVEN** call A has made a slot and call B makes its slot a moment later
- **WHEN** B reclaims abandoned slots
- **THEN** A's slot SHALL remain

#### Scenario: Slots and properties that are not abandoned slots of this version
- **WHEN** a call reclaims abandoned slots in a page that has a slot without `u`, a slot whose `u` is not a number, and a property `other_x` with an old numeric `u`
- **THEN** none of the three SHALL be removed

#### Scenario: A page whose clock cannot be read
- **WHEN** the page's `Date.now` throws, or returns something that is not a finite number (a string, `NaN`, `Infinity`, `null`)
- **THEN** the call SHALL complete as usual
- **AND** no slot SHALL be removed because of it
- **AND** a slot made under that clock SHALL carry no stamp, so it is never reclaimed

#### Scenario: A clock that stands still or runs behind
- **WHEN** the page's `Date.now` is replaced by a constant that is not later than the stamps of the slots in the page
- **THEN** no slot SHALL be removed because of it

#### Scenario: A clock that moves forward
- **GIVEN** a slot stamped at one time, and a page whose `Date.now` then reports a time more than 600000 milliseconds later (fake timers, a constant set in the future, a system clock that jumped)
- **WHEN** another call makes a slot
- **THEN** the slot SHALL be removed even if its call is still reading it
- **AND** that call SHALL report an incomplete transfer or that the page was replaced, and SHALL NOT run the code again

#### Scenario: A call that stalls beyond the retention
- **GIVEN** a call that has made its slot and does not make its next round trip for more than 600000 milliseconds of page time
- **WHEN** another call makes a slot in that time
- **THEN** the slot SHALL be removed
- **AND** `js` in any of its paths, and a chunk read of any call, SHALL report an incomplete transfer or that the page was replaced
- **AND** `get text`, `get html`, `snapshot` and `exec`, whose own slot is gone between the store and the length read, SHALL behave as when the page was replaced at that moment: an empty result and exit status 0

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
