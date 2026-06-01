INSTALL_DIR = $(HOME)/bin
BINARY_NAME = safari-browser

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
test-e2e:
	./Tests/e2e-test.sh

# Multi-profile filter e2e (#47/#51). Needs ≥2 Safari profiles configured;
# auto-skips (exit 77) when the setup is absent.
test-e2e-profile:
	./Tests/e2e-profile.sh

# `tab focus` live tab-switch (#45). Opens a throwaway window; auto-skips
# (exit 77) when the binary isn't installed.
test-tab-focus:
	./Tests/e2e-tab-focus.sh

test-daemon-parity:
	./Tests/e2e-daemon-parity.sh

test-exec-script:
	./Tests/e2e-exec-script.sh

test-mark-tab:
	./Tests/e2e-mark-tab.sh

clean:
	rm -rf .build
