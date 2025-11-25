# Phase 0: Shared Types

## Overview

This phase defines the common data types used across all layout implementation phases. These types must be implemented first as they form the foundation for all other modules.

**Location**: `grid-cli/internal/types/layout_types.go`

**Dependencies**: None

**Parallelizes With**: Can be implemented first, or alongside Phase 1, 2, 3

---

## Scope

Create the shared type definitions that will be imported by:
- Phase 1: Configuration Parser
- Phase 2: Grid Calculation Engine
- Phase 3: State Persistence
- Phase 4: Window Assignment
- Phase 6: Focus Navigation
- Phase 7: Split Ratio Management

---

## Files to Create

```
grid-cli/internal/types/
└── layout_types.go
```

---

## Implementation

### layout_types.go

```go
package types

// StackMode defines how multiple windows in a cell are arranged
type StackMode string

const (
    StackVertical   StackMode = "vertical"
    StackHorizontal StackMode = "horizontal"
    StackTabs       StackMode = "tabs"
)

// TrackSize represents a grid track dimension (column or row)
// Supports: "1fr", "2fr", "300px", "auto", "minmax(200px, 1fr)"
type TrackSize struct {
    Type  TrackType // Type of track sizing
    Value float64   // Primary value (for fr/px)
    Min   float64   // Minimum value (for minmax)
    Max   float64   // Maximum value (for minmax)
}

// TrackType categorizes track sizing methods
type TrackType string

const (
    TrackFr     TrackType = "fr"     // Fractional unit
    TrackPx     TrackType = "px"     // Fixed pixels
    TrackAuto   TrackType = "auto"   // Content-based
    TrackMinMax TrackType = "minmax" // Constrained flexible
)

// Cell represents a grid cell definition from configuration
type Cell struct {
    ID          string    // Unique cell identifier
    ColumnStart int       // 1-indexed column start
    ColumnEnd   int       // 1-indexed column end (exclusive)
    RowStart    int       // 1-indexed row start
    RowEnd      int       // 1-indexed row end (exclusive)
    StackMode   StackMode // How windows stack in this cell (optional override)
}

// Layout defines a complete grid layout configuration
type Layout struct {
    ID          string               // Unique layout identifier
    Name        string               // Human-readable name
    Description string               // Optional description
    Columns     []TrackSize          // Column track definitions
    Rows        []TrackSize          // Row track definitions
    Cells       []Cell               // Cell definitions
    CellModes   map[string]StackMode // Per-cell stack mode overrides
}

// Rect represents pixel bounds on screen
type Rect struct {
    X      float64 // Left edge (pixels from screen left)
    Y      float64 // Top edge (pixels from screen top)
    Width  float64 // Width in pixels
    Height float64 // Height in pixels
}

// Point represents a 2D coordinate
type Point struct {
    X float64
    Y float64
}

// Center returns the center point of a Rect
func (r Rect) Center() Point {
    return Point{
        X: r.X + r.Width/2,
        Y: r.Y + r.Height/2,
    }
}

// Contains checks if a point is inside the rect
func (r Rect) Contains(p Point) bool {
    return p.X >= r.X && p.X <= r.X+r.Width &&
        p.Y >= r.Y && p.Y <= r.Y+r.Height
}

// CellBounds contains calculated pixel positions for a cell
type CellBounds struct {
    CellID string // Reference to cell definition
    Bounds Rect   // Calculated pixel bounds
}

// WindowPlacement specifies where a window should be positioned
type WindowPlacement struct {
    WindowID uint32 // Window identifier from server
    Bounds   Rect   // Target position and size
}

// CalculatedLayout contains all computed bounds for a layout
type CalculatedLayout struct {
    LayoutID    string          // Reference to layout definition
    ScreenRect  Rect            // Screen bounds used for calculation
    Gap         float64         // Gap between cells in pixels
    ColumnSizes []float64       // Calculated column widths
    RowSizes    []float64       // Calculated row heights
    CellBounds  map[string]Rect // cellID -> calculated bounds
}

// Direction represents navigation direction
type Direction int

const (
    DirLeft Direction = iota
    DirRight
    DirUp
    DirDown
)

// String returns the string representation of a Direction
func (d Direction) String() string {
    switch d {
    case DirLeft:
        return "left"
    case DirRight:
        return "right"
    case DirUp:
        return "up"
    case DirDown:
        return "down"
    default:
        return "unknown"
    }
}

// ParseDirection converts a string to Direction
func ParseDirection(s string) (Direction, bool) {
    switch s {
    case "left":
        return DirLeft, true
    case "right":
        return DirRight, true
    case "up":
        return DirUp, true
    case "down":
        return DirDown, true
    default:
        return 0, false
    }
}

// AssignmentStrategy defines how windows are distributed to cells
type AssignmentStrategy int

const (
    AssignAutoFlow AssignmentStrategy = iota // Even distribution
    AssignPinned                              // Use app rules
    AssignPreserve                            // Maintain previous assignments
)
```

---

## Usage Examples

### Importing Types

```go
import "github.com/yourusername/grid-cli/internal/types"

// Use types
var mode types.StackMode = types.StackVertical
var track types.TrackSize = types.TrackSize{Type: types.TrackFr, Value: 1}
var rect types.Rect = types.Rect{X: 0, Y: 0, Width: 1920, Height: 1080}
```

### Creating a Layout

```go
layout := types.Layout{
    ID:   "two-column",
    Name: "Two Column",
    Columns: []types.TrackSize{
        {Type: types.TrackFr, Value: 1},
        {Type: types.TrackFr, Value: 1},
    },
    Rows: []types.TrackSize{
        {Type: types.TrackFr, Value: 1},
    },
    Cells: []types.Cell{
        {ID: "left", ColumnStart: 1, ColumnEnd: 2, RowStart: 1, RowEnd: 2},
        {ID: "right", ColumnStart: 2, ColumnEnd: 3, RowStart: 1, RowEnd: 2},
    },
}
```

---

## Acceptance Criteria

1. All types compile without errors
2. Types are exported (capitalized names)
3. JSON and YAML struct tags are NOT included here (added in Phase 1 for config types)
4. Helper methods (Center, Contains, String, ParseDirection) work correctly
5. Constants are properly defined with iota where appropriate

---

## Test Scenarios

```go
func TestRectCenter(t *testing.T) {
    r := types.Rect{X: 0, Y: 0, Width: 100, Height: 100}
    c := r.Center()
    if c.X != 50 || c.Y != 50 {
        t.Errorf("expected (50,50), got (%v,%v)", c.X, c.Y)
    }
}

func TestRectContains(t *testing.T) {
    r := types.Rect{X: 0, Y: 0, Width: 100, Height: 100}
    if !r.Contains(types.Point{X: 50, Y: 50}) {
        t.Error("center point should be contained")
    }
    if r.Contains(types.Point{X: 150, Y: 50}) {
        t.Error("outside point should not be contained")
    }
}

func TestParseDirection(t *testing.T) {
    d, ok := types.ParseDirection("left")
    if !ok || d != types.DirLeft {
        t.Error("failed to parse 'left'")
    }
    _, ok = types.ParseDirection("invalid")
    if ok {
        t.Error("should fail on invalid direction")
    }
}
```

---

## Notes for Implementing Agent

1. Create the `internal/types/` directory if it doesn't exist
2. This is a pure data types file - no external dependencies
3. Keep types minimal - only add what's needed by multiple phases
4. Phase-specific types should be defined in their respective packages
5. Run `go build ./...` to verify compilation
