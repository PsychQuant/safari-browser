## ADDED Requirements

### Requirement: Cached-PDF commands are non-interfering and send no request

`pdf-cache list` and `pdf-cache get` SHALL be classified as **Non-interfering**. They read files from disk read-only and write only the destination file the caller named. They do not control input devices, display system dialogs, produce sound, steal window focus, or require Safari to be running. `get` with a tab-targeting flag performs one passive read of the target tab's URL through the existing target resolution.

They SHALL NOT send any network request from the user's machine to a publisher or any other host. This is the reason the command exists: a page-level or script-level request to a publisher can be judged automated traffic, and reading the copy Safari already holds cannot.

The commands read a long-term record of what the user viewed (every PDF Safari has cached, across sites). Their data sensitivity SHALL be recorded alongside the interference class, `list` SHALL apply a default result limit, and `get` SHALL act only on an explicit selection.

#### Scenario: retrieval during unrelated activity

- **WHEN** `safari-browser pdf-cache get out.pdf --key 0123abcd` runs while the user is typing in another application
- **THEN** the command completes without moving the cursor, changing window focus, showing a dialog, or producing sound

#### Scenario: no request leaves the machine

- **WHEN** any `pdf-cache` command runs
- **THEN** no network connection is opened by the command
