.PHONY: help build server cli test clean server-test cli-test server-clean cli-clean run-server install dist dev reset-accessibility setup-signing install-scripts

# Version from VERSION file
VERSION := $(shell cat VERSION)
COMMIT  := $(shell git rev-parse HEAD 2>/dev/null || echo "unknown")

# Code signing identity for development builds
# Create this certificate once in Keychain Access:
#   1. Open Keychain Access
#   2. Menu: Keychain Access → Certificate Assistant → Create a Certificate
#   3. Name: thegrid-dev
#   4. Identity Type: Self-Signed Root
#   5. Certificate Type: Code Signing
#   6. Click Create
# This gives stable signatures so TCC remembers accessibility permissions.
CODESIGN_IDENTITY ?= thegrid-dev
ENTITLEMENTS := grid-server/thegrid.entitlements

# Default target - build everything
all: build

# Build both server and CLI
build: server cli
	@echo "✓ Built all components"

# Generate Version.swift with build-time version info
generate-version:
	@echo "// Auto-generated - do not edit" > grid-server/Sources/GridServer/Version.swift
	@echo "let GridServerVersion = \"$(VERSION)\"" >> grid-server/Sources/GridServer/Version.swift
	@echo "let GridServerCommit = \"$(COMMIT)\"" >> grid-server/Sources/GridServer/Version.swift

# Server targets
server: generate-version
	@echo "Building grid-server..."
	@cd grid-server && swift build

server-release: generate-version
	@echo "Building grid-server (release)..."
	@cd grid-server && swift build -c release

server-test:
	@echo "Running grid-server tests..."
	@cd grid-server && swift test

server-clean:
	@echo "Cleaning grid-server..."
	@cd grid-server && swift package clean

# CLI targets
cli:
	@echo "Building grid-cli..."
	@cd grid-cli && $(MAKE) build VERSION=$(VERSION) COMMIT=$(COMMIT)

cli-test:
	@echo "Running grid-cli tests..."
	@cd grid-cli && $(MAKE) test

cli-clean:
	@echo "Cleaning grid-cli..."
	@cd grid-cli && $(MAKE) clean

cli-install:
	@echo "Installing grid-cli..."
	@cd grid-cli && $(MAKE) install

# Combined targets
test: server-test cli-test
	@echo "✓ All tests passed"

clean: server-clean cli-clean
	@echo "✓ Cleaned all components"

# Quick verification
verify: build test
	@echo "✓ Build and test verification complete"

# Distribution tarball (single architecture - for local use)
dist: server-release cli
	@echo "Creating distribution tarball v$(VERSION)..."
	@rm -rf dist
	@mkdir -p dist/thegrid-$(VERSION)/bin
	@cp grid-server/.build/release/grid-server dist/thegrid-$(VERSION)/bin/
	@cp grid-cli/bin/thegrid dist/thegrid-$(VERSION)/bin/
	@cp VERSION dist/thegrid-$(VERSION)/
	@cp LICENSE dist/thegrid-$(VERSION)/ 2>/dev/null || echo "No LICENSE file"
	@cp README.md dist/thegrid-$(VERSION)/ 2>/dev/null || true
	@cd dist && tar -czf thegrid-$(VERSION).tar.gz thegrid-$(VERSION)
	@echo ""
	@echo "Distribution tarball created:"
	@ls -lh dist/thegrid-$(VERSION).tar.gz
	@echo ""
	@echo "SHA256:"
	@shasum -a 256 dist/thegrid-$(VERSION).tar.gz

# Universal binary builds (arm64 + x86_64)
server-universal:
	@echo "Building grid-server (universal binary)..."
	@cd grid-server && swift build -c release --arch arm64 --arch x86_64
	@echo "Verifying universal binary..."
	@if ! file grid-server/.build/apple/Products/Release/grid-server | grep -q "universal binary"; then \
		echo "Error: Failed to create universal binary for grid-server"; \
		exit 1; \
	fi

