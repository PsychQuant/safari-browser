## ADDED Requirements

### Requirement: Self-update is non-interfering and contacts only GitHub

The `self-update` command, with or without `--check`, SHALL be classified as **Non-interfering** under the conformance classification for new commands. It SHALL NOT drive Safari, control input devices, display system dialogs, produce sound, or change window focus. Its network requests SHALL go only to `api.github.com` for the release lookup and to the release asset URLs under `github.com/PsychQuant/safari-browser/releases/download/` (including GitHub's own redirect to its asset storage), and SHALL carry no user data beyond HTTP request metadata. Writing the CLI's own binary does not change this classification; it is recorded here so the network and self-write behaviour are explicit rather than implied.

#### Scenario: Self-update during unrelated user activity

- **WHEN** a user runs `safari-browser self-update` while typing in another application
- **THEN** the command SHALL complete without moving the cursor, changing window focus, producing sound, or launching Safari
