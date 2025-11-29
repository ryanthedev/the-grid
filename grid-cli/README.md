# Grid CLI

A powerful command-line client for GridServer, the macOS window manager.

## Features

- 🔌 Unix domain socket communication
- 🎨 Colorized output with beautiful tables
- 📝 JSON output mode for scripting
- ⚡ Fast and lightweight Go implementation
- 🛠️ Built with Cobra CLI framework

## Installation

### Build from source

```bash
cd grid-cli
make deps    # Download dependencies
make build   # Build to ./bin/grid
make install # Install to $GOPATH/bin
```

## Quick Start

```bash
# Test connectivity
grid ping

# Get server information
grid info

# Dump complete state (JSON)
grid dump

# Use custom socket path
grid --socket /custom/path.sock ping

# JSON output mode
grid info --json
```

## Current Commands

### Connectivity
- `grid ping` - Test server connection
- `grid info` - Get server information and capabilities

### State Queries
- `grid dump` - Dump complete window manager state (JSON output)

## Architecture

### Project Structure

```
grid-cli/
├── cmd/grid/main.go              # Cobra CLI entry point
├── internal/
│   ├── client/
│   │   ├── client.go             # High-level client API
│   │   └── connection.go         # Unix socket connection
│   ├── models/
│   │   └── envelope.go           # Message protocol types
│   ├── output/                   # Output formatting (tables.go)
│   └── config/                   # Configuration loading and validation
├── go.mod
├── Makefile
└── README.md
```

### Protocol

Grid CLI communicates with GridServer using a custom JSON-RPC protocol over Unix domain sockets:

**Message Envelope:**
```json
{
  "type": "request|response|event",
  "request": {...},
  "response": {...},
  "event": {...}
}
```

**Request:**
```json
{
  "id": "uuid",
  "method": "methodName",
  "params": {"key": "value"}
}
```

**Response:**
```json
{
  "id": "uuid",
  "result": {...},
  "error": {"code": -32600, "message": "..."}
}
```

## Extending the CLI

### Adding a New Command

1. **Add the client method** in `internal/client/client.go`:

```go
func (c *Client) ListWindows(ctx context.Context) (map[string]interface{}, error) {
    resp, err := c.request(ctx, "getWindows", nil)
    if err != nil {
        return nil, err
    }
    if resp.IsError() {
        return nil, fmt.Errorf("server error: %s", resp.GetError())
    }
    return resp.Result, nil
}
```

2. **Add the Cobra command** in `cmd/grid/main.go`:

```go
var listWindowsCmd = &cobra.Command{
    Use:   "list-windows",
    Short: "List all windows",
    RunE: func(cmd *cobra.Command, args []string) error {
        c := client.NewClient(socketPath, timeout)
        defer c.Close()

        result, err := c.ListWindows(context.Background())
        if err != nil {
            printError(fmt.Sprintf("Failed: %v", err))
            return err
        }

        if jsonOutput {
            return printJSON(result)
        }

        // Pretty print here
        return nil
    },
}

func init() {
    rootCmd.AddCommand(listWindowsCmd)
}
```

### Adding Table Output

To add beautiful table output (using tablewriter):

1. Create `internal/output/tables.go`:

```go
package output

import (
    "os"
    "github.com/olekukonko/tablewriter"
)

func PrintWindowsTable(windows []map[string]interface{}) {
    table := tablewriter.NewWriter(os.Stdout)
    table.SetHeader([]string{"ID", "Title", "App", "Space"})

    for _, win := range windows {
        table.Append([]string{
            fmt.Sprintf("%v", win["id"]),
            fmt.Sprintf("%v", win["title"]),
            fmt.Sprintf("%v", win["app"]),
            fmt.Sprintf("%v", win["space"]),
        })
    }

    table.Render()
}
```

### Adding State Models

For complex responses, create structured models in `internal/models/`:

```go
// internal/models/window.go
package models

type Window struct {
    ID          int     `json:"id"`
    Title       string  `json:"title"`
    AppName     string  `json:"appName"`
    Frame       Frame   `json:"frame"`
    IsMinimized bool    `json:"isMinimized"`
    Spaces      []int64 `json:"spaces"`
}

type Frame struct {
    X      float64 `json:"x"`
    Y      float64 `json:"y"`
    Width  float64 `json:"width"`
    Height float64 `json:"height"`
}
```

## Available GridServer Methods

The following methods are available in the GridServer API:

- `ping` - Test connectivity
- `getServerInfo` - Get server information
- `dump` - Get complete state
- `getSpaces` - List all spaces
- `getWindows` - List all windows
- `updateWindow` - Update window properties

See the main GridServer README for complete API documentation.

## Implemented Features

### Query Commands
- [x] `grid list spaces` - List all spaces with tables
- [x] `grid list windows` - List windows (with yabai-style filtering, use `--all` for all)
- [x] `grid list apps` - List all applications
- [x] `grid list displays` - List all displays
- [x] `grid window get <id>` - Get specific window details
- [x] Table formatting via `internal/output/`
- [x] Filtering options (`--all` flag)

### Window Manipulation
- [x] `grid window update <id> --x X --y Y --width W --height H` - Move/resize (unified command)
- [x] `grid window to-space <id> <space-id>` - Move to specific space
- [x] `grid window to-display <id> <uuid>` - Move to specific display

### Configuration
- [x] `grid config show` - Display current configuration
- [x] `grid config validate [path]` - Validate config file
- [x] `grid config init` - Create default configuration

## Remaining TODOs

### Configuration Enhancements
- [ ] Add Viper config support
- [ ] Create `~/.gridrc` config file support
- [ ] Support environment variables
- [ ] Add `grid config get/set/list` commands

### Advanced Features
- [ ] Shell completion
- [ ] Batch operations
- [ ] Dry-run mode

## Development

```bash
# Format code
make fmt

# Run linter
make vet

# Run tests
make test

# Quick test
make run-ping
make run-info
```

## Global Flags

- `--socket <path>` - Custom socket path (default: `/tmp/grid-server.sock`)
- `--timeout <duration>` - Request timeout (default: `30s`)
- `--json` - Output in JSON format
- `--no-color` - Disable colored output

## License

MIT

## Contributing

Contributions welcome! Please feel free to submit pull requests or open issues.