cli-universal:
	@echo "Building thegrid CLI (universal binary)..."
	@mkdir -p grid-cli/bin
	@cd grid-cli && GOOS=darwin GOARCH=arm64 go build -o bin/thegrid-arm64 ./cmd/grid
	@cd grid-cli && GOOS=darwin GOARCH=amd64 go build -o bin/thegrid-amd64 ./cmd/grid
	@lipo -create -output grid-cli/bin/thegrid grid-cli/bin/thegrid-arm64 grid-cli/bin/thegrid-amd64
	@rm grid-cli/bin/thegrid-arm64 grid-cli/bin/thegrid-amd64
	@echo "Verifying universal binary..."
	@if ! file grid-cli/bin/thegrid | grep -q "universal binary"; then \
		echo "Error: Failed to create universal binary for thegrid CLI"; \
		exit 1; \
	fi
	@echo "Created universal binary: grid-cli/bin/thegrid"
	@file grid-cli/bin/thegrid

# Create GridServer.app bundle
app-bundle: server-universal
	@echo "Creating GridServer.app bundle..."
	@rm -rf dist/GridServer.app
	@mkdir -p dist/GridServer.app/Contents/MacOS
	@mkdir -p dist/GridServer.app/Contents/Resources
	@cp grid-server/.build/apple/Products/Release/grid-server dist/GridServer.app/Contents/MacOS/
	@cp grid-server/Info.plist dist/GridServer.app/Contents/
	@sed -i '' "s/VERSION_PLACEHOLDER/$(VERSION)/g" dist/GridServer.app/Contents/Info.plist
	@grep -q "$(VERSION)" dist/GridServer.app/Contents/Info.plist || (echo "ERROR: Version substitution failed" && exit 1)
	@echo "Signing app bundle with identity '$(CODESIGN_IDENTITY)'..."
	@codesign -fs "$(CODESIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) dist/GridServer.app/Contents/MacOS/grid-server
	@codesign -fs "$(CODESIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) dist/GridServer.app
	@echo "Verifying app bundle..."
	@codesign --verify --verbose dist/GridServer.app
	@codesign -dv dist/GridServer.app 2>&1 | head -5
	@echo "✓ GridServer.app created"

# Distribution tarball with universal binaries (for Homebrew)
dist-universal: app-bundle cli-universal
	@echo "Creating universal distribution tarball v$(VERSION)..."
	@rm -rf dist/thegrid-$(VERSION)
	@mkdir -p dist/thegrid-$(VERSION)/bin
	@cp -R dist/GridServer.app dist/thegrid-$(VERSION)/
	@cp grid-cli/bin/thegrid dist/thegrid-$(VERSION)/bin/
	@cp VERSION dist/thegrid-$(VERSION)/
	@cp LICENSE dist/thegrid-$(VERSION)/ 2>/dev/null || echo "No LICENSE file"
	@cp README.md dist/thegrid-$(VERSION)/ 2>/dev/null || true
	@cd dist && tar -czf thegrid-$(VERSION)-darwin-universal.tar.gz thegrid-$(VERSION)
	@echo ""
	@echo "Universal distribution tarball created:"
	@ls -lh dist/thegrid-$(VERSION)-darwin-universal.tar.gz
	@echo ""
	@echo "SHA256:"
	@shasum -a 256 dist/thegrid-$(VERSION)-darwin-universal.tar.gz
	@echo ""
	@echo "Verify contents:"
	@file dist/thegrid-$(VERSION)/GridServer.app/Contents/MacOS/grid-server
	@file dist/thegrid-$(VERSION)/bin/thegrid

