.PHONY: help build server cli test clean server-test cli-test server-clean cli-clean run-server install

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

# Show help
help:
	@echo "TheGrid Monorepo Build System"
	@echo ""
	@echo "Main targets:"
	@echo "  all/build        - Build both server and CLI (default)"
	@echo "  test             - Run all tests"
	@echo "  clean            - Clean all build artifacts"
	@echo "  verify           - Build and test everything"
	@echo ""
	@echo "Server targets:"
	@echo "  server           - Build grid-server (debug)"
	@echo "  server-release   - Build grid-server (release)"
	@echo "  server-test      - Run grid-server tests"
	@echo "  server-clean     - Clean grid-server build"
	@echo "  run-server       - Build and run grid-server (debug)"
	@echo ""
	@echo "CLI targets:"
	@echo "  cli              - Build grid-cli"
	@echo "  cli-test         - Run grid-cli tests"
	@echo "  cli-clean        - Clean grid-cli build"
	@echo "  cli-install      - Install grid-cli to \$$GOPATH/bin"
	@echo ""
	@echo "Usage examples:"
	@echo "  make              # Build everything"
	@echo "  make server       # Build just the server"
	@echo "  make cli          # Build just the CLI"
	@echo "  make test         # Run all tests"
	@echo "  make run-server   # Build and run the server"
