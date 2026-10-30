## MODIFIED Requirements

### Requirement: Strict command integration
Dismissal SHALL synchronously re-inspect using the complete scanner in the original scope before invoking its existing decision callback. Without an explicit stable window scope, it SHALL retain complete global scanning and uniqueness. Only a complete single candidate SHALL authorize a press. The initial observation's stable window ID SHALL be checked again before decision or press callbacks, including unscoped commands. The pressed element SHALL come from the same ordered button snapshot used to decide its index. Session state and remaining deadline SHALL be checked before AXPress. An abandoned background inspection SHALL never perform a press.

#### Scenario: The second global scan is incomplete
- **WHEN** a prior unscoped list succeeded but the unscoped dismissal scan cannot inspect another window
- **THEN** no decision or press callback is invoked and dismissal reports incomplete inspection

#### Scenario: The chosen snapshot remains valid
- **WHEN** the complete re-read matches the original window ID, expected message and ordered titles
- **THEN** the existing named-button rule selects the corresponding element from that same re-read, with existing uncertain-delivery errors preserved

#### Scenario: Identical content moves to another window
- **WHEN** the first scan finds window 42 and the second finds only window 99 with identical message and buttons
- **THEN** no decision or press callback is invoked
