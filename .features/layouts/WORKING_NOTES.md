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
| 1 | Config Parser | Not Started |
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

// Existing models
import "github.com/yourusername/grid-cli/internal/models"
```

## Testing

```bash
# Run all tests
cd grid-cli && go test ./...

# Run specific package tests
go test ./internal/types/... -v
```

## Notes for Future Phases

### Phase 1 (Config Parser)
- Will add JSON/YAML struct tags to types
- Needs to parse track size strings like "1fr", "300px", "minmax(200px, 1fr)"

### Phase 2 (Grid Engine)
- Uses `Rect`, `TrackSize`, `Cell` from Phase 0
- Calculates pixel positions from track definitions

### Phase 4 (Window Assignment)
- Uses `AssignmentStrategy` from Phase 0
- Maps windows to cells based on rules
