# theGrid

A macOS window management system consisting of a Swift-based Unix domain socket server and a Go CLI client, providing programmatic access to macOS Spaces and Windows APIs.

## Repository Structure

This is a monorepo containing two main components:

- **`grid-server/`**: Swift-based Unix domain socket server for macOS window management
- **`grid-cli/`**: Go-based CLI client for interacting with the server
- **`docs/`**: Documentation and specifications

## Requirements

### Server (`grid-server/`)
- macOS 13.0 or later
- Swift 5.9 or later
- Xcode Command Line Tools

### CLI (`grid-cli/`)
- Go 1.21 or later

### Optional: MSS (macOS Scripting Support)

For advanced window management features on macOS 12.7+, 13.6+, 14.5+, and 15+, theGrid integrates with [MSS](https://github.com/ryanthedev/mss), a privileged helper that provides access to private SkyLight APIs.

**MSS enables:**
- Window opacity control (set, fade, get)
- Window layer management (above, normal, below)
- Sticky windows (visible on all spaces)
- Window minimize/unminimize
- Space creation, destruction, and focusing
- Reliable window-to-space moves on modern macOS versions

**Installation:**
```bash
brew install mss
sudo mss load
```

**Verification:**
```bash
mss --help
```

Note: Window-to-space moves work without MSS on older macOS versions (< 12.7) using direct SkyLight APIs. MSS is required for this functionality on modern macOS versions.

## Building

The repository includes a root `Makefile` for building both components:

### Build Everything

```bash
make build
# or simply
make
```

### Build Server Only

```bash
make server
```

The executable will be located at `grid-server/.build/debug/grid-server`.

### Build CLI Only

```bash
make cli
```

The executable will be located at `grid-cli/bin/grid`.

### Release Build (Server)

```bash
make server-release
```

### Run Tests

```bash
# Run all tests
make test

# Server tests only
make server-test

# CLI tests only
make cli-test
```

### Clean Build Artifacts

```bash
# Clean all components
make clean

# Clean specific component
make server-clean
make cli-clean
```

### Quick Start

```bash
# Build and run the server
make run-server

# In another terminal, use the CLI
cd grid-cli
make run-ping    # Test connectivity
make run-info    # Get server info
make run-dump    # Dump current state
```

See `make help` for all available targets.

## Running

### Server

```bash
# Run with default settings (socket at /tmp/grid-server.sock)
grid-server/.build/debug/grid-server

# Or use the Makefile
make run-server

# Specify custom socket path
grid-server/.build/debug/grid-server --socket-path /tmp/my-socket.sock

# Enable verbose logging
grid-server/.build/debug/grid-server --verbose

# Enable debug logging
grid-server/.build/debug/grid-server --debug

# Enable heartbeat events for testing
grid-server/.build/debug/grid-server --heartbeat --heartbeat-interval 5
```

### CLI

```bash
# Test connectivity
grid-cli/bin/grid ping

# Get server info
grid-cli/bin/grid info

# List all spaces
grid-cli/bin/grid list spaces

# List all windows
grid-cli/bin/grid list windows

# Dump complete state as JSON
grid-cli/bin/grid dump
```

### Server Command-Line Options

```
OPTIONS:
  -s, --socket-path <socket-path>
                          Path to the Unix domain socket (default: /tmp/grid-server.sock)
  -v, --verbose           Enable verbose logging
  -d, --debug             Enable debug logging
  --heartbeat             Enable periodic heartbeat events for testing
  --heartbeat-interval <heartbeat-interval>
                          Heartbeat interval in seconds (default: 10.0)
  --version               Show the version.
  -h, --help              Show help information.
```

## CLI Commands

### Core Commands

```bash
# Test connectivity
grid ping

# Get server information
grid info

# Dump complete state as JSON
grid dump
```

### List Commands

```bash
# List all windows
grid list windows

# List all spaces
grid list spaces

# List all displays
grid list displays

# List all applications
grid list apps
```

### Window Information

```bash
# Get window details
grid window get <window-id>

# Find windows by title pattern
grid window find <pattern>
```

### Window Manipulation

```bash
# Move window to position
grid window move <window-id> --x <x> --y <y>

# Resize window
grid window resize <window-id> --width <width> --height <height>

# Update window position and/or size
grid window update <window-id> [--x <x>] [--y <y>] [--width <width>] [--height <height>]

# Center window on its display
grid window center <window-id>

# Move window to space
grid window to-space <window-id> <space-id>

# Move window to display
grid window to-display <window-id> <display-uuid>
```

### Window Opacity (requires MSS)

```bash
# Set window opacity instantly (0.0 = transparent, 1.0 = opaque)
grid window set-opacity <window-id> <opacity>

# Fade window opacity over time
grid window fade-opacity <window-id> <opacity> <duration-seconds>

# Get current window opacity
grid window get-opacity <window-id>
```

### Window Layer (requires MSS)

```bash
# Set window layer
grid window set-layer <window-id> <layer>  # layer: above, normal, below

# Get current window layer
grid window get-layer <window-id>
```

### Window Sticky/Minimize (requires MSS)

```bash
# Make window sticky (visible on all spaces)
grid window set-sticky <window-id> <true|false>

# Check if window is sticky
grid window is-sticky <window-id>

# Minimize window
grid window minimize <window-id>

# Restore minimized window
grid window unminimize <window-id>

# Check if window is minimized
grid window is-minimized <window-id>
```

### Space Management (requires MSS)

```bash
# Create a new space on a display
grid space create <display-uuid>

# Destroy a space (cannot destroy last space on display)
grid space destroy <space-id>

# Focus/switch to a space
grid space focus <space-id>
```

### Visual Display

```bash
# Show visual layout of all spaces
grid show layout

# Show specific display layout
grid show display <display-uuid>

# Options for show commands
--ascii          # Force ASCII mode (no Unicode)
--unicode        # Force Unicode mode
--no-ids         # Hide window IDs
--width <width>  # Override terminal width
--height <height> # Override terminal height
```

## Common Examples

### Window Workflows

```bash
# Find all Chrome windows
grid window find "Chrome"

# Move a window to the top-left corner
grid window move 12345 --x 0 --y 0

# Resize and move a window
grid window update 12345 --x 100 --y 100 --width 800 --height 600

# Make a window semi-transparent (requires MSS)
grid window set-opacity 12345 0.5

# Make a window always on top (requires MSS)
grid window set-layer 12345 above

# Make a window sticky (visible on all spaces) (requires MSS)
grid window set-sticky 12345 true
```

### Space Management Workflows

```bash
# List all spaces to get IDs
grid list spaces

# Create a new space on the main display
grid space create <display-uuid>

# Move window to a different space
grid window to-space 12345 67890

# Focus a specific space
grid space focus 67890

# Destroy an empty space
grid space destroy 67890
```

### Advanced Workflows

```bash
# Fade a window out over 2 seconds (requires MSS)
grid window fade-opacity 12345 0.0 2.0

# Move window to another display and position it
grid window to-display 12345 <display-uuid>
grid window move 12345 --x 100 --y 100

# Create a picture-in-picture effect (requires MSS)
grid window set-layer 12345 above
grid window set-sticky 12345 true
grid window set-opacity 12345 0.9
grid window resize 12345 --width 400 --height 300
```

### JSON Output

All commands support `--json` for programmatic usage:

```bash
# Get window info as JSON
grid window get 12345 --json

# List all windows as JSON
grid list windows --json

# Check if window is sticky (requires MSS)
grid window is-sticky 12345 --json
```

## Debugging in VSCode

The project includes pre-configured VSCode debugger settings:

1. Open the project in VSCode
2. Install the [CodeLLDB extension](https://marketplace.visualstudio.com/items?itemName=vadimcn.vscode-lldb)
3. Press `F5` or go to Run → Start Debugging
4. Select "Debug GridServer" from the dropdown

### Available Debug Configurations

- **Debug GridServer**: Build and run with full debugging enabled
- **Run GridServer (No Debug)**: Build and run without debugger
- **Attach to GridServer**: Attach debugger to already running process

## JSON Protocol

All messages are newline-delimited JSON objects sent over the Unix domain socket.

### Message Envelope

```json
{
  "type": "request" | "response" | "event",
  "request": { ... } | null,
  "response": { ... } | null,
  "event": { ... } | null
}
```

### Request Message

```json
{
  "type": "request",
  "request": {
    "id": "unique-request-id",
    "method": "methodName",
    "params": { ... } | null
  },
  "response": null,
  "event": null
}
```

### Response Message

```json
{
  "type": "response",
  "request": null,
  "response": {
    "id": "request-id",
    "result": { ... } | null,
    "error": {
      "code": -32600,
      "message": "Error description",
      "data": { ... } | null
    } | null
  },
  "event": null
}
```

### Event Message

```json
{
  "type": "event",
  "request": null,
  "response": null,
  "event": {
    "eventType": "eventName",
    "data": { ... } | null,
    "timestamp": "2025-01-09T12:34:56Z"
  }
}
```

## Available Methods (POC)

Current implementation includes placeholder methods with mock data:

### `ping`

Test server connectivity.

**Request:**
```json
{
  "id": "1",
  "method": "ping",
  "params": null
}
```

**Response:**
```json
{
  "id": "1",
  "result": {
    "pong": true,
    "timestamp": 1704800000.0
  },
  "error": null
}
```

### `echo`

Echo back the provided parameters.

**Request:**
```json
{
  "id": "2",
  "method": "echo",
  "params": {
    "message": "Hello, World!"
  }
}
```

**Response:**
```json
{
  "id": "2",
  "result": {
    "message": "Hello, World!"
  },
  "error": null
}
```

### `getSpaces`

Get list of macOS Spaces (mock data).

**Request:**
```json
{
  "id": "3",
  "method": "getSpaces",
  "params": null
}
```

**Response:**
```json
{
  "id": "3",
  "result": {
    "spaces": [
      {"id": 1, "name": "Space 1", "index": 0},
      {"id": 2, "name": "Space 2", "index": 1},
      {"id": 3, "name": "Space 3", "index": 2}
    ]
  },
  "error": null
}
```

### `getWindows`

Get list of windows (mock data).

**Request:**
```json
{
  "id": "4",
  "method": "getWindows",
  "params": null
}
```

**Response:**
```json
{
  "id": "4",
  "result": {
    "windows": [
      {"id": 101, "title": "Terminal", "app": "Terminal", "space": 1},
      {"id": 102, "title": "Safari", "app": "Safari", "space": 1},
      {"id": 103, "title": "VSCode", "app": "Code", "space": 2}
    ]
  },
  "error": null
}
```

### `getServerInfo`

Get server information and capabilities.

**Request:**
```json
{
  "id": "5",
  "method": "getServerInfo",
  "params": null
}
```

**Response:**
```json
{
  "id": "5",
  "result": {
    "name": "GridServer",
    "version": "0.1.0",
    "platform": "macOS",
    "capabilities": {
      "spaces": false,
      "windows": false,
      "events": true
    }
  },
  "error": null
}
```

### `subscribe`

Subscribe to events (placeholder).

**Request:**
```json
{
  "id": "6",
  "method": "subscribe",
  "params": {
    "eventType": "all"
  }
}
```

**Response:**
```json
{
  "id": "6",
  "result": {
    "subscribed": true
  },
  "error": null
}
```

## Events

The server can broadcast events to all connected clients.

### `heartbeat`

Periodic heartbeat event (when `--heartbeat` is enabled).

```json
{
  "type": "event",
  "event": {
    "eventType": "heartbeat",
    "data": {
      "timestamp": 1704800000.0,
      "uptime": 12345.67
    },
    "timestamp": "2025-01-09T12:34:56Z"
  }
}
```

### Future Events

Planned events for macOS API integration:

- `spaceChanged`: Triggered when active space changes
- `windowEvent`: Triggered on window creation/destruction/focus/etc.

## Development

### Project Structure

Each component has its own development workflow:

- **Server**: See [`grid-server/README.md`](grid-server/README.md) for server-specific development
- **CLI**: See [`grid-cli/README.md`](grid-cli/README.md) for CLI-specific development

### Adding New Methods (Server)

1. Register a new handler in `grid-server/Sources/GridServer/MessageHandler.swift`:

```swift
register(method: "myMethod") { request, completion in
    // Handle the request
    let result = ["key": "value"]
    let response = Response(id: request.id, result: AnyCodable(result))
    completion(response)
}
```

2. Document the method in the protocol documentation below

### Adding New Events (Server)

Use the `EventBroadcaster` to send events:

```swift
eventBroadcaster.sendEvent(
    type: "myEvent",
    data: ["key": "value"]
)
```

## Roadmap

### Completed
- [x] Integrate real macOS Spaces API
- [x] Integrate macOS Windows management API
- [x] Implement window move/resize/center commands
- [x] Implement window-to-space and window-to-display moves
- [x] Integrate MSS for advanced window management
- [x] Window opacity control (set, fade, get)
- [x] Window layer management (above, normal, below)
- [x] Sticky windows and minimize/unminimize
- [x] Space creation, destruction, and focusing
- [x] Visual layout display with ASCII/Unicode support

### In Progress
- [ ] Comprehensive test suite

### Planned
- [ ] Window focus commands
- [ ] Add authentication/authorization
- [ ] Add client library implementations (Node.js, Python, etc.)
- [ ] Performance optimizations
- [ ] Additional window management features

## License

MIT License - See LICENSE file for details

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## Support

For issues and questions, please open an issue on GitHub.
