# vision-worker Specification

## Purpose

TBD - created by archiving change 'realtime-vision-channel'. Update Purpose after archive.

## Requirements

### Requirement: Analyze screenshot with FastVLM

The system SHALL provide a Swift CLI (`safari-vision`) that loads FastVLM-0.5B CoreML model and generates a text description from a screenshot image and a text prompt.

#### Scenario: Analyze a screenshot

- **WHEN** user runs `safari-vision analyze /tmp/frame.png "Describe this webpage"`
- **THEN** stdout contains a text description of the webpage content

#### Scenario: Model not downloaded

- **WHEN** user runs `safari-vision analyze` and the CoreML model is not present at `~/.safari-browser/models/`
- **THEN** the CLI exits with non-zero status and stderr contains instructions to run `safari-vision setup`


<!-- @trace
source: realtime-vision-channel
updated: 2026-04-08
code:
-->

---
### Requirement: Setup and download model

The system SHALL provide a `safari-vision setup` command that downloads the FastVLM-0.5B CoreML model from Hugging Face to `~/.safari-browser/models/`.

#### Scenario: First-time setup

- **WHEN** user runs `safari-vision setup`
- **THEN** the model is downloaded and cached at `~/.safari-browser/models/fastvlm-0.5b-coreml/`


<!-- @trace
source: realtime-vision-channel
updated: 2026-04-08
code:
-->

---
### Requirement: Fast inference

The system SHALL achieve time-to-first-token under 50ms on Apple Silicon (M1 or later) for a single screenshot analysis.

#### Scenario: Inference speed

- **WHEN** `safari-vision analyze` is called on a 1920x1080 screenshot
- **THEN** the first token is generated within 50ms (FastVLM design target: ~6ms)

<!-- @trace
source: realtime-vision-channel
updated: 2026-04-08
code:
-->
