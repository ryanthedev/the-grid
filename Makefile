.PHONY: help build server cli viewer test clean server-test server-clean run-server install dist dev reset-accessibility setup-signing server-universal cli-universal viewer-universal dist-universal notify notify-dev notify-universal notify-app-bundle notify-test notify-clean mcp mcp-dev mcp-install

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
# Use $(CURDIR) so it works from worktrees and CI
ENTITLEMENTS := $(CURDIR)/grid-server/thegrid.entitlements
NOTIFY_ENTITLEMENTS := $(CURDIR)/grid-notify/grid-notify.entitlements

# Default target - build everything
all: build

# Build server, CLI, and notify
build: server cli notify
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

# Viewer target (standalone image/media viewer)
viewer:
	@echo "Building grid-viewer..."
	@cd grid-server && swift build --product grid-viewer

server-release: generate-version
	@echo "Building grid-server (release)..."
	@cd grid-server && swift build -c release

server-test:
	@echo "Running grid-server tests..."
	@cd grid-server && swift test

server-clean:
	@echo "Cleaning grid-server..."
	@cd grid-server && swift package clean

# Notification panel targets
notify:
	@echo "Building grid-notify..."
	@cd grid-notify && swift build

notify-test:
	@echo "Running grid-notify tests..."
	@cd grid-notify && swift test

notify-clean:
	@echo "Cleaning grid-notify..."
	@cd grid-notify && swift package clean

# CLI target (Swift)
cli:
	@echo "Building grid-cli (Swift)..."
	@cd grid-server && swift build --product grid-cli

# Combined targets
test: server-test notify-test
	@echo "✓ All tests passed"

clean: server-clean notify-clean
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
	@cp grid-server/.build/release/grid-cli dist/thegrid-$(VERSION)/bin/thegrid
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
server-universal: generate-version
	@echo "Building grid-server (universal binary)..."
	@cd grid-server && swift build -c release --arch arm64 --arch x86_64
	@echo "Verifying universal binary..."
	@if ! file grid-server/.build/apple/Products/Release/grid-server | grep -q "universal binary"; then \
		echo "Error: Failed to create universal binary for grid-server"; \
		exit 1; \
	fi

cli-universal:
	@echo "Building grid-cli universal binary..."
	@cd grid-server && swift build -c release --product grid-cli --arch arm64 --arch x86_64
	@echo "Verifying universal binary..."
	@if ! file grid-server/.build/apple/Products/Release/grid-cli | grep -q "universal binary"; then \
		echo "Error: Failed to create universal binary for grid-cli"; \
		exit 1; \
	fi
	@echo "Created universal binary: grid-server/.build/apple/Products/Release/grid-cli"
	@file grid-server/.build/apple/Products/Release/grid-cli

viewer-universal:
	@echo "Building grid-viewer (universal binary)..."
	@cd grid-server && swift build -c release --product grid-viewer --arch arm64 --arch x86_64
	@echo "Verifying universal binary..."
	@if ! file grid-server/.build/apple/Products/Release/grid-viewer | grep -q "universal binary"; then \
		echo "Error: Failed to create universal binary for grid-viewer"; \
		exit 1; \
	fi
	@echo "Created universal binary: grid-server/.build/apple/Products/Release/grid-viewer"
	@file grid-server/.build/apple/Products/Release/grid-viewer

notify-universal:
	@echo "Building grid-notify (universal binary)..."
	@cd grid-notify && swift build -c release --arch arm64 --arch x86_64
	@echo "Verifying universal binary..."
	@if ! file grid-notify/.build/apple/Products/Release/GridNotify | grep -q "universal binary"; then \
		echo "Error: Failed to create universal binary for grid-notify"; \
		exit 1; \
	fi
	@echo "Created universal binary: grid-notify/.build/apple/Products/Release/GridNotify"
	@file grid-notify/.build/apple/Products/Release/GridNotify

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

# Create GridNotify.app bundle
notify-app-bundle: notify-universal
	@echo "Creating GridNotify.app bundle..."
	@rm -rf dist/GridNotify.app
	@mkdir -p dist/GridNotify.app/Contents/MacOS
	@mkdir -p dist/GridNotify.app/Contents/Resources
	@cp grid-notify/.build/apple/Products/Release/GridNotify dist/GridNotify.app/Contents/MacOS/grid-notify
	@cp grid-notify/Info.plist dist/GridNotify.app/Contents/
	@cp -R grid-notify/scripts/ dist/GridNotify.app/Contents/Resources/scripts/
	@sed -i '' "s/VERSION_PLACEHOLDER/$(VERSION)/g" dist/GridNotify.app/Contents/Info.plist
	@grep -q "$(VERSION)" dist/GridNotify.app/Contents/Info.plist || (echo "ERROR: Version substitution failed" && exit 1)
	@echo "Signing app bundle with identity '$(CODESIGN_IDENTITY)'..."
	@codesign -fs "$(CODESIGN_IDENTITY)" --entitlements $(NOTIFY_ENTITLEMENTS) dist/GridNotify.app/Contents/MacOS/grid-notify
	@codesign -fs "$(CODESIGN_IDENTITY)" --entitlements $(NOTIFY_ENTITLEMENTS) dist/GridNotify.app
	@echo "Verifying app bundle..."
	@codesign --verify --verbose dist/GridNotify.app
	@codesign -dv dist/GridNotify.app 2>&1 | head -5
	@echo "✓ GridNotify.app created"

