## MODIFIED Requirements

### Requirement: Wait for duration
The system SHALL pause execution for the specified non-negative number of milliseconds when no URL or JavaScript wait predicate is selected. The millisecond value SHALL be representable as UInt64 nanoseconds; otherwise the CLI SHALL return a validation error before sleeping, without an arithmetic trap. Predicate selection and precedence SHALL remain unchanged.

#### Scenario: Wait 2 seconds
- **WHEN** user runs `safari-browser wait 2000`
- **THEN** the CLI blocks for approximately 2000ms before exiting

#### Scenario: Conversion upper bound
- **WHEN** the pure conversion receives 18_446_744_073_709 milliseconds
- **THEN** it returns 18_446_744_073_709_000_000 nanoseconds without starting a wait

#### Scenario: Overflow rejected
- **WHEN** user runs `safari-browser wait 18446744073710`
- **THEN** the CLI returns a validation error naming the upper bound before starting a wait, rather than terminating by signal

#### Scenario: Negative duration
- **WHEN** the pure conversion receives -1 or Int.min
- **THEN** it returns the existing non-negative-value validation error before converting to UInt64
