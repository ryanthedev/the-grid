#!/usr/bin/env bash
# Grid Scripting Addition Installer
# Installs and loads the Grid SA using Mach port injection

set -e

SA_PATH="/Library/ScriptingAdditions/grid-sa.osax"
USER=$(whoami)

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

print_header() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Grid Scripting Addition Installer   ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""
}

print_status() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
    if [ -n "$2" ]; then
        echo -e "${YELLOW}   💡 $2${NC}"
    fi
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run with sudo" "Usage: sudo ./install.sh"
        exit 1
    fi
}

check_sip() {
    echo "Checking System Integrity Protection..."
    SIP_STATUS=$(csrutil status)

    if echo "$SIP_STATUS" | grep -q "Filesystem Protections: disabled"; then
        print_status "SIP filesystem protections are disabled"
    else
        print_error "SIP filesystem protections must be disabled"
        echo ""
        echo "To disable SIP:"
        echo "  1. Reboot into Recovery Mode"
        echo "     Intel: Hold Cmd+R during boot"
        echo "     Apple Silicon: Hold Power button until options appear"
        echo "  2. Open Terminal from Utilities menu"
        echo "  3. Run: csrutil enable --without fs --without debug"
        echo "  4. Reboot normally"
        exit 1
    fi

    if echo "$SIP_STATUS" | grep -q "Debugging Restrictions: disabled"; then
        print_status "SIP debugging restrictions are disabled"
    else
        print_warning "SIP debugging restrictions should be disabled"
        print_warning "Injection may fail without this"
    fi
}

build_if_needed() {
    if [ ! -f "build/grid-sa.osax/Contents/MacOS/loader" ]; then
        echo ""
        echo -e "${CYAN}Building Grid SA...${NC}"
        make clean && make
    fi
}

install_bundle() {
    echo ""
    echo "Installing Grid SA to $SA_PATH..."

    # Remove old installation
    rm -rf "$SA_PATH"

    # Copy new bundle
    cp -r "build/grid-sa.osax" "$SA_PATH"
    chmod -R 755 "$SA_PATH"

    print_status "Installed to $SA_PATH"
}

run_loader() {
    echo ""
    echo -e "${CYAN}Running loader to inject into Dock...${NC}"
    echo ""

    # Run the loader
    /Library/ScriptingAdditions/grid-sa.osax/Contents/MacOS/loader

    local EXIT_CODE=$?
    if [ $EXIT_CODE -ne 0 ]; then
        echo ""
        print_error "Loader failed with exit code $EXIT_CODE"
        print_error "Check Console.app for error messages"
        exit 1
    fi
}

verify_installation() {
    echo "Verifying installation..."

    local SOCKET_PATH="/tmp/grid-sa_$USER.socket"

    if [ -e "$SOCKET_PATH" ]; then
        print_status "Socket exists: $SOCKET_PATH"
        print_status "Grid SA is loaded and running"
        return 0
    else
        print_warning "Socket not found: $SOCKET_PATH"
        print_warning "Grid SA may not have loaded correctly"
        echo ""
        echo "Troubleshooting:"
        echo "  1. Check Console.app for [GridSA] logs from Dock process"
        echo "  2. Try: make logs"
        echo "  3. Verify installation: ls -laR $SA_PATH"
        return 1
    fi
}

# Main installation flow
main() {
    print_header

    # Pre-flight checks
    check_root
    check_sip

    # Build
    build_if_needed

    # Install
    install_bundle

    # Run loader to inject
    run_loader

    # Verify
    echo ""
    verify_installation

    # Success message
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       Installation Complete! 🎉       ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo "Grid SA is now active and ready to use."
    echo ""
    echo "Next steps:"
    echo "  • Build GridServer: cd .. && swift build"
    echo "  • Start server:     .build/debug/grid-server"
    echo "  • Test movement:    ./test-window-move.py"
    echo ""
}

main "$@"
