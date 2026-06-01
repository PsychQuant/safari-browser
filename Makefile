INSTALL_DIR = $(HOME)/bin
BINARY_NAME = safari-browser

# E2E harnesses read $SAFARI_BROWSER_BIN (falling back to ~/bin). Default it to
# the freshly-built debug binary so `make test-e2e*` always exercises CURRENT
# source instead of a possibly weeks-stale installed ~/bin. Override to test
# another build, e.g. the installed artifact:
#   SAFARI_BROWSER_BIN=$(INSTALL_DIR)/$(BINARY_NAME) make test-e2e
SAFARI_BROWSER_BIN ?= .build/debug/$(BINARY_NAME)
export SAFARI_BROWSER_BIN

.PHONY: build build-debug install clean \
        test test-unit test-smoke test-all \
        test-e2e test-e2e-profile test-tab-focus test-daemon-parity test-exec-script test-mark-tab

build:
	swift build -c release

build-debug:
	swift build

install: build
	@mkdir -p $(INSTALL_DIR)
	cp .build/release/$(BINARY_NAME) $(INSTALL_DIR)/$(BINARY_NAME)
	@codesign --force --sign - $(INSTALL_DIR)/$(BINARY_NAME) 2>/dev/null || true
	@echo "✓ Installed $(BINARY_NAME) to $(INSTALL_DIR)/$(BINARY_NAME)"

# ── CI-safe tiers (no live Safari required) ──────────────────────────
test:
	SKIP_E2E=1 swift test

test-unit:
	SKIP_E2E=1 swift test

# Smoke: run the real binary's CLI contract (help/parse/validation errors)
# WITHOUT Safari — ArgumentParser + our custom main() resolve before any
# AppleScript. Fast, deterministic, CI-safe.
test-smoke: build-debug
	./Tests/smoke-test.sh

# Everything that can run unattended in CI.
test-all: test-unit test-smoke
	@echo "✓ unit + smoke green"

# ── Live-Safari tiers (local only — Safari must be running) ──────────
# Each depends on build-debug + runs against $SAFARI_BROWSER_BIN (the fresh
# debug binary by default; see the top-of-file override note).
test-e2e: build-debug
	./Tests/e2e-test.sh

# Multi-profile filter e2e (#47/#51). Needs ≥2 Safari profiles configured;
# auto-skips (exit 77) when the setup is absent.
test-e2e-profile: build-debug
	./Tests/e2e-profile.sh

# `tab focus` live tab-switch (#45). Opens a throwaway window; auto-skips
# (exit 77) when the binary isn't installed.
test-tab-focus: build-debug
	./Tests/e2e-tab-focus.sh

test-daemon-parity: build-debug
	./Tests/e2e-daemon-parity.sh

test-exec-script: build-debug
	./Tests/e2e-exec-script.sh

test-mark-tab: build-debug
	./Tests/e2e-mark-tab.sh

clean:
	rm -rf .build
