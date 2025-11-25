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
| 2 | Grid Engine | Completed |
| 3 | State Manager | Completed |
| 4 | Window Assignment | Completed |
| 5 | CLI Commands | Completed |
| 6 | Focus Navigation | Completed |
| 7 | Split Ratios | Completed |

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

### Created in Phase 2
- `grid-cli/internal/layout/grid.go` - Track calculations, main CalculateLayout entry point
- `grid-cli/internal/layout/cells.go` - Cell bounds, adjacency, sorting
- `grid-cli/internal/layout/windows.go` - Window stacking (vertical, horizontal, tabs)
- `grid-cli/internal/layout/grid_test.go` - Track calculation tests (14 tests)
- `grid-cli/internal/layout/cells_test.go` - Cell bounds tests (12 tests)
- `grid-cli/internal/layout/windows_test.go` - Window stacking tests (14 tests)

### Created in Phase 3
- `grid-cli/internal/state/state.go` - RuntimeState, SpaceState, CellState types & operations
- `grid-cli/internal/state/persistence.go` - Load/Save to ~/.local/state/thegrid/state.json
- `grid-cli/internal/state/queries.go` - Query helpers for window assignments, layouts, etc.
- `grid-cli/internal/state/state_test.go` - Tests (31 tests)

### Created in Phase 4
- `grid-cli/internal/layout/assignment.go` - Window-to-cell assignment strategies
- `grid-cli/internal/layout/apply.go` - Layout application orchestration
- `grid-cli/internal/layout/reconcile.go` - State sync with server
- `grid-cli/internal/layout/assignment_test.go` - Tests (19 tests)

### Modified in Phase 5
- `grid-cli/cmd/grid/main.go` - Added 15 new CLI commands for layout management

### Created in Phase 6
- `grid-cli/internal/focus/focus.go` - Main orchestration (MoveFocus, FocusCell, CycleFocusInCell)
- `grid-cli/internal/focus/navigation.go` - Directional navigation algorithms (FindTargetCell, distance calculations)
- `grid-cli/internal/focus/within_cell.go` - Window cycling (CycleWindowIndex, helpers)
- `grid-cli/internal/focus/focus_test.go` - Tests (27 tests)

### Created in Phase 7
- `grid-cli/internal/layout/splits.go` - Split ratio calculations (InitializeSplitRatios, AdjustSplitRatio, etc.)
- `grid-cli/internal/layout/resize.go` - Resize orchestration (AdjustSplit, ResetSplits, ResetAllSplits)
- `grid-cli/internal/layout/splits_test.go` - Tests (17 tests)

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

// Phase 2 layout
import "github.com/yourusername/grid-cli/internal/layout"

// Phase 3 state
import "github.com/yourusername/grid-cli/internal/state"

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

## Phase 2 Key APIs

```go
// Calculate track sizes from abstract definitions
sizes := layout.CalculateTracks(tracks, availableSpace, gap)

// Calculate full layout with all cell bounds
calculated := layout.CalculateLayout(layoutDef, screenRect, gap)

// Get cell at a specific point
cellID := layout.GetCellAtPoint(calculated.CellBounds, point)

// Get adjacent cells for navigation
adjacent := layout.GetAdjacentCells("main", calculated.CellBounds)

// Calculate window bounds within a cell
windowBounds := layout.CalculateWindowBounds(cellBounds, windowCount, mode, ratios, padding)

// Calculate all window placements
placements := layout.CalculateAllWindowPlacements(calculated, assignments, cellModes, cellRatios, defaultMode, padding)

// Normalize split ratios to sum to 1.0
ratios := layout.NormalizeRatios([]float64{1, 2, 3})
```

## Phase 3 Key APIs

```go
// Load state (creates if missing)
rs, err := state.LoadState()

// Get/create space state
space := rs.GetSpace("1")

// Layout management
space.SetCurrentLayout("two-column", 0)
newLayout := space.CycleLayout(availableLayouts)

// Window assignment
space.AssignWindow(windowID, "left")
space.RemoveWindow(windowID)
cellID := space.GetWindowCell(windowID)

// Focus tracking
space.SetFocus("left", 0)
focusedWin := space.GetFocusedWindow()

// Save state
rs.Save()

// Query helpers
assignments := rs.GetWindowAssignments("1")
ratios := rs.GetCellSplitRatios("1", "left")
rs.SetCellStackMode("1", "left", types.StackTabs)
```

