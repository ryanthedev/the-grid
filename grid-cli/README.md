# Grid CLI

Command-line client for theGrid macOS window manager.

## Installation

```bash
cd grid-cli
make build      # Build to ./bin/thegrid
make install    # Install to $GOPATH/bin
```

## Quick Start

```bash
thegrid ping                    # Test server connection
thegrid info                    # Get server info
thegrid list windows            # List all windows
thegrid layout apply ide        # Apply a layout
thegrid focus right             # Move focus to adjacent cell
```

## Commands

### Connectivity
```bash
thegrid ping                    # Test server connection
thegrid info                    # Get server information
thegrid dump                    # Dump complete state (JSON)
```

### Listing
```bash
thegrid list windows [--all]    # List windows (--all includes minimized/hidden)
thegrid list spaces             # List all spaces
thegrid list displays           # List all displays
thegrid list apps               # List all applications
```

### Window Management
```bash
thegrid window get <id>                              # Get window details
thegrid window find <pattern>                        # Find windows by title/app
thegrid window update <id> --x X --y Y --w W --h H   # Move/resize window
thegrid window to-space <id> <space-id>              # Move to space
thegrid window to-display <id> <uuid>                # Move to display
```

### Window Properties (requires MSS)
```bash
thegrid window set-opacity <id> <0.0-1.0>            # Set window opacity
thegrid window fade-opacity <id> <opacity> <duration> # Animated opacity
thegrid window get-opacity <id>                      # Get current opacity
thegrid window set-layer <id> <layer>                # Set window layer
thegrid window get-layer <id>                        # Get window layer
thegrid window set-sticky <id> <true|false>          # Set sticky (all spaces)
thegrid window is-sticky <id>                        # Check if sticky
thegrid window minimize <id>                         # Minimize window
thegrid window unminimize <id>                       # Unminimize window
thegrid window is-minimized <id>                     # Check if minimized
```

### Space Management (requires MSS)
```bash
thegrid space create <display-space-id>              # Create new space
thegrid space destroy <space-id>                     # Destroy space
thegrid space focus <space-id>                       # Focus space
```

### Layout Management
```bash
thegrid layout list                   # List available layouts
thegrid layout show <id>              # Show layout details
thegrid layout apply <id> [--space N] # Apply layout to current/specified space
thegrid layout cycle                  # Cycle to next layout
thegrid layout current                # Show current layout
thegrid layout reapply                # Reapply current layout
```

### Focus Navigation
```bash
thegrid focus left [--wrap]           # Focus cell to the left
thegrid focus right [--wrap]          # Focus cell to the right
thegrid focus up [--wrap]             # Focus cell above
thegrid focus down [--wrap]           # Focus cell below
thegrid focus next                    # Next window in cell
thegrid focus prev                    # Previous window in cell
thegrid focus cell <id>               # Focus specific cell by ID
```

### Resize
```bash
thegrid resize grow [amount]          # Grow focused window (default 10%)
thegrid resize shrink [amount]        # Shrink focused window
thegrid resize reset [--all]          # Reset splits in cell (--all for all)
```

### Cell Management
```bash
thegrid cell send <direction>         # Send window to adjacent cell
```

### Configuration
```bash
thegrid config show                   # Display current config
thegrid config validate [path]        # Validate config file
thegrid config init                   # Create default config
```

### State Management
```bash
thegrid state show                    # Show runtime state
thegrid state reset                   # Clear all state
```

### Debug
```bash
thegrid show layout                   # ASCII visualization of layout
thegrid show display <index>          # Show display info
thegrid render <space-id>             # Render window positions (JSON)
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
