## ADDED Requirements

### Requirement: Multi-level console capture

The system SHALL capture all console methods (log, warn, error, info, debug) when `--start` is invoked. Each captured message SHALL include a level prefix.

#### Scenario: Capture warn and error

- **WHEN** user runs `safari-browser console --start`, then JS calls `console.warn('low disk')` and `console.error('failed')`
- **THEN** `safari-browser console` output includes `[warn] low disk` and `[error] failed`

#### Scenario: Capture debug and info

- **WHEN** user runs `safari-browser console --start`, then JS calls `console.info('loaded')` and `console.debug('v=2')`
- **THEN** `safari-browser console` output includes `[info] loaded` and `[debug] v=2`

#### Scenario: Log level has no prefix for backwards compatibility

- **WHEN** user runs `safari-browser console --start`, then JS calls `console.log('hello')`
- **THEN** `safari-browser console` output includes `hello` (no `[log]` prefix, preserving existing behavior)