# Show help
help:
	@echo "TheGrid Monorepo Build System"
	@echo ""
	@echo "Main targets:"
	@echo "  all/build        - Build both server and CLI (default)"
	@echo "  test             - Run all tests"
	@echo "  clean            - Clean all build artifacts"
	@echo "  verify           - Build and test everything"
	@echo "  dist             - Create distribution tarball (current arch)"
	@echo "  dist-universal   - Create universal binary tarball (arm64+x86_64)"
	@echo ""
	@echo "Development targets:"
	@echo "  dev              - Build debug GridServer.app bundle"
	@echo "  run              - Build and restart thegrid-dev service"
	@echo "  install-dev      - Install dev CLI to ~/.local/state/thegrid/bin"
	@echo "  setup-signing    - Create code signing certificate (one-time)"
	@echo "  reset-accessibility - Reset TCC accessibility permissions"
	@echo ""
	@echo "Server targets:"
	@echo "  server           - Build grid-server (debug)"
	@echo "  server-release   - Build grid-server (release)"
	@echo "  server-test      - Run grid-server tests"
	@echo "  server-clean     - Clean grid-server build"
	@echo ""
	@echo "CLI targets:"
	@echo "  cli              - Build thegrid CLI"
	@echo "  cli-test         - Run grid-cli tests"
	@echo "  cli-clean        - Clean grid-cli build"
	@echo "  cli-install      - Install thegrid to \$$GOPATH/bin"
	@echo ""
	@echo "Usage examples:"
	@echo "  make dev          # Build debug app bundle"
	@echo "  make run          # Build and restart thegrid service"
	@echo "  make test         # Run all tests"
	@echo "  make dist         # Create distribution tarball"

# Debug app bundle (for development - required for Accessibility permissions)
APP_BUNDLE := grid-server/.build/debug/GridServer.app

# Build debug app bundle
dev: server cli
	@echo "Creating debug GridServer.app bundle..."
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp grid-server/.build/debug/grid-server $(APP_BUNDLE)/Contents/MacOS/
	@cp grid-server/Info.plist $(APP_BUNDLE)/Contents/
	@echo "Signing with identity '$(CODESIGN_IDENTITY)'..."
	@codesign -fs "$(CODESIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) $(APP_BUNDLE)/Contents/MacOS/grid-server
	@codesign -fs "$(CODESIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) $(APP_BUNDLE)
	@echo "✓ Debug GridServer.app created at $(APP_BUNDLE)"

# Build and restart thegrid service
run: dev install-dev
	@echo "Restarting thegrid-dev service..."
	@services restart thegrid-dev
	@echo "✓ Service restarted"

# Install dev build to ~/.local/state/thegrid/bin for wrapper resolution
install-dev: cli
	@mkdir -p ~/.local/state/thegrid/bin
	@cp grid-cli/bin/thegrid ~/.local/state/thegrid/bin/thegrid
	@echo "✓ Installed dev CLI to ~/.local/state/thegrid/bin/thegrid"

# Install utility scripts to ~/.local/bin
install-scripts:
	@mkdir -p ~/.local/bin
	@ln -sf $(CURDIR)/scripts/reapply-layouts.sh ~/.local/bin/thegrid-reapply-layouts
	@ln -sf $(CURDIR)/scripts/reset-accessibility.sh ~/.local/bin/thegrid-reset-accessibility
	@echo "✓ Installed scripts to ~/.local/bin"

# Tail server logs (real-time streaming)
tail-server:
	@tail -f ~/.local/state/thegrid/thegrid-server.json | jq --unbuffered -c '{ev: .ev, data: .data}'

# Tail CLI logs (real-time streaming)
tail-cli:
	@tail -f ~/.local/state/thegrid/thegrid-cli.json | jq --unbuffered -c '{ev: .ev, data: .data}'

# Tail both logs
tail:
	@tail -f ~/.local/state/thegrid/*.json | jq --unbuffered -c '{ev: .ev, data: .data}'

# Reset accessibility permissions (use when TCC gets confused)
reset-accessibility:
	@./scripts/reset-accessibility.sh

# Setup code signing certificate (one-time)
setup-signing:
	@./scripts/create-dev-certificate.sh
