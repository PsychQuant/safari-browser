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

---
### Requirement: PDF export command accepts full TargetOptions

The `pdf` command SHALL accept `--url <pattern>`, `--window <n>`, `--tab <n>`, and `--document <n>` targeting flags in addition to the existing `--allow-hid` requirement. When targeting flags are supplied, the system SHALL resolve the target through the native path resolver, after `--window <n>` was resolved to the window's id at command start (document-targeting, "Window number resolved to its id at command start"), and SHALL then run one export script that names the window `window id <id>` (document-targeting, "Window-level commands act on the window they resolved"). In its first Safari block that script SHALL, in this order: fail with no menu action sent when the window is no longer open; when the resolution names a tab, run the URL check on it when it was found by its URL and make it the window's current tab when it is not; read the URL of the window's current tab; raise the window; activate Safari. No separate AppleScript SHALL switch the tab. The checks the script makes before each later step compare the id of Safari's front window with `<id>` and the URL of its current tab with the URL read, and stop the export when either differs.

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

#### Scenario: pdf names the window by its id from the first step of the export script

- **WHEN** user runs `safari-browser pdf --allow-hid --window 2 /tmp/out.pdf` and window 2 has id 5822 when the command starts
- **THEN** the export script checks that `window id 5822` exists, reads the URL of `current tab of window id 5822`, and raises `window id 5822`
- **AND** the script does not name `window 2`

##### Example: export script by window id

Safari's windows, front to back: window 1 has id 4711 and tabs `https://home.example/1`, `https://home.example/2`, `https://home.example/3`; window 2 has id 5822 and tabs `https://work.example/a1`, `https://work.example/a2`; window 3 has id 6933 and the tab `https://work.example/b1`. Tab 1 is the current tab of each window.

| Command | First Safari block of the export script |
| --- | --- |
| `pdf --allow-hid --window 2 out.pdf` | the existence check on `window id 5822`; the URL of `current tab of window id 5822`; `set index of window id 5822 to 1`; `activate`; no statement about a tab |
| `pdf --allow-hid --url work.example/a2 out.pdf` | the existence check; the URL check on `tab 2 of window id 5822`; tab 2 is made current; then the URL read, the raise and `activate`, in that order |
| `pdf --allow-hid --url work.example/a1 out.pdf` | the existence check; the URL check on `tab 1 of window id 5822`; no tab is made current; then the URL read, the raise and `activate` |
| `pdf --allow-hid --window-id 5822 --tab-in-window 2 out.pdf` | as the first `--url` row, without the URL check |
| `pdf --allow-hid out.pdf` | unchanged: `set pdfWindowID to id of window 1` |
| `pdf --allow-hid --window 2 out.pdf`, when the script reports that window id 5822 is gone | the command fails with a document-not-found error whose pattern is `window 2 (window id 5822 at command start)` |