# Distribution tarball with universal binaries (for Homebrew)
dist-universal: app-bundle notify-app-bundle cli-universal viewer-universal
	@echo "Creating universal distribution tarball v$(VERSION)..."
	@rm -rf dist/thegrid-$(VERSION)
	@mkdir -p dist/thegrid-$(VERSION)/bin
	@cp -R dist/GridServer.app dist/thegrid-$(VERSION)/
	@cp -R dist/GridNotify.app dist/thegrid-$(VERSION)/
	@cp grid-server/.build/apple/Products/Release/grid-cli dist/thegrid-$(VERSION)/bin/thegrid
	@cp grid-server/.build/apple/Products/Release/grid-viewer dist/thegrid-$(VERSION)/bin/
	@cp VERSION dist/thegrid-$(VERSION)/
	@cp LICENSE dist/thegrid-$(VERSION)/ 2>/dev/null || echo "No LICENSE file"
	@cp README.md dist/thegrid-$(VERSION)/ 2>/dev/null || true
	@printf '    prefix.install "GridServer.app"\n    prefix.install "GridNotify.app"\n    bin.install "bin/thegrid"\n    bin.install "bin/grid-viewer"\n    bin.install_symlink prefix/"GridServer.app/Contents/MacOS/grid-server"\n    bin.install_symlink prefix/"GridNotify.app/Contents/MacOS/grid-notify"\n' > dist/thegrid-$(VERSION)/FORMULA_INSTALL
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
	@file dist/thegrid-$(VERSION)/GridNotify.app/Contents/MacOS/grid-notify
	@file dist/thegrid-$(VERSION)/bin/thegrid
	@file dist/thegrid-$(VERSION)/bin/grid-viewer
# Show help
help:
	@echo "TheGrid Monorepo Build System"
	@echo ""
	@echo "Main targets:"
	@echo "  all/build        - Build server, CLI, and notify (default)"
	@echo "  test             - Run all tests"
	@echo "  clean            - Clean all build artifacts"
	@echo "  verify           - Build and test everything"
	@echo "  dist             - Create distribution tarball (current arch)"
	@echo "  dist-universal   - Create universal binary tarball (arm64+x86_64)"
	@echo ""
	@echo "Development targets:"
	@echo "  dev              - Build debug GridServer.app bundle"
	@echo "  run              - Build and restart thegrid-dev service"
	@echo "  install-dev      - Install dev CLI to ~/.local/bin"
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
	@echo "  cli              - Build Swift CLI"
	@echo ""
	@echo "Notify targets:"
	@echo "  notify           - Build grid-notify (debug)"
	@echo "  notify-test      - Run grid-notify tests"
	@echo "  notify-clean     - Clean grid-notify build"
	@echo ""
	@echo "Usage examples:"
	@echo "  make dev          # Build debug app bundle"
	@echo "  make run          # Build and restart thegrid service"
	@echo "  make test         # Run all tests"
	@echo "  make dist         # Create distribution tarball"

# Debug app bundles (for development - required for Accessibility permissions)
APP_BUNDLE := grid-server/.build/debug/GridServer.app
NOTIFY_APP_BUNDLE := grid-notify/.build/debug/GridNotify.app

# Where launchd expects the apps (central location for all worktrees)
DEPLOY_LOCATION := $(HOME)/.local/state/thegrid/GridServer.app
NOTIFY_DEPLOY_LOCATION := $(HOME)/.local/state/thegrid/GridNotify.app

