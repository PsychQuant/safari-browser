INSTALL_DIR = $(HOME)/bin
BINARY_NAME = safari-browser

# E2E harnesses read $SAFARI_BROWSER_BIN (falling back to ~/bin). Default it to
# the freshly-built debug binary so `make test-e2e*` always exercises CURRENT
# source instead of a possibly weeks-stale installed ~/bin. Override to test
# another build, e.g. the installed artifact:
#   SAFARI_BROWSER_BIN=$(INSTALL_DIR)/$(BINARY_NAME) make test-e2e
SAFARI_BROWSER_BIN ?= .build/debug/$(BINARY_NAME)
export SAFARI_BROWSER_BIN

.PHONY: build build-debug install install-signed clean \
        sign-developer-id verify-developer-id verify-install-signature \
        test test-unit test-smoke test-all test-install-signature \
        test-e2e test-e2e-profile test-tab-focus test-daemon-parity test-exec-script test-mark-tab test-csp test-target-identity test-reference-edges

build:
	swift build -c release

build-debug:
	swift build

# Local dev install, ad-hoc signed. Fast iteration for work that does not need
# Full Disk Access.
#
# Re-signing after the copy matters: TCC keys a grant to the binary's code
# signature, so an unsigned copy is a different subject and starts with no
# permissions. (#98)
#
# But an ad-hoc signature is not merely "weaker" — its designated requirement
# IS the content hash (`designated => cdhash H"..."`), so EVERY rebuild
# invalidates any Full Disk Access grant this binary was given, silently. For
# `history` / `bookmarks` / `cloud-tabs` / `downloads` use `install-signed`
# instead. (#119)
#
# Installs through a temporary file and lands it with `mv`. Two reasons, both
# learned the hard way:
#
#   - `cp` over the canonical path writes IN PLACE, reusing the inode, and
#     macOS caches code-signature validation per inode. Overwriting an inode
#     still held open by a running process (the persistent daemon holds one for
#     up to its 600s idle timeout) makes the NEXT launch die with "load code
#     signature error 2" — SIGKILL, exit 137, no readable error. `mv` is a
#     rename: the destination gets a fresh inode. (#121)
#   - Writing the canonical path first also means a failed signing leaves a
#     broken binary on $PATH with the working one already gone.
install: build
	@mkdir -p "$(INSTALL_DIR)"
	@set -e; \
	 STAGE=$$(mktemp "$(INSTALL_DIR)/$(BINARY_NAME).XXXXXX"); \
	 trap 'rm -f "$$STAGE"' EXIT; \
	 cp .build/release/$(BINARY_NAME) "$$STAGE"; \
	 chmod +x "$$STAGE"; \
	 { codesign --force --sign - \
	       --entitlements Sources/SafariBrowser/Entitlements.plist \
	       "$$STAGE" 2>/dev/null \
	   || codesign --force --sign - "$$STAGE" 2>/dev/null; } \
	   || { echo "✗ ad-hoc signing failed — refusing to install"; exit 1; }; \
	 mv -f "$$STAGE" "$(INSTALL_DIR)/$(BINARY_NAME)"; \
	 trap - EXIT
	@echo "✓ Installed $(BINARY_NAME) to $(INSTALL_DIR)/$(BINARY_NAME) (ad-hoc)"
	@echo "  ⚠ A Full Disk Access grant on this binary will NOT survive the next"
	@echo "    rebuild. For history / bookmarks / cloud-tabs / downloads, use:"
	@echo "      DEVELOPER_ID=<cert-sha1> make install-signed"
	@echo "  Next: $(BINARY_NAME) setup   # grant Accessibility / Screen Recording"

# Fail fast when DEVELOPER_ID is missing. Left-most dependency of the signed
# targets so a missing env var aborts before the ~30s release build.
#
# Serial make only. Under `make -j` the build runs concurrently with this check
# and has already started by the time it fails — measured, not assumed. The
# guard still aborts the target; it just no longer saves you the build.
verify-developer-id:
	@test -n "$(DEVELOPER_ID)" || { echo "DEVELOPER_ID is unset — see CLAUDE.md 'Apple Developer / Notarization Pipeline'"; exit 1; }

