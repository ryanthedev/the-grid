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
thegrid window move <direction>                      # Move window to adjacent cell
thegrid window swap <direction>                      # Swap window with adjacent cell
```

**Window Move/Swap Flags:**
- `--extend` - Extend to adjacent monitors when no cell exists
- `--mouse, -m` - Move mouse cursor to moved window
- `--wrap` (default: true) - Wrap around to opposite edge

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
thegrid focus left                    # Focus cell to the left
thegrid focus right                   # Focus cell to the right
thegrid focus up                      # Focus cell above
thegrid focus down                    # Focus cell below
thegrid focus next                    # Next window in cell
thegrid focus prev                    # Previous window in cell
thegrid focus cell <id>               # Jump focus to specific cell ID
```

**Focus Command Flags:**
- `--extend` - Extend focus to adjacent monitors when no cell exists
- `--mouse, -m` - Move mouse cursor to focused window
- `--wrap` (default: true) - Wrap around to opposite edge

### Unified Launcher (Pick)

Search and launch windows, applications, Chrome profiles, zoxide directories, and custom actions in a single unified picker.

```bash
thegrid pick                           # All sources (windows, apps, chrome, actions, zoxide)
thegrid pick --only windows            # Just windows
thegrid pick --only apps,chrome        # Multiple sources
thegrid pick --exclude chrome          # All sources except Chrome
thegrid pick window                    # Backwards compat - just windows
```

**Picker Features:**
- Fuzzy search across all enabled sources
- Frecency-based sorting (frequently used items appear first)
- Hybrid icon support (SF Symbols + app icons)
- Treats hyphens/underscores as spaces in search (e.g., "google-chrome" matches "google chrome")
- Window title enrichment:
  - SSH: Displays "user@host" with remote working directory/command
  - Tmux: Displays session:window with pane commands
  - Chrome: Displays page title with profile name as subtitle

**Source Priority (for tie-breaking in search):**
- Windows: 1000x (active work, highest priority)
- Actions: 1.5x
- Apps: 1x
- Chrome: 1x
- Zoxide: 0.5x

**Picker Actions:**
- Window → Focus the window
- App → Launch the application
- Chrome profile → Open Chrome with the profile
- Zoxide directory → Open in terminal (Ghostty)
- Action → Execute the configured command

### Resize
```bash
thegrid resize grow [amount]          # Grow focused window (default 10%)
thegrid resize shrink [amount]        # Shrink focused window
thegrid resize reset                  # Reset splits in focused cell
```

**Resize Reset Flags:**
- `--all` - Reset all window splits, not just focused cell
- `--cells` - Reset cell/track ratios to layout defaults

### Cell Management
```bash
thegrid cell send <direction>         # Send window to adjacent cell
```

### Mouse Control
```bash
thegrid mouse center                  # Move mouse to focused window center
thegrid mouse warp <window-id>        # Move mouse to specific window
```

### Configuration
```bash
thegrid config show                   # Display current config
thegrid config validate [path]        # Validate config file
thegrid config init                   # Create default config
```

**Picker Configuration:**

Configure which sources are enabled and add custom actions in `~/.config/thegrid/config.yaml`:

```yaml
picker:
  sources:
    windows: true      # Search active windows
    apps: true         # Search applications
    chrome:
      enabled: true    # Search Chrome profiles
    actions: true      # Search custom actions
    zoxide: true       # Search zoxide directories

  actions:
    - name: "New Terminal"
      command: "open -na Ghostty"
      category: "Actions"
      icon: "terminal"  # SF Symbol name

    - name: "Lock Screen"
      command: "pmset displaysleepnow"
      category: "System"
      icon: "lock"
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
```

All CLI logs are written to `~/.local/state/thegrid/thegrid-cli.json` in JSONL format.

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
│   ├── enrichers/             # Window context enrichment (SSH, tmux, Chrome profiles)
│   ├── focus/                 # Focus navigation
│   ├── layout/                # Grid engine and calculations
│   ├── logging/               # Structured logging
│   ├── models/                # State models
│   ├── output/                # Table formatting
│   ├── reconcile/             # State synchronization
│   ├── server/                # Server state handling
│   ├── sources/               # Picker source discovery (apps, chrome, actions, zoxide)
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
