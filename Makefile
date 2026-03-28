INSTALL_DIR = $(HOME)/bin
BINARY_NAME = safari-browser

.PHONY: build install clean test test-unit test-e2e

build:
	swift build -c release

install: build
	@mkdir -p $(INSTALL_DIR)
	cp .build/release/$(BINARY_NAME) $(INSTALL_DIR)/$(BINARY_NAME)
	@echo "✓ Installed $(BINARY_NAME) to $(INSTALL_DIR)/$(BINARY_NAME)"

test:
	SKIP_E2E=1 swift test

test-unit:
	SKIP_E2E=1 swift test

test-e2e:
	swift test --filter E2ETests

clean:
	rm -rf .build
