# GridWM Layout Feature - Working Notes

This document tracks context and knowledge for implementing the GridWM layout feature across phases.

## Project Overview

- **theGrid**: macOS window management system
- **grid-server** (Swift): Unix socket server providing window/space/display APIs
- **grid-cli** (Go): CLI client at `github.com/yourusername/grid-cli`

## Phase Status

| Phase | Description | Status |
|-------|-------------|--------|
| 0 | Shared Types | Completed |
| 1 | Config Parser | Completed |
| 2 | Grid Engine | Not Started |
| 3 | State Manager | Not Started |
| 4 | Window Assignment | Not Started |
| 5 | CLI Commands | Not Started |
| 6 | Focus Navigation | Not Started |
| 7 | Split Ratios | Not Started |

## Key Files

### Created in Phase 0
- `grid-cli/internal/types/layout_types.go` - Shared type definitions
- `grid-cli/internal/types/layout_types_test.go` - Tests for types

### Created in Phase 1
- `grid-cli/internal/config/types.go` - Config structs with YAML/JSON tags
- `grid-cli/internal/config/parser.go` - Track size parsing, areas conversion
- `grid-cli/internal/config/validate.go` - Configuration validation
- `grid-cli/internal/config/config.go` - Loading and conversion to types.Layout
- `grid-cli/internal/config/config_test.go` - Tests (17 tests)

### Existing Reference Files
- `grid-cli/internal/models/state.go` - Existing Window/Space/Display types
- `grid-cli/internal/models/envelope.go` - RPC message types
- `grid-cli/internal/client/client.go` - Server communication

## Architecture Notes

### Type Organization
- **`internal/models/`** - Server state types (Window, Space, Display, Application)
- **`internal/types/`** - Layout calculation types (NEW - for GridWM feature)

### Coordinate Systems
- Server uses global screen coordinates with origin at top-left
- Window IDs are `uint32`, Space IDs are `uint64`
- Frame is `{X, Y, Width, Height}` in pixels

### Key Concepts from Spec
1. **Layouts are fixed, windows are dynamic** - Grid structure is predefined
2. **Cells contain windows** - Multiple windows can stack in a cell
3. **Stack modes**: vertical, horizontal, tabs
4. **Track sizes**: fr (fractional), px (fixed), auto, minmax

## Import Paths

```go
// Phase 0 types
import "github.com/yourusername/grid-cli/internal/types"

// Phase 1 config
import "github.com/yourusername/grid-cli/internal/config"

// Existing models
import "github.com/yourusername/grid-cli/internal/models"
```

## Testing

```bash
# Run all tests
cd grid-cli && go test ./...

# Run specific package tests
go test ./internal/types/... -v
go test ./internal/config/... -v
```

## Notes for Future Phases

### Phase 2 (Grid Engine)
- Uses `Rect`, `TrackSize`, `Cell` from Phase 0
- Uses `config.LoadConfig()` to load layouts
- Calculates pixel positions from track definitions

### Phase 4 (Window Assignment)
- Uses `AssignmentStrategy` from Phase 0
- Uses `config.GetAppRule()` for app-specific rules
- Maps windows to cells based on rules

## Phase 1 Key APIs

```go
// Load config from file
cfg, err := config.LoadConfig("")  // uses default path

// Load from bytes (for testing)
cfg, err := config.LoadConfigFromBytes(data, "yaml")

// Get a layout as types.Layout
layout, err := cfg.GetLayout("two-column")

// Get layout IDs
ids := cfg.GetLayoutIDs()

// Parse track sizes
ts, err := config.ParseTrackSize("1fr")
ts, err := config.ParseTrackSize("300px")
ts, err := config.ParseTrackSize("minmax(200px, 1fr)")

// Convert areas to cells
cells := config.AreasToCell([][]string{
    {"main", "side"},
    {"main", "side"},
})
```
