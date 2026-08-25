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
        test-install-signature-strict \
        test-e2e test-e2e-profile test-tab-focus test-daemon-parity test-exec-script test-mark-tab test-csp test-target-identity test-reference-edges

build:
	swift build -c release

# The signature guard. Swift, not shell: it reads the Security framework
# directly, so the designated requirement is an OBJECT rather than text
# scraped out of codesign's human-readable diagnostics. Five rounds of review
# broke five successive text-parsing versions — the last two with nothing more
# exotic than a real third-party app and a filename containing a newline. See
# the header of the script for the full history. (#119)
# Compiled, not `swift scripts/...`. Round 6: when the swift driver could not
# compile the script — which happens on this machine whenever swiftly's
# toolchain leads PATH and .build was made by another — the driver exits 1,
# and 1 is the documented verdict "this binary is ad-hoc, run install-signed".
# A user with the wrong PATH order was told their Developer ID binary was
# ad-hoc. Compiling separates the two: a compile failure is a build failure
# here, loudly, and never reaches the exit-code contract. It also stops the
# test suite recompiling the same file twenty times.
VERIFY_BIN = .build/verify-install-signature
VERIFY_SIG = $(VERIFY_BIN)

$(VERIFY_BIN): scripts/verify-install-signature.swift
	@mkdir -p .build
	@swiftc -O -o $@ $< || { echo "✗ could not compile the signature guard — this is a build"; \
	  echo "  failure, not a verdict about any binary. Check that swift can compile:"; \
	  echo "    swiftc -o /dev/null scripts/verify-install-signature.swift"; exit 1; }

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
	 WANT=$$(shasum -a 256 < "$$STAGE" | awk '{print $$1}'); \
	 mv -f "$$STAGE" "$(INSTALL_DIR)/$(BINARY_NAME)"; \
	 GOT=$$(shasum -a 256 < "$(INSTALL_DIR)/$(BINARY_NAME)" | awk '{print $$1}'); \
	 [ "$$WANT" = "$$GOT" ] || { \
	   echo "✗ another install landed a different binary at the same moment."; \
	   echo "  What is on \$$PATH is not what this run built. Nothing was rolled"; \
	   echo "  back: the other binary may well be the one you want, and deleting"; \
	   echo "  someone else's completed install would be the worse mistake."; \
	   echo "  Re-run this target if you did want this one."; \
	   exit 1; }; \
	 echo "✓ Installed $(BINARY_NAME) to $(INSTALL_DIR)/$(BINARY_NAME) (ad-hoc)"; \
	 true
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
install-signed: verify-developer-id build $(VERIFY_BIN)
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
	 $(VERIFY_SIG) --require-shape "Developer ID" \
	               --require-entitlement com.apple.security.automation.apple-events \
	               "$$STAGE" \
	   || { echo "✗ refusing to install — see above"; exit 1; }; \
	 WANT=$$(shasum -a 256 < "$$STAGE" | awk '{print $$1}'); \
	 mv -f "$$STAGE" "$(INSTALL_DIR)/$(BINARY_NAME)"; \
	 GOT=$$(shasum -a 256 < "$(INSTALL_DIR)/$(BINARY_NAME)" | awk '{print $$1}'); \
	 [ "$$WANT" = "$$GOT" ] && LANDED_OURS=1 || LANDED_OURS=0; \
	 $(VERIFY_SIG) --require-shape "Developer ID" \
	               --require-entitlement com.apple.security.automation.apple-events \
	               "$(INSTALL_DIR)/$(BINARY_NAME)" >/dev/null \
	   || { echo "✗ the binary now on \$$PATH does not meet install-signed's contract."; \
	        echo "  Nothing was rolled back — see the diagnosis above and decide."; \
	        exit 1; }; \
	 [ "$$LANDED_OURS" = 1 ] || { \
	   echo "✗ another install landed at the same moment. What is on \$$PATH is not"; \
	   echo "  what this run built — it does meet the contract, so it was left alone."; \
	   echo "  Re-run this target if you wanted this build specifically."; \
	   exit 1; }; \
	 echo "✓ Installed $(BINARY_NAME) to $(INSTALL_DIR)/$(BINARY_NAME) (Developer ID)"; \
	 true
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
# guard's distinct codes do not survive this wrapper — run $(VERIFY_SIG) <path>
# directly to tell them apart, and read their meanings from the header of
# scripts/verify-install-signature.swift, which is the one place they are
# defined. This comment used to restate them and drifted: it still said
# "2 unreadable" after round 7 moved unreadable to 70 and gave 2 to unsigned,
# i.e. it had inverted. Non-zero still means "not provably durable", which is what CI
# needs; run $(VERIFY_SIG) <path> directly to tell them apart.
verify-install-signature: $(VERIFY_BIN)
	@$(VERIFY_SIG) "$(INSTALL_DIR)/$(BINARY_NAME)"

test-install-signature: $(VERIFY_BIN)
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

# The same suite, refusing to pass on a partial run. Use this on a machine that
# holds both a Developer ID and a non-Developer-ID identity; it is what this
# repo's own verification runs, and what a change to the guard must be checked
# against. `make test-all` deliberately does not gate on it — see below.
# ALLOW_INCOMPLETE= is passed explicitly, not merely left unset. Round 7: this
# target's entire strictness was "we do not set it" — but it is an environment
# variable, so a shell that had exported it (which is what `test-all` does, one
# target above) handed it straight through, and `strict` accepted a partial run
# with rc=0. A target whose guarantee can be switched off by the caller's
# environment does not have that guarantee.
test-install-signature-strict: $(VERIFY_BIN)
	@ALLOW_INCOMPLETE= bash Tests/install-signature-test.sh

# Everything that runs on any machine, with or without a signing identity.
#
# ALLOW_INCOMPLETE is set here on purpose. The signature suite needs BOTH a
# Developer ID and a non-Developer-ID identity in the keychain to run every
# case; with one it skips two, with none it skips three. Round 6 measured
# `make test-all` going red on a machine holding only a Developer ID — which
# is exactly the configuration #119 tells you to have — and on a plain clone
# by anyone without an Apple Developer account, for whom README says `make
# install` is the right target. That is round 1's defect verbatim: the fix for
# a review finding turned the green-build gate red for the population the
# change serves.
#
# The suite still names every case it could not run, and `make
# test-install-signature-strict` refuses to pass on a partial run — that is
# the target to use on a machine that has both identities, and the one this
# repo's own verification uses.
test-all: test-unit test-smoke
	@ALLOW_INCOMPLETE=1 $(MAKE) --no-print-directory test-install-signature
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
