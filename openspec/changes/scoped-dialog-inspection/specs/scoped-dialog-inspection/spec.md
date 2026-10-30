## Purpose

Allow explicit native dialog inspection and dismissal within one stable Safari window without traversing unrelated windows. Preserve complete evidence and named-button safeguards within that scope.

## ADDED Requirements

### Requirement: Stable scoped inspection
Dialog list and dismiss SHALL accept a positive `--window-id`. Paired dismissal expectations SHALL select the same scope; conflicting IDs SHALL fail validation. The scanner SHALL completely enumerate bounded unique positive window IDs before traversing only the selected window. Missing, duplicate, unreadable or changed target identity SHALL remain incomplete. It SHALL NOT fall back to another window or a positional index.

#### Scenario: Unrelated window traversal fails
- **WHEN** window 42 has a complete native confirm and window 99 has unreadable descendants or an unrelated AXDialog
- **THEN** inspection scoped to 42 returns its dialog without reading window 99 descendants
- **AND** an unscoped incomplete or ambiguous scan still refuses dismissal

#### Scenario: Target identity cannot be established
- **WHEN** enumeration is truncated, an ID cannot be read, IDs are duplicated, or target 42 disappears or changes identity
- **THEN** no decision or press is authorized

### Requirement: Complete target evidence
Scoped inspection SHALL preserve native-dialog classification, WebArea exclusion, traversal limits, multiple-candidate refusal, and complete message/button details. Exhausted time or node budgets SHALL NOT authorize pressing an already discovered candidate.

#### Scenario: Target remains incomplete
- **WHEN** window 42 has one known dialog but another branch cannot be read
- **THEN** dismiss refuses without invoking a decision or AXPress

#### Scenario: Multiple dialogs in the target
- **WHEN** two native candidates exist in window 42, including nested candidates
- **THEN** scoped dismissal refuses as ambiguous

### Requirement: Scoped reporting and handoff
Listing and post-press reporting SHALL identify an explicitly selected scope. Incomplete and no-candidate diagnostics SHALL explain the native AX visibility boundary and human handoff when a visible dialog remains. They SHALL NOT recommend repeated identical inspection or replaying the page action as recovery.

#### Scenario: Visible but unexposed card
- **WHEN** Safari displays a card that the supported native AX traversal cannot identify
- **THEN** the command reports its inspection limitation and directs manual handling rather than guessing a button
