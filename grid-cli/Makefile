.PHONY: build install clean test run-ping run-info deps

BINARY_NAME=grid
BUILD_DIR=bin
GO=go
GOFLAGS=-v

# Build the CLI
build:
	@echo "Building $(BINARY_NAME)..."
	@mkdir -p $(BUILD_DIR)
	$(GO) build $(GOFLAGS) -o $(BUILD_DIR)/$(BINARY_NAME) ./cmd/grid

# Install to $GOPATH/bin
install:
	@echo "Installing $(BINARY_NAME)..."
	$(GO) install $(GOFLAGS) ./cmd/grid

# Clean build artifacts
clean:
	@echo "Cleaning..."
	@rm -rf $(BUILD_DIR)
	$(GO) clean

# Download dependencies
deps:
	@echo "Downloading dependencies..."
	$(GO) mod download
	$(GO) mod tidy

# Run tests
test:
	$(GO) test -v ./...

# Quick test commands
run-ping: build
	@echo "Testing ping..."
	@$(BUILD_DIR)/$(BINARY_NAME) ping

run-info: build
	@echo "Getting server info..."
	@$(BUILD_DIR)/$(BINARY_NAME) info

run-dump: build
	@echo "Dumping state..."
	@$(BUILD_DIR)/$(BINARY_NAME) dump | head -50

# Development helpers
fmt:
	$(GO) fmt ./...

vet:
	$(GO) vet ./...

lint:
	golangci-lint run

# Show help
help:
	@echo "Available targets:"
	@echo "  build      - Build the grid CLI"
	@echo "  install    - Install to \$$GOPATH/bin"
	@echo "  clean      - Remove build artifacts"
	@echo "  deps       - Download and tidy dependencies"
	@echo "  test       - Run tests"
	@echo "  run-ping   - Build and test ping command"
	@echo "  run-info   - Build and test info command"
	@echo "  run-dump   - Build and test dump command"
	@echo "  fmt        - Format code"
	@echo "  vet        - Run go vet"
	@echo "  lint       - Run golangci-lint"
