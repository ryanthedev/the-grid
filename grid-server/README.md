# Grid Server

Swift-based Unix domain socket server for macOS window management, providing real-time access to macOS Spaces and window management APIs.

## Overview

Grid Server is a high-performance server that:
- Listens on a Unix domain socket for JSON-RPC requests
- Provides real-time access to macOS window and space information
- Broadcasts events when windows or spaces change
- Uses private macOS APIs via a scripting addition for enhanced capabilities

## Architecture

### Core Components

- **`main.swift`**: Entry point and server initialization
- **`SocketServer.swift`**: Unix domain socket server implementation
- **`MessageHandler.swift`**: JSON-RPC request/response handler
- **`EventBroadcaster.swift`**: Event broadcasting to all connected clients
- **`StateManager.swift`**: Central state management for spaces and windows
- **`WindowManipulator.swift`**: Window manipulation operations
- **`ApplicationObserver.swift`**: Observes application lifecycle events
- **`WorkspaceObserver.swift`**: Observes workspace and space changes
- **`DisplayInfo.swift`**: Display and screen information
- **`MacOSAPIs.swift`**: macOS private API bindings
- **`ScriptingAdditionClient.swift`**: Communication with the scripting addition
- **`PermissionChecker.swift`**: Accessibility permission verification

### Data Models

- **`StateModels.swift`**: Core data models (Space, Window, Application, etc.)
- **`Models/Message.swift`**: JSON-RPC message types

## Building

### From Grid Server Directory

```bash
# Debug build
swift build -c debug

# Release build
swift build -c release

# Run tests
swift test

# Clean build artifacts
swift package clean
```

### From Repository Root

```bash
# Use the monorepo Makefile
make server           # Debug build
make server-release   # Release build
make server-test      # Run tests
make server-clean     # Clean artifacts
make run-server       # Build and run
```

## Running

### Command-Line Options

```
USAGE: grid-server [OPTIONS]

OPTIONS:
  -s, --socket-path <socket-path>
                          Path to the Unix domain socket (default: /tmp/grid-server.sock)
  -v, --verbose           Enable verbose logging
  -d, --debug             Enable debug logging
  --heartbeat             Enable periodic heartbeat events for testing
  --heartbeat-interval <heartbeat-interval>
                          Heartbeat interval in seconds (default: 10.0)
  --version               Show the version
  -h, --help              Show help information
```

### Examples

```bash
# Run with defaults
./grid-server/.build/debug/grid-server

# Custom socket path
./grid-server/.build/debug/grid-server --socket-path /tmp/my-grid.sock

# Verbose logging
./grid-server/.build/debug/grid-server --verbose

# Debug logging with heartbeat
./grid-server/.build/debug/grid-server --debug --heartbeat --heartbeat-interval 5
```

## Development

### Adding New RPC Methods

1. Register the method in `MessageHandler.swift`:

```swift
register(method: "myMethod") { [weak self] request, completion in
    guard let self = self else { return }

    // Extract parameters
    let params = request.params?.value as? [String: Any]

    // Perform operation
    let result = self.performOperation(params)

    // Return response
    let response = Response(
        id: request.id,
        result: AnyCodable(result),
        error: nil
    )
    completion(response)
}
```

2. Add error handling as needed
3. Document the method in the protocol documentation

### Adding New Events

Use the `EventBroadcaster` to send events to all connected clients:

```swift
eventBroadcaster.sendEvent(
    type: "myEvent",
    data: [
        "key": "value",
        "timestamp": Date().timeIntervalSince1970
    ]
)
```

### Observing System Events

To observe workspace or application events:

1. Add observers in `WorkspaceObserver.swift` or `ApplicationObserver.swift`
2. Handle the event and update `StateManager`
3. Broadcast events to clients via `EventBroadcaster`

### Using Private APIs

Private macOS APIs are accessed through:
- **`MacOSAPIs.swift`**: Direct API calls using dyld runtime
- **`ScriptingAdditionClient.swift`**: Calls to the scripting addition for privileged operations

Always check permissions before accessing private APIs:

```swift
if !PermissionChecker.hasAccessibilityPermissions() {
    // Handle missing permissions
}
```

## Testing

### Unit Tests

```bash
swift test
```

### Manual Testing

Use the grid-cli client or test scripts to verify functionality:

```bash
# From the root directory
cd grid-cli
make run-ping    # Test connectivity
make run-info    # Get server info
make run-dump    # Dump state
```

## Debugging

### VSCode

The project includes VSCode debug configurations:

1. Open the repository root in VSCode
2. Press F5 or select Run → Start Debugging
3. Choose "Debug GridServer" from the dropdown

### LLDB

```bash
# Build with debug symbols
swift build -c debug

# Run with LLDB
lldb .build/debug/grid-server

# Set breakpoints
(lldb) breakpoint set --name main
(lldb) run
```

### Logging

The server uses different log levels:

- **Normal**: Important operations and errors
- **Verbose** (`--verbose`): Detailed operation logs
- **Debug** (`--debug`): All operations including internal state changes

## Performance Considerations

- The server uses asynchronous I/O for socket operations
- State updates are batched when possible
- Events are broadcast efficiently to all connected clients
- Memory usage is monitored and minimized

## Security

- The server listens only on a Unix domain socket (local connections only)
- File permissions on the socket should be set appropriately
- Accessibility permissions are required for window management
- The scripting addition requires additional permissions for some operations

## Dependencies

Managed via Swift Package Manager:

- **swift-argument-parser**: Command-line argument parsing
- **swift-log**: Structured logging

## Requirements

- macOS 13.0 or later
- Swift 5.9 or later
- Xcode Command Line Tools
- Accessibility permissions for full functionality

## License

MIT License - See LICENSE file for details
