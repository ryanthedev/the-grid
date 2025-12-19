.PHONY: help build server cli test clean server-test cli-test server-clean cli-clean run-server install dist dev

# Version from VERSION file
VERSION := $(shell cat VERSION)

# Default target - build everything
all: build

# Build both server and CLI
build: server cli
	@echo "✓ Built all components"

# Server targets
server:
	@echo "Building grid-server..."
	@cd grid-server && swift build

server-release:
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
	@cd grid-cli && $(MAKE) build

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

# Development targets
run-server: server
	@echo "Starting grid-server..."
	@./grid-server/.build/debug/grid-server

run-server-release: server-release
	@echo "Starting grid-server (release)..."
	@./grid-server/.build/release/grid-server

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
	@echo "Signing app bundle (inside-out)..."
	@codesign -fs - dist/GridServer.app/Contents/MacOS/grid-server
	@codesign -fs - dist/GridServer.app
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
	@echo "Server targets:"
	@echo "  server           - Build grid-server (debug)"
	@echo "  server-release   - Build grid-server (release)"
	@echo "  server-test      - Run grid-server tests"
	@echo "  server-clean     - Clean grid-server build"
	@echo "  run-server       - Build and run grid-server (debug)"
	@echo ""
	@echo "CLI targets:"
	@echo "  cli              - Build thegrid CLI"
	@echo "  cli-test         - Run grid-cli tests"
	@echo "  cli-clean        - Clean grid-cli build"
	@echo "  cli-install      - Install thegrid to \$$GOPATH/bin"
	@echo ""
	@echo "Usage examples:"
	@echo "  make              # Build everything"
	@echo "  make server       # Build just the server"
	@echo "  make cli          # Build just the CLI"
	@echo "  make test         # Run all tests"
	@echo "  make run-server   # Build and run the server"
	@echo "  make dev          # Build, clear logs, restart server (interactive)"
	@echo "  make dist         # Create distribution tarball"

# Development: build, clear logs, restart server with output visible
dev: build
	@echo "Stopping existing server..."
	@-pkill -f "grid-server" 2>/dev/null || true
	@sleep 0.5
	@echo "Clearing logs..."
	@rm -f ~/.local/state/thegrid/grid-cli.log
	@rm -f ~/.local/state/thegrid/events.jsonl
	@rm -f ~/.local/state/thegrid/grid-server.log
	@echo "Starting server (Ctrl+C to stop)..."
	@script -q ~/.local/state/thegrid/grid-server.log ./grid-server/.build/debug/grid-server --debug

# Quick reload: build, restart server in background, apply layout
# Usage: make reload LAYOUT=two-column  (default: two-column)
LAYOUT ?= two-column
reload: build
	@echo "Restarting server..."
	@-pkill -f "grid-server" 2>/dev/null || true
	@sleep 0.5
	@./grid-server/.build/debug/grid-server &>/dev/null &
	@sleep 1
	@echo "Applying layout: $(LAYOUT)"
	@./grid-cli/bin/thegrid layout apply $(LAYOUT)
	@echo "✓ Server reloaded and layout applied"