# Build and deploy debug GridNotify.app bundle
notify-dev: notify
	@echo "Creating debug GridNotify.app bundle..."
	@mkdir -p $(NOTIFY_APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(NOTIFY_APP_BUNDLE)/Contents/Resources
	@cp grid-notify/.build/debug/GridNotify $(NOTIFY_APP_BUNDLE)/Contents/MacOS/grid-notify
	@cp grid-notify/Info.plist $(NOTIFY_APP_BUNDLE)/Contents/
	@cp -R grid-notify/scripts/ $(NOTIFY_APP_BUNDLE)/Contents/Resources/scripts/
	@echo "Signing with identity '$(CODESIGN_IDENTITY)'..."
	@codesign -fs "$(CODESIGN_IDENTITY)" --entitlements $(NOTIFY_ENTITLEMENTS) $(NOTIFY_APP_BUNDLE)/Contents/MacOS/grid-notify
	@codesign -fs "$(CODESIGN_IDENTITY)" --entitlements $(NOTIFY_ENTITLEMENTS) $(NOTIFY_APP_BUNDLE)
	@echo "✓ Debug GridNotify.app built"
	@echo "Deploying to $(NOTIFY_DEPLOY_LOCATION)..."
	@mkdir -p $$(dirname $(NOTIFY_DEPLOY_LOCATION))
	@rm -rf $(NOTIFY_DEPLOY_LOCATION)
	@cp -R $(NOTIFY_APP_BUNDLE) $(NOTIFY_DEPLOY_LOCATION)
	@echo "✓ GridNotify deployed to $(NOTIFY_DEPLOY_LOCATION)"

# Build debug app bundles
dev: server viewer notify-dev
	@echo "Creating debug GridServer.app bundle..."
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp grid-server/.build/debug/grid-server $(APP_BUNDLE)/Contents/MacOS/
	@cp grid-server/Info.plist $(APP_BUNDLE)/Contents/
	@echo "Signing with identity '$(CODESIGN_IDENTITY)'..."
	@codesign -fs "$(CODESIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) $(APP_BUNDLE)/Contents/MacOS/grid-server
	@codesign -fs "$(CODESIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) $(APP_BUNDLE)
	@echo "✓ Debug GridServer.app built"
	@echo "Deploying to $(DEPLOY_LOCATION)..."
	@mkdir -p $$(dirname $(DEPLOY_LOCATION))
	@rm -rf $(DEPLOY_LOCATION)
	@cp -R $(APP_BUNDLE) $(DEPLOY_LOCATION)
	@echo "✓ Server deployed to $(DEPLOY_LOCATION)"

# Build and restart thegrid service
run: dev install-dev
	@echo "Killing any stray grid-server processes..."
	@pkill -9 -f grid-server 2>/dev/null || true
	@echo "Killing any stray grid-notify processes..."
	@pkill -9 -f grid-notify 2>/dev/null || true
	@sleep 0.5
	@echo "Clearing state, logs, and config cache..."
	@rm -f ~/.local/state/thegrid/*.json
	@rm -f ~/.cache/thegrid/config.merged.yaml
	@echo "Restarting thegrid-dev service..."
	@services restart thegrid-dev
	@echo "Launching GridNotify..."
	@open $(NOTIFY_DEPLOY_LOCATION)
	@echo "✓ Service restarted"

# Install dev build to ~/.local/bin
install-dev: cli viewer
	@mkdir -p ~/.local/bin
	@cp grid-server/.build/debug/grid-cli ~/.local/bin/thegrid
	@cp grid-server/.build/debug/grid-viewer ~/.local/bin/grid-viewer
	@echo "✓ Installed dev CLI to ~/.local/bin/thegrid"
	@echo "✓ Installed grid-viewer to ~/.local/bin/grid-viewer"

# Tail server logs (real-time streaming)
tail-server:
	@tail -f ~/.local/state/thegrid/thegrid-server.json | jq --unbuffered -c '{ev: .ev, data: .data}'

# Tail both logs
tail:
	@tail -f ~/.local/state/thegrid/*.json | jq --unbuffered -c '{ev: .ev, data: .data}'

# Reset accessibility permissions (use when TCC gets confused)
reset-accessibility:
	@./scripts/reset-accessibility.sh

# Setup code signing certificate (one-time)
setup-signing:
	@./scripts/create-dev-certificate.sh

# --- grid-mcp (MCP server) ---

MCP_BINARY := grid-mcp/.build/debug/GridMCP
MCP_INSTALL_PATH := $(HOME)/.local/bin/grid-mcp

# Build grid-mcp debug binary
mcp:
	cd grid-mcp && swift build
	@echo "✓ GridMCP built"

# Build and symlink grid-mcp binary (changes reflected immediately on next call)
mcp-dev: mcp
	@mkdir -p $(HOME)/.local/bin
	@ln -sf $(CURDIR)/$(MCP_BINARY) $(MCP_INSTALL_PATH)
	@echo "✓ GridMCP symlinked to $(MCP_INSTALL_PATH)"

# Install grid-mcp binary (copy, for stable installs)
mcp-install: mcp
	@mkdir -p $(HOME)/.local/bin
	@cp $(CURDIR)/$(MCP_BINARY) $(MCP_INSTALL_PATH)
	@echo "✓ GridMCP installed to $(MCP_INSTALL_PATH)"