# Install with a Developer ID signature. This is the path to a Full Disk Access
# grant that SURVIVES rebuilds: the designated requirement names an identity
# (`identifier ... and certificate leaf[subject.OU] = "<team>"`) rather than a
# content hash, so re-running this target does not invalidate the grant. (#119)
#
# Notarization is deliberately NOT part of this. It is for distributing to OTHER
# people; your own certificate launches fine on your own Mac, and requiring it
# here would drag in NOTARY_PROFILE and a 2–10 minute round-trip.
#
# The identifier comes from Sources/SafariBrowser/Info.plist — Package.swift
# links it in with `-sectcreate __TEXT __info_plist`, and codesign reads
# CFBundleIdentifier from there. Changing THAT string changes the designated
# requirement and silently invalidates existing grants; the filename does not.
# An earlier version of this recipe passed `--identifier` to "pin the current
# value", which was both redundant and harmful: it made this target's identifier
# a second source of truth that sign-developer-id did not share, so editing
# Info.plist would have made the two targets emit different requirements from
# one source tree — the exact silent invalidation the pin claimed to prevent.
#
# Installs through a temporary file in $(INSTALL_DIR) and only replaces the
# existing binary once signing AND verification have passed. Writing to the
# canonical path first meant a failed signing (cert missing, keychain locked,
# entitlement check failing) left an unsigned binary on $PATH with the
# known-good one already deleted — and macOS SIGKILLs unsigned binaries that
# call osascript, so the failure mode was not "no FDA" but "the CLI is dead".
install-signed: verify-developer-id build
	@mkdir -p "$(INSTALL_DIR)"
	@set -e; \
	 STAGE=$$(mktemp "$(INSTALL_DIR)/$(BINARY_NAME).XXXXXX"); \
	 trap 'rm -f "$$STAGE"' EXIT; \
	 cp .build/release/$(BINARY_NAME) "$$STAGE"; \
	 chmod +x "$$STAGE"; \
	 codesign --force --options runtime \
	          --sign "$(DEVELOPER_ID)" \
	          --entitlements Sources/SafariBrowser/Entitlements.plist \
	          "$$STAGE"; \
	 codesign -dv --entitlements - "$$STAGE" 2>&1 | grep -q apple-events \
	   || { echo "✗ entitlement missing from the signed binary"; exit 1; }; \
	 echo "✓ signed with apple-events entitlement"; \
	 codesign -dvv "$$STAGE" 2>&1 | grep -q "Authority=Developer ID Application" \
	   || { echo "✗ DEVELOPER_ID is not a Developer ID Application certificate:"; \
	        codesign -dvv "$$STAGE" 2>&1 | grep -E "^Authority=" | head -1 | sed "s/^/    /"; \
	        echo "    \`security find-identity -v -p codesigning\` often lists an Apple"; \
	        echo "    Development identity FIRST; this target needs the Developer ID one."; \
	        exit 1; }; \
	 ./scripts/verify-install-signature.sh "$$STAGE" \
	   || { echo "✗ refusing to install — see above"; exit 1; }; \
	 mv -f "$$STAGE" "$(INSTALL_DIR)/$(BINARY_NAME)"; \
	 trap - EXIT
	@echo "✓ Installed $(BINARY_NAME) to $(INSTALL_DIR)/$(BINARY_NAME) (Developer ID)"
	@echo "  ℹ Grant Full Disk Access ONCE to $(INSTALL_DIR)/$(BINARY_NAME);"
	@echo "    it then persists across rebuilds and version bumps."
	@echo "  Next: $(BINARY_NAME) setup   # grant Accessibility / Screen Recording"

# Sign the build-directory binary WITHOUT installing it.
#
# No AUTOMATION calls this target — there is no CI workflow and no release
# script. It is not free-standing, though, and #123 should not be read as
# saying so: the shipped binary tells users to run it
# (Sources/SafariBrowser/Utilities/CodeSigningState.swift), three assertions in
# CodeSigningStateTests.swift pin the string, and task 1.4 of the in-flight
# openspec change local-safari-data-query names it as the remediation. Deleting
# it without touching those leaves the product pointing at a make target that
# does not exist.
#
# It is also the target whose existence made this bug hard to see: it looks
# like "the signed install path" and is not one. It does NOT copy to
# $(INSTALL_DIR), and following it with `make install` re-signs ad-hoc and
# undoes the work. For a usable local install, use `install-signed`.
#
# Requires DEVELOPER_ID (certificate SHA-1) in the environment.
sign-developer-id: verify-developer-id build
	codesign --force --options runtime \
	         --sign $(DEVELOPER_ID) \
	         --entitlements Sources/SafariBrowser/Entitlements.plist \
	         .build/release/$(BINARY_NAME)
	@codesign -dv --entitlements - .build/release/$(BINARY_NAME) 2>&1 | grep -q apple-events \
	  && echo "✓ signed with apple-events entitlement" \
	  || { echo "✗ entitlement missing from the signed binary"; exit 1; }

# Is the installed binary's grant rebuild-proof? Reads only — no certificate,
# no Full Disk Access, no Safari.
#
# Note: make reports its own failure code (2) for any recipe error, so the
# script's distinction between 1 (ad-hoc) and 2 (unsigned) does not survive
# this wrapper. Non-zero still means "not rebuild-proof", which is what CI
# needs; call ./scripts/verify-install-signature.sh directly to tell the two
# failures apart.
verify-install-signature:
	@./scripts/verify-install-signature.sh "$(INSTALL_DIR)/$(BINARY_NAME)"

test-install-signature:
	./Tests/install-signature-test.sh

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
test-all: test-unit test-smoke test-install-signature
	@echo "✓ unit + smoke + install-signature green"

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

# #76: js on strict-CSP pages (eval-free wrappers) + interaction commands.
test-csp: build-debug
	./Tests/e2e-csp.sh

# #79: identity-anchored refs survive z-order churn (window-id + guard + retry).
test-target-identity: build-debug
	./Tests/e2e-target-identity.sh

# #83 / #96: only runs when a 0-tab front window or a modal sheet happens to be
# present — neither can be created safely on demand. Skips otherwise.
test-reference-edges: build-debug
	./Tests/e2e-reference-form-edges.sh

clean:
	rm -rf .build
