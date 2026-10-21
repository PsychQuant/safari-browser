## ADDED Requirements

### Requirement: JSON output for local data query commands

The system SHALL output results as a JSON array when the `--json` flag is provided to `history`, `bookmarks`, `cloud-tabs`, or `downloads`. When a command produces no results, `--json` SHALL emit `[]` rather than an empty stdout.

Timestamps in JSON output SHALL be formatted as ISO 8601 strings including a time zone offset.

The `downloads` command's `date` key MAY be `null`: `Downloads.plist` entries are not
guaranteed to carry `DownloadEntryDateAddedKey`, and dropping an otherwise-valid download
record because it lacks a date would lose data the user asked for. Every other timestamp
key is non-null.

Each command emits objects with the following keys:

| Command | Keys |
|---|---|
| `history` | `url`, `title`, `visit_time`, `visit_count` |
| `bookmarks` | `folder`, `title`, `url`, `reading_list` |
| `cloud-tabs` | `device`, `title`, `url` |
| `downloads` | `filename`, `source_url`, `date` |

#### Scenario: History with --json

- **WHEN** a user runs `safari-browser history --limit 2 --json`
- **THEN** stdout contains a JSON array like `[{"url":"https://example.com/","title":"Example","visit_time":"2026-08-17T10:03:43+08:00","visit_count":3}, ...]`

#### Scenario: Bookmarks with --json marks Reading List entries

- **WHEN** a user runs `safari-browser bookmarks --json`
- **THEN** entries originating from the Reading List carry `"reading_list": true` and ordinary bookmarks carry `"reading_list": false`

#### Scenario: A download without a recorded date emits null

- **GIVEN** a `Downloads.plist` entry that carries no `DownloadEntryDateAddedKey`
- **WHEN** a user runs `safari-browser downloads --json`
- **THEN** that entry appears with `"date": null` rather than being omitted

#### Scenario: Empty result emits an empty array

- **WHEN** a user runs `safari-browser history --search zzzzznomatchzzzzz --json`
- **THEN** stdout contains exactly `[]`

#### Scenario: Missing source file emits an empty array

- **GIVEN** `~/Library/Safari/CloudTabs.db` does not exist
- **WHEN** a user runs `safari-browser cloud-tabs --json`
- **THEN** stdout contains exactly `[]`, stderr explains the file is absent, and the exit code is 0

---

### Requirement: Explanatory text is separated from parseable output

For the local data query commands, the system SHALL write explanatory text — column legends, absent-file notices, and permission guidance — to stderr, and SHALL write only parseable data rows to stdout.

This applies in both default and `--json` modes, so that `safari-browser history 2>/dev/null` yields output that can be parsed directly without stripping decoration.

#### Scenario: Legend does not contaminate stdout

- **WHEN** a user runs `safari-browser history --limit 3 2>/dev/null`
- **THEN** stdout contains only the three data rows, with no legend, heading, or notice text

#### Scenario: Absent-file notice does not contaminate JSON

- **GIVEN** `~/Library/Safari/CloudTabs.db` does not exist
- **WHEN** a user runs `safari-browser cloud-tabs --json 2>/dev/null`
- **THEN** stdout contains exactly `[]` and parses as valid JSON
