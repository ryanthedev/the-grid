# Grid CLI

Command-line client for theGrid macOS window manager.

## Installation

```bash
cd grid-cli
make build      # Build to ./bin/grid
make install    # Install to $GOPATH/bin
```

## Quick Start

```bash
grid ping                    # Test server connection
grid info                    # Get server info
grid list windows            # List all windows
grid layout apply ide        # Apply a layout
grid focus right             # Move focus to adjacent cell
```

## Commands

### Connectivity
```bash
grid ping                    # Test server connection
grid info                    # Get server information
grid dump                    # Dump complete state (JSON)
```

### Listing
```bash
grid list windows [--all]    # List windows (--all includes minimized/hidden)
grid list spaces             # List all spaces
grid list displays           # List all displays
grid list apps               # List all applications
```

### Window Management
```bash
grid window get <id>                              # Get window details
grid window find <pattern>                        # Find windows by title/app
grid window update <id> --x X --y Y --w W --h H   # Move/resize window
grid window to-space <id> <space-id>              # Move to space
grid window to-display <id> <uuid>                # Move to display
```

### Window Properties (requires MSS)
```bash
grid window set-opacity <id> <0.0-1.0>            # Set window opacity
grid window fade-opacity <id> <opacity> <duration> # Animated opacity
grid window get-opacity <id>                      # Get current opacity
grid window set-layer <id> <layer>                # Set window layer
grid window get-layer <id>                        # Get window layer
grid window set-sticky <id> <true|false>          # Set sticky (all spaces)
grid window is-sticky <id>                        # Check if sticky
grid window minimize <id>                         # Minimize window
grid window unminimize <id>                       # Unminimize window
grid window is-minimized <id>                     # Check if minimized
```

### Space Management (requires MSS)
```bash
grid space create <display-space-id>              # Create new space
grid space destroy <space-id>                     # Destroy space
grid space focus <space-id>                       # Focus space
```

### Layout Management
```bash
grid layout list                   # List available layouts
grid layout show <id>              # Show layout details
grid layout apply <id> [--space N] # Apply layout to current/specified space
grid layout cycle                  # Cycle to next layout
grid layout current                # Show current layout
grid layout reapply                # Reapply current layout
```

### Focus Navigation
```bash
grid focus left [--wrap]           # Focus cell to the left
grid focus right [--wrap]          # Focus cell to the right
grid focus up [--wrap]             # Focus cell above
grid focus down [--wrap]           # Focus cell below
grid focus next                    # Next window in cell
grid focus prev                    # Previous window in cell
grid focus cell <id>               # Focus specific cell by ID
```

### Resize
```bash
grid resize grow [amount]          # Grow focused window (default 10%)
grid resize shrink [amount]        # Shrink focused window
grid resize reset [--all]          # Reset splits in cell (--all for all)
```

### Cell Management
```bash
grid cell send <direction>         # Send window to adjacent cell
```

### Configuration
```bash
grid config show                   # Display current config
grid config validate [path]        # Validate config file
grid config init                   # Create default config
```

### State Management
```bash
grid state show                    # Show runtime state
grid state reset                   # Clear all state
```

### Debug
```bash
grid show layout                   # ASCII visualization of layout
grid show display <index>          # Show display info
grid render <space-id>             # Render window positions (JSON)
```

## Global Flags

```
--socket <path>      Custom socket path (default: /tmp/grid-server.sock)
--timeout <duration> Request timeout (default: 30s)
--json               Output in JSON format
--no-color           Disable colored output
--debug              Enable debug logging
```

## MSS Requirements

Commands marked "requires MSS" need the macOS System Suite library for privileged operations (window opacity, layers, space creation/destruction). These will fail gracefully if MSS is not available.

## Project Structure

```
grid-cli/
├── cmd/grid/main.go           # CLI commands
├── internal/
│   ├── cell/                  # Cell window management
│   ├── client/                # Server IPC client
│   ├── config/                # Configuration loading
│   ├── focus/                 # Focus navigation
│   ├── layout/                # Grid engine and calculations
│   ├── logging/               # Structured logging
│   ├── models/                # State models
│   ├── output/                # Table formatting
│   ├── reconcile/             # State synchronization
│   ├── server/                # Server state handling
│   ├── state/                 # Runtime state persistence
│   └── types/                 # Core type definitions
├── go.mod
└── Makefile
```

## Development

```bash
make fmt       # Format code
make vet       # Run go vet
make test      # Run tests
make lint      # Run golangci-lint
```
