# pdf-export Specification

## Purpose

Define native Safari PDF export, shared file-dialog navigation, explicit overwrite authorization and target selection.

## Requirements

### Requirement: Export page as PDF
The PDF command SHALL export through one native script to a unique private staging `.pdf` path, using the same shared navigation generator as upload. It SHALL use clipboard path entry with restoration, named enabled initial confirmation without Return fallback, and polling under one shared deadline. Upload's default navigation behavior SHALL remain unchanged.

The command SHALL observe native sheet closure and verify a complete independent PDF snapshot before atomically publishing to the effective destination. No extension SHALL resolve to `.pdf`; an explicit extension SHALL be preserved. Success SHALL identify the actual published path, not merely indicate that Save was dispatched.

Replacement of a destination entry SHALL require `--overwrite` in addition to `--allow-hid`. Existing unauthorized destinations SHALL fail before GUI interaction; late unauthorized destinations SHALL fail through atomic no-replace. Authorized publication SHALL replace the entry without following a leaf symlink; directory and special-file targets SHALL be refused. A staging replacement or other additional native confirmation SHALL always be refused, even when final-destination overwrite is authorized.

The runner SHALL retain bounded escaped action traces after the subprocess completes, including failure and timeout, and SHALL retain the pre-GUI keyboard-control warning. It SHALL NOT replay a dispatched Save, native confirmation or uncertain publication.

#### Scenario: PDF export uses clipboard for path
- **WHEN** the user authorizes PDF export
- **THEN** the staging path is pasted through the shared navigation generator with clipboard restoration

#### Scenario: PDF export uses precise waits
- **WHEN** native dialog transitions or output creation are delayed
- **THEN** they are observed under the common deadline without a fixed one-shot completion assumption

#### Scenario: Existing destination without authorization
- **WHEN** the effective destination exists and overwrite is absent
- **THEN** the command refuses before GUI interaction

#### Scenario: Destination appears after preflight
- **WHEN** the effective destination is created after preflight and overwrite is absent
- **THEN** publication refuses atomically without changing that entry

#### Scenario: Authorized replacement
- **WHEN** allow-hid and overwrite are supplied and a complete snapshot is ready
- **THEN** the command atomically replaces the validated destination entry
- **AND** Safari does not write directly to the published inode

### Requirement: PDF export command accepts full TargetOptions

The `pdf` command SHALL accept `--url <pattern>`, `--window <n>`, `--tab <n>`, and `--document <n>` targeting flags in addition to the existing `--allow-hid` requirement. When targeting flags are supplied, the system SHALL resolve the target to a physical window index via the native path resolver, switch to the target tab if needed, raise that window to the front, and dispatch the PDF file-dialog keystroke sequence against the resolved window.

The `pdf` command SHALL NOT reject `--url`, `--tab`, or `--document` at validation time.

#### Scenario: pdf --url resolves to target window

- **WHEN** Safari has two windows, one showing `https://docs.example.com/`
- **AND** user runs `safari-browser pdf --url docs --allow-hid /tmp/docs.pdf`
- **THEN** the system SHALL resolve `--url docs` to the docs window index
- **AND** SHALL raise that window
- **AND** SHALL dispatch the PDF file-dialog keystroke sequence against that window

#### Scenario: pdf --document resolves via document collection

- **WHEN** Safari has three documents across two windows
- **AND** user runs `safari-browser pdf --document 3 --allow-hid /tmp/third.pdf`
- **THEN** the system SHALL identify which window owns the third document
- **AND** SHALL raise that window and dispatch the PDF dialog

#### Scenario: pdf --url with no match

- **WHEN** Safari has no window whose URL contains `xyz`
- **AND** user runs `safari-browser pdf --url xyz --allow-hid /tmp/out.pdf`
- **THEN** the system SHALL throw `documentNotFound` before dispatching any keystroke

<!-- @trace
source: clipboard-path-input
updated: 2026-04-07
code:
-->
