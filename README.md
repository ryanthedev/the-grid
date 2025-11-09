# theGrid

A Swift-based Unix domain socket server for macOS window management, providing programmatic access to macOS Spaces and Windows APIs.

## Overview

This project contains multiple sub-projects. The first is **GridServer**, a Swift application that exposes macOS Spaces and Windows APIs through a Unix domain socket interface using JSON messages.

### Features

- **Unix Domain Socket Server**: Efficient IPC using Unix domain sockets
- **JSON Message Protocol**: Bidirectional communication supporting both request/response and event streaming
- **Request/Response Pattern**: RPC-style method calls with results
- **Event Streaming**: Real-time event notifications to connected clients
- **CLI Interface**: Easy-to-use command-line interface with argument parsing
- **Debug Support**: Full VSCode debugger integration with lldb
- **Structured Logging**: Configurable log levels for development and production

### Current Status

This is a proof-of-concept implementation. The socket infrastructure and message protocol are fully functional with mock data. macOS Spaces and Windows API integration is planned for future releases.

## Project Structure

```
theGrid/
├── Sources/
│   └── GridServer/
│       ├── main.swift                  # CLI entry point
│       ├── SocketServer.swift          # Unix domain socket server
│       ├── MessageHandler.swift        # Request routing and handling
│       ├── EventBroadcaster.swift      # Event streaming
│       └── Models/
│           └── Message.swift           # JSON message models
├── Tests/
│   └── GridServerTests/
├── .vscode/
│   ├── launch.json                     # VSCode debugger config
│   └── tasks.json                      # Build tasks
├── test-client.py                      # Python test client
├── Package.swift                       # Swift Package Manager manifest
└── README.md
```

## Requirements

- macOS 13.0 or later
- Swift 5.9 or later
- Xcode Command Line Tools
- Python 3.7+ (for test client)

## Building

### Debug Build

```bash
swift build -c debug
```

The executable will be located at `.build/debug/grid-server`.

### Release Build

```bash
swift build -c release
```

The executable will be located at `.build/release/grid-server`.

### Clean Build

```bash
swift package clean
```

## Running

### Basic Usage

```bash
# Run with default settings (socket at /tmp/grid-server.sock)
.build/debug/grid-server

# Specify custom socket path
.build/debug/grid-server --socket-path /tmp/my-socket.sock

# Enable verbose logging
.build/debug/grid-server --verbose

# Enable debug logging
.build/debug/grid-server --debug

# Enable heartbeat events for testing
.build/debug/grid-server --heartbeat --heartbeat-interval 5
```

### Command-Line Options

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

## Testing with the Test Client

A Python test client is included for easy testing and demonstration.

### Interactive Mode

```bash
# Start the server
.build/debug/grid-server --debug --heartbeat

# In another terminal, run the test client
./test-client.py

# Available commands in interactive mode:
#   ping                 - Send a ping request
#   echo <json>          - Echo back JSON params
#   spaces               - Get spaces (mock data)
#   windows              - Get windows (mock data)
#   info                 - Get server info
#   subscribe <type>     - Subscribe to events
#   event <type> <json>  - Send an event
#   quit                 - Quit
```

### Automated Tests

```bash
./test-client.py --test
```

### Custom Socket Path

```bash
./test-client.py --socket /path/to/custom.sock
```

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

### Adding New Methods

1. Register a new handler in `MessageHandler.swift`:

```swift
register(method: "myMethod") { request, completion in
    // Handle the request
    let result = ["key": "value"]
    let response = Response(id: request.id, result: AnyCodable(result))
    completion(response)
}
```

2. Document the method in this README

### Adding New Events

Use the `EventBroadcaster` to send events:

```swift
eventBroadcaster.sendEvent(
    type: "myEvent",
    data: ["key": "value"]
)
```

## Roadmap

- [ ] Integrate real macOS Spaces API
- [ ] Integrate macOS Windows management API
- [ ] Implement window focus/move/resize commands
- [ ] Implement space switching commands
- [ ] Add authentication/authorization
- [ ] Add client library implementations (Node.js, Python, etc.)
- [ ] Performance optimizations
- [ ] Comprehensive test suite

## License

MIT License - See LICENSE file for details

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## Support

For issues and questions, please open an issue on GitHub.
