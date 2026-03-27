# storage-management Specification

## Purpose

TBD - created by archiving change 'phase2-advanced-features'. Update Purpose after archive.

## Requirements

### Requirement: Get cookies

The system SHALL print all cookies or a specific cookie's value via `document.cookie`.

#### Scenario: Get all cookies

- **WHEN** user runs `safari-browser cookies get`
- **THEN** stdout contains the raw cookie string

#### Scenario: Get specific cookie

- **WHEN** user runs `safari-browser cookies get "session_id"`
- **THEN** stdout contains the value of the `session_id` cookie, or empty if not found

---
### Requirement: Set cookie

The system SHALL set a cookie via `document.cookie = "name=value"`.

#### Scenario: Set a cookie

- **WHEN** user runs `safari-browser cookies set "theme" "dark"`
- **THEN** the cookie `theme=dark` is set for the current domain

---
### Requirement: Clear cookies

The system SHALL clear all cookies for the current domain by setting each cookie's expiry to the past.

#### Scenario: Clear all cookies

- **WHEN** user runs `safari-browser cookies clear`
- **THEN** all cookies for the current domain are expired

---
### Requirement: Get localStorage value

The system SHALL print the value of a localStorage key.

#### Scenario: Get localStorage item

- **WHEN** user runs `safari-browser storage local get "tokenstr"`
- **THEN** stdout contains the stored value

---
### Requirement: Set localStorage value

The system SHALL set a localStorage key to the given value.

#### Scenario: Set localStorage item

- **WHEN** user runs `safari-browser storage local set "key" "value"`
- **THEN** localStorage item `key` is set to `value`

---
### Requirement: Remove localStorage value

The system SHALL remove a localStorage key.

#### Scenario: Remove localStorage item

- **WHEN** user runs `safari-browser storage local remove "key"`
- **THEN** the localStorage item `key` is removed

---
### Requirement: Clear localStorage

The system SHALL clear all localStorage data.

#### Scenario: Clear all localStorage

- **WHEN** user runs `safari-browser storage local clear`
- **THEN** all localStorage items are removed

---
### Requirement: sessionStorage operations

The system SHALL support the same get/set/remove/clear operations for sessionStorage.

#### Scenario: Get sessionStorage item

- **WHEN** user runs `safari-browser storage session get "key"`
- **THEN** stdout contains the sessionStorage value
