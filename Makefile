INSTALL_DIR = $(HOME)/bin
BINARY_NAME = safari-browser

.PHONY: build install clean

build:
	swift build -c release

install: build
	@mkdir -p $(INSTALL_DIR)
	cp .build/release/$(BINARY_NAME) $(INSTALL_DIR)/$(BINARY_NAME)
	@echo "✓ Installed $(BINARY_NAME) to $(INSTALL_DIR)/$(BINARY_NAME)"

clean:
	rm -rf .build
