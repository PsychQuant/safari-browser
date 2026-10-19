## MODIFIED Requirements

### Requirement: Tab bar as ground truth

All target-resolution subcommands SHALL observe Safari's tab state through the same abstraction a human observes through the Safari window chrome: every tab in every window is individually addressable, and no tab is hidden from enumeration. The CLI SHALL NOT expose any abstraction where a background tab within a window is invisible to one subcommand while visible to another.

In practice, this means target resolution SHALL be implemented against the `tabs of windows` AppleScript collection (which enumerates every tab), not against the `documents` collection (which exposes only the front tab of each window).

#### Scenario: documents subcommand sees all tabs

- **WHEN** Safari has one window containing two tabs (`https://a.example/` at index 1, `https://b.example/` at index 2, with `b` being the current tab)
- **AND** user runs `safari-browser documents`
- **THEN** stdout SHALL contain two lines, one per tab, including the background tab `https://a.example/`
- **AND** the output SHALL NOT omit any tab that is reachable via the Safari GUI

#### Scenario: Cross-subcommand tab enumeration is consistent

- **WHEN** Safari has N tabs total across all windows
- **AND** user queries the same tab state via `safari-browser documents` and via a targeted subcommand's resolver error listing that is not scoped and enumerates tabs (the URL-miss listing of `documentNotFound`, for example)
- **THEN** both enumerations SHALL list the same N tabs, in the same order
- **AND** no tab SHALL be present in one listing and absent in the other
- **AND** a listing that names fewer tabs — scoped by its cause (a miss on one window's tab lists that window's tabs; a window-level listing names each window's current tab) or narrowed by `--profile` — SHALL list only tabs that `safari-browser documents` lists, with the same window and tab numbers
- **AND** the listings differ from `documents` in how a URL is shown (shortened in the error listing; see `document-targeting`) and in how an entry is labelled
