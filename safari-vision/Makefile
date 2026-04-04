INSTALL_DIR = $(HOME)/bin
BINARY_NAME = safari-vision

.PHONY: build release install clean metallib

build:
	swift build -c release
	./scripts/build-metallib.sh .build/release

release: build

install: build
	@mkdir -p $(INSTALL_DIR)
	cp .build/release/$(BINARY_NAME) $(INSTALL_DIR)/$(BINARY_NAME)
	cp .build/release/mlx.metallib $(INSTALL_DIR)/mlx.metallib
	@codesign --force --sign - $(INSTALL_DIR)/$(BINARY_NAME) 2>/dev/null || true
	@echo "✓ Installed $(BINARY_NAME) + mlx.metallib to $(INSTALL_DIR)/"

metallib:
	./scripts/build-metallib.sh .build/release

clean:
	rm -rf .build .xcodebuild
