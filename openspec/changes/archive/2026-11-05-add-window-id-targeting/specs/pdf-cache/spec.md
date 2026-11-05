## MODIFIED Requirements

### Requirement: Retrieval requires an explicit selection

`pdf-cache get` SHALL act only on a selection the caller states. The selection forms are a closed list of three; no other input SHALL be treated as a selection, and none SHALL be inferred from similarity to these:

1. a tab-targeting flag: `--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--window` or `--window-id` (each with or without `--tab-in-window`), `--document`, or `--tab`;
2. `--key <prefix>`;
3. `--source webkit-pdfs --file <name>`.

When no selection is given, the command SHALL fail before reading the cache and before creating any file. When more than one selection form is given, the command SHALL fail with a usage error. `--first-match` alone is not a selection. `pdf-cache get` SHALL refuse `--profile` with a usage error: it reads the default profile's network cache only, a named profile keeps its own store that is not read, and matching a named profile's tab URL against the default store could copy the default profile's version of the same URL. `pdf-cache list` SHALL say, when it finds nothing, that it read the default profile's network cache. The command SHALL NOT choose the newest, the largest, or the only PDF on the caller's behalf.

#### Scenario: nothing selected

- **WHEN** `safari-browser pdf-cache get out.pdf` runs with no selection flag
- **THEN** the command fails naming the three selection forms
- **AND** `out.pdf` does not exist afterwards and the cache was not read

#### Scenario: a profile is refused

- **WHEN** `safari-browser pdf-cache get out.pdf --profile Work` runs, with or without a selection
- **THEN** the command fails with a usage error that says only the default profile's cache is read, before any read

The flag is the only way the command is told about a profile. A tab chosen with `--url`, `--window`, `--window-id`, `--tab` or `--document` can still belong to a named profile; the command does not identify the profile of the tab it resolved, so that tab's URL is looked up in the default profile's cache (#243).

#### Scenario: two selection forms

- **WHEN** `safari-browser pdf-cache get out.pdf --url plaud --key 0123abcd` runs
- **THEN** the command fails with a usage error before any read

#### Scenario: only one PDF is cached

- **WHEN** the cache holds exactly one PDF and `pdf-cache get out.pdf` runs with no selection
- **THEN** the command still fails; it does not select that PDF