## Phase 4 Key APIs

```go
// Assign windows to cells using various strategies
result := layout.AssignWindows(windows, layoutDef, cellBounds, appRules, previous, strategy)
// result.Assignments[cellID] = []windowIDs
// result.Floating = windows that should float
// result.Excluded = minimized/hidden windows

// Main orchestration function
err := layout.ApplyLayout(ctx, client, config, runtimeState, layoutID, opts)

// Apply window placements to server
err := layout.ApplyPlacements(ctx, client, placements)

// Cycle to next/previous layout
newLayoutID, err := layout.CycleLayout(ctx, client, cfg, runtimeState, spaceID, opts)
newLayoutID, err := layout.PreviousLayout(ctx, client, cfg, runtimeState, spaceID, opts)

// State reconciliation
err := layout.ReconcileState(ctx, client, runtimeState, spaceID)
newWindowIDs, err := layout.CheckForNewWindows(ctx, client, runtimeState, spaceID)
staleWindowIDs, err := layout.GetStaleWindows(ctx, client, runtimeState, spaceID)

// Helper functions
preferred := layout.GetPreferredCell(window, appRules)
```

## Phase 5 CLI Commands

```bash
# Layout management
grid layout list                    # List available layouts
grid layout show <id>               # Show layout details
grid layout apply <id> [--space]    # Apply layout to space
grid layout cycle [--space]         # Cycle to next layout
grid layout current [--space]       # Show current layout

# Config management
grid config show                    # Show current config as JSON
grid config validate [path]         # Validate config file
grid config init                    # Create default config

# State management
grid state show                     # Show runtime state
grid state reset                    # Clear all state

# Focus (stubs - Phase 6)
grid focus left|right|up|down       # Move to adjacent cell
grid focus next|prev                # Cycle within cell
grid focus cell <id>                # Jump to cell

# Resize (stubs - Phase 7)
grid resize grow|shrink [amount]    # Resize focused window
grid resize reset                   # Reset to equal splits
```

## Phase 6 Key APIs

```go
// Move focus to adjacent cell (with wrap-around support)
newCellID, err := focus.MoveFocus(ctx, client, cfg, runtimeState, types.DirRight, opts)

// Focus a specific cell by ID
cellID, err := focus.FocusCell(ctx, client, runtimeState, spaceID, "main")

// Cycle focus to next/prev window in current cell
windowID, err := focus.CycleFocusInCell(ctx, client, runtimeState, spaceID, true) // forward
windowID, err := focus.CycleFocusInCell(ctx, client, runtimeState, spaceID, false) // backward

// Navigation helpers
targetCell, found := focus.FindTargetCell(currentCellID, direction, cellBounds, wrapAround)
cell := focus.GetCellInDirection(currentCellID, types.DirLeft, cellBounds)

// Window cycling helpers
nextIndex := focus.CycleWindowIndex(currentIndex, totalWindows, forward)
windowID := focus.GetWindowAtIndex(windows, index)
index := focus.FindWindowIndex(windows, windowID)
```

## Phase 7 Key APIs

```go
// Resize focused window in cell
err := layout.AdjustSplit(ctx, client, cfg, runtimeState, 0.1)  // grow 10%
err := layout.AdjustSplit(ctx, client, cfg, runtimeState, -0.1) // shrink 10%

// Reset splits to equal
err := layout.ResetSplits(ctx, client, cfg, runtimeState)      // focused cell
err := layout.ResetAllSplits(ctx, client, cfg, runtimeState)   // all cells

// Get info about current splits
info, err := layout.GetSplitInfo(runtimeState, spaceID)
// info.CellID, info.WindowCount, info.Ratios, info.FocusedIndex

// Pure ratio functions
ratios := layout.InitializeSplitRatios(3)                      // [0.33, 0.33, 0.34]
ratios := layout.NormalizeSplitRatios([]float64{1, 2, 3})     // [0.17, 0.33, 0.5]
newRatios, err := layout.AdjustSplitRatio(ratios, 0, 0.1, 0.1) // grow first window
ratios = layout.RecalculateSplitsAfterRemoval(ratios, 1)       // remove window 1
ratios = layout.RecalculateSplitsAfterAddition(ratios, 1)      // add window at pos 1

// Constants
layout.MinimumRatio       // 0.1 (10% minimum)
layout.DefaultResizeAmount // 0.1 (10% step)
```

## Notes for Future Phases

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
