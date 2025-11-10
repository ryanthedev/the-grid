# Makefile for Grid Scripting Addition with Mach Injection
# Builds: shellcode → loader → payload → final .osax bundle

# Configuration
PRODUCT_NAME = grid-sa
BUNDLE_NAME = $(PRODUCT_NAME).osax
BUILD_DIR = build
BUNDLE_DIR = $(BUILD_DIR)/$(BUNDLE_NAME)
CONTENTS_DIR = $(BUNDLE_DIR)/Contents
MACOS_DIR = $(CONTENTS_DIR)/MacOS
RESOURCES_DIR = $(CONTENTS_DIR)/Resources
PAYLOAD_BUNDLE_DIR = $(RESOURCES_DIR)/payload.bundle
PAYLOAD_CONTENTS_DIR = $(PAYLOAD_BUNDLE_DIR)/Contents
PAYLOAD_MACOS_DIR = $(PAYLOAD_CONTENTS_DIR)/MacOS

# Compiler settings
CC = clang
CFLAGS = -Wall -Wextra -O2 -fmodules
LDFLAGS = -framework Cocoa -framework Carbon
ARCH_FLAGS = -arch arm64 -arch x86_64

# Colors for output
CYAN = \033[0;36m
GREEN = \033[0;32m
YELLOW = \033[1;33m
NC = \033[0m # No Color

.PHONY: all clean shellcode loader payload bundle install uninstall check logs help

# Default target
all: bundle

# Build everything
bundle: shellcode loader payload
	@echo "$(CYAN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(CYAN)  Assembling final .osax bundle$(NC)"
	@echo "$(CYAN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"

	# Create bundle structure
	@mkdir -p $(MACOS_DIR)
	@mkdir -p $(RESOURCES_DIR)

	# Copy top-level Info.plist
	@cp Info.plist $(CONTENTS_DIR)/

	# Loader is already in place (built in loader target)

	# Payload bundle is already in place (built in payload target)

	# Sign the entire bundle (critical for macOS to recognize it)
	@echo "$(CYAN)Signing bundle...$(NC)"
	@codesign --force --deep --sign - $(BUNDLE_DIR) 2>/dev/null || \
		echo "$(YELLOW)⚠️  Bundle signing failed (may cause runtime issues)$(NC)"
	@echo "$(GREEN)✓ Bundle signed$(NC)"

	@echo ""
	@echo "$(GREEN)✓ Bundle assembled: $(BUNDLE_DIR)$(NC)"
	@echo ""
	@echo "$(GREEN)╔═══════════════════════════════════════╗$(NC)"
	@echo "$(GREEN)║     Build Complete! 🎉                ║$(NC)"
	@echo "$(GREEN)╚═══════════════════════════════════════╝$(NC)"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Install: $(YELLOW)sudo ./install.sh$(NC)"
	@echo "  2. Check:   $(YELLOW)make check$(NC)"
	@echo ""

# Build shellcode
shellcode:
	@echo "$(CYAN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(CYAN)  Stage 1: Building Shellcode$(NC)"
	@echo "$(CYAN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@cd shellcode && ./build_shellcode.sh
	@echo ""

# Build loader
loader: shellcode
	@echo "$(CYAN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(CYAN)  Stage 2: Building Loader$(NC)"
	@echo "$(CYAN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"

	@mkdir -p $(MACOS_DIR)

	$(CC) $(ARCH_FLAGS) $(CFLAGS) $(LDFLAGS) \
		-o $(MACOS_DIR)/loader \
		loader/loader.m

	@chmod +x $(MACOS_DIR)/loader

	# Code sign the loader
	@codesign --force --deep --sign - $(MACOS_DIR)/loader 2>/dev/null || \
		echo "$(YELLOW)⚠️  Code signing failed (not critical)$(NC)"

	@echo "$(GREEN)✓ Loader built: $(MACOS_DIR)/loader$(NC)"
	@echo ""

# Build payload bundle
payload:
	@echo "$(CYAN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(CYAN)  Stage 3: Building Payload Bundle$(NC)"
	@echo "$(CYAN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"

	@mkdir -p $(PAYLOAD_MACOS_DIR)

	# Build payload as a dylib (bundle)
	$(CC) $(ARCH_FLAGS) $(CFLAGS) -dynamiclib \
		-framework Cocoa -framework Carbon \
		-o $(PAYLOAD_MACOS_DIR)/payload \
		payload/payload.m

	# Copy payload Info.plist
	@cp payload/Info.plist $(PAYLOAD_CONTENTS_DIR)/

	# Code sign the payload
	@codesign --force --deep --sign - $(PAYLOAD_MACOS_DIR)/payload 2>/dev/null || \
		echo "$(YELLOW)⚠️  Code signing failed (not critical)$(NC)"

	@echo "$(GREEN)✓ Payload built: $(PAYLOAD_MACOS_DIR)/payload$(NC)"
	@echo ""

# Install (now just points to install script)
install:
	@echo "$(YELLOW)⚠️  Use the installation script:$(NC)"
	@echo "    $(CYAN)sudo ./install.sh$(NC)"
	@echo ""

# Uninstall
uninstall:
	@echo "$(YELLOW)Uninstalling Grid SA...$(NC)"
	@sudo rm -rf /Library/ScriptingAdditions/$(BUNDLE_NAME)
	@sudo rm -f /usr/local/bin/grid-dock-wrapper
	@echo "$(GREEN)✓ Uninstalled$(NC)"
	@echo ""
	@echo "$(YELLOW)Restarting Dock...$(NC)"
	@killall Dock 2>/dev/null || true
	@echo "$(GREEN)✓ Done$(NC)"

# Clean build artifacts
clean:
	@rm -rf $(BUILD_DIR)
	@rm -f shellcode/shellcode.h
	@echo "$(GREEN)✓ Cleaned build directory$(NC)"

# Check if SA is loaded
check:
	@echo "$(CYAN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(CYAN)  Checking Grid SA Status$(NC)"
	@echo "$(CYAN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo ""
	@if [ -e /tmp/grid-sa_$(USER).socket ]; then \
		echo "$(GREEN)✓ Socket exists: /tmp/grid-sa_$(USER).socket$(NC)"; \
		echo "$(GREEN)✓ Grid SA is loaded and running$(NC)"; \
	else \
		echo "$(YELLOW)✗ Socket not found: /tmp/grid-sa_$(USER).socket$(NC)"; \
		echo "$(YELLOW)✗ Grid SA is not loaded or not running$(NC)"; \
		echo ""; \
		echo "Troubleshooting:"; \
		echo "  1. Check if installed:"; \
		echo "     $(CYAN)ls -la /Library/ScriptingAdditions/grid-sa.osax$(NC)"; \
		echo "  2. Run loader:"; \
		echo "     $(CYAN)sudo ./install.sh$(NC)"; \
		echo "  3. Check logs:"; \
		echo "     $(CYAN)make logs$(NC)"; \
	fi
	@echo ""

# Show logs
logs:
	@echo "$(CYAN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(CYAN)  Recent Grid SA Logs$(NC)"
	@echo "$(CYAN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo ""
	@log show --last 5m --style compact 2>&1 | grep -i "GridSA" || echo "No Grid SA logs found"
	@echo ""

# Help
help:
	@echo "$(CYAN)╔═══════════════════════════════════════╗$(NC)"
	@echo "$(CYAN)║   Grid Scripting Addition Build      ║$(NC)"
	@echo "$(CYAN)╚═══════════════════════════════════════╝$(NC)"
	@echo ""
	@echo "Targets:"
	@echo "  $(GREEN)make$(NC)              Build everything"
	@echo "  $(GREEN)make shellcode$(NC)    Build shellcode only"
	@echo "  $(GREEN)make loader$(NC)       Build loader only"
	@echo "  $(GREEN)make payload$(NC)      Build payload only"
	@echo "  $(GREEN)make bundle$(NC)       Assemble final .osax"
	@echo "  $(GREEN)make clean$(NC)        Clean build artifacts"
	@echo ""
	@echo "Installation:"
	@echo "  $(YELLOW)sudo ./install.sh$(NC)  Install and load SA"
	@echo "  $(GREEN)make uninstall$(NC)   Remove SA"
	@echo ""
	@echo "Verification:"
	@echo "  $(GREEN)make check$(NC)        Check if SA is loaded"
	@echo "  $(GREEN)make logs$(NC)         View recent logs"
	@echo ""
