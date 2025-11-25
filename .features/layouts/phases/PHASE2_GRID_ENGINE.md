# Phase 2: Grid Calculation Engine

## Overview

Implement the grid calculation engine that converts abstract layout definitions into pixel coordinates. This is a pure algorithmic module with no external dependencies beyond the shared types.

**Location**: `grid-cli/internal/layout/`

**Dependencies**: Phase 0 (Shared Types)

**Parallelizes With**: Phase 1, Phase 3

---

## Scope

1. Calculate track sizes from screen dimensions (fr, px, auto, minmax)
2. Compute cell bounds from track sizes
3. Calculate window bounds within cells based on stack mode
4. Handle gap/padding between cells
5. Support minmax constraints with proper clamping

---

## Files to Create

```
grid-cli/internal/layout/
├── grid.go         # Grid track calculations
├── cells.go        # Cell bounds calculations
└── windows.go      # Window bounds within cells
```

---

## Implementation

### grid.go

```go
package layout

import (
    "github.com/yourusername/grid-cli/internal/types"
)

// CalculateTracks converts track definitions to pixel sizes
// Parameters:
//   - tracks: Track size definitions from layout
//   - available: Total available space in pixels
//   - gap: Gap between tracks in pixels
//
// Returns: Array of pixel sizes for each track
func CalculateTracks(tracks []types.TrackSize, available float64, gap float64) []float64 {
    if len(tracks) == 0 {
        return nil
    }

    // Subtract gaps from available space
    totalGaps := gap * float64(len(tracks)-1)
    available -= totalGaps

    sizes := make([]float64, len(tracks))
    remaining := available

    // First pass: allocate fixed pixel tracks
    var totalFr float64
    var frIndices []int

    for i, track := range tracks {
        switch track.Type {
        case types.TrackPx:
            sizes[i] = track.Value
            remaining -= track.Value
        case types.TrackFr:
            totalFr += track.Value
            frIndices = append(frIndices, i)
        case types.TrackMinMax:
            // Start with minimum, will adjust later
            sizes[i] = track.Min
            remaining -= track.Min
            totalFr += track.Max // Max is in fr units
            frIndices = append(frIndices, i)
        case types.TrackAuto:
            // Auto tracks get minimum size initially (will be handled by content)
            // For now, treat as 0 and let fr tracks take the space
            sizes[i] = 0
        }
    }

    // Second pass: distribute remaining space to fr tracks
    if totalFr > 0 && remaining > 0 {
        frUnit := remaining / totalFr

        for _, i := range frIndices {
            track := tracks[i]
            switch track.Type {
            case types.TrackFr:
                sizes[i] = frUnit * track.Value
            case types.TrackMinMax:
                // Add fr portion to minimum
                frPortion := frUnit * track.Max
                sizes[i] = track.Min + frPortion
            }
        }
    }

    // Third pass: apply minmax constraints and redistribute if needed
    sizes = applyMinMaxConstraints(tracks, sizes, available)

    return sizes
}

// applyMinMaxConstraints ensures minmax tracks stay within bounds
// and redistributes excess space if clamping occurs
func applyMinMaxConstraints(tracks []types.TrackSize, sizes []float64, available float64) []float64 {
    // For simplicity, just ensure minimums are met
    // A full implementation would iterate until stable
    for i, track := range tracks {
        if track.Type == types.TrackMinMax {
            if sizes[i] < track.Min {
                sizes[i] = track.Min
            }
            // Note: max constraint in minmax(Xpx, Yfr) is relative, not absolute
        }
    }

    // Ensure sizes are non-negative
    for i := range sizes {
        if sizes[i] < 0 {
            sizes[i] = 0
        }
    }

    return sizes
}

// CalculateTrackPositions returns the starting position of each track
// This is useful for determining cell positions
func CalculateTrackPositions(sizes []float64, gap float64) []float64 {
    positions := make([]float64, len(sizes)+1)
    positions[0] = 0

    for i, size := range sizes {
        positions[i+1] = positions[i] + size
        if i < len(sizes)-1 {
            positions[i+1] += gap
        }
    }

    return positions
}

// CalculateLayout computes the full layout with all cell bounds
func CalculateLayout(layout *types.Layout, screenRect types.Rect, gap float64) *types.CalculatedLayout {
    // Calculate column and row sizes
    columnSizes := CalculateTracks(layout.Columns, screenRect.Width, gap)
    rowSizes := CalculateTracks(layout.Rows, screenRect.Height, gap)

    // Calculate column and row positions
    colPositions := CalculateTrackPositions(columnSizes, gap)
    rowPositions := CalculateTrackPositions(rowSizes, gap)

    // Calculate bounds for each cell
    cellBounds := make(map[string]types.Rect)
    for _, cell := range layout.Cells {
        bounds := CalculateCellBounds(cell, colPositions, rowPositions, columnSizes, rowSizes, gap)
        // Offset by screen position
        bounds.X += screenRect.X
        bounds.Y += screenRect.Y
        cellBounds[cell.ID] = bounds
    }

    return &types.CalculatedLayout{
        LayoutID:    layout.ID,
        ScreenRect:  screenRect,
        Gap:         gap,
        ColumnSizes: columnSizes,
        RowSizes:    rowSizes,
        CellBounds:  cellBounds,
    }
}
```

### cells.go

```go
package layout

import (
    "github.com/yourusername/grid-cli/internal/types"
)

// CalculateCellBounds computes the pixel rect for a cell
// Parameters:
//   - cell: Cell definition with column/row spans
//   - colPositions: Starting X position for each column (len = columns + 1)
//   - rowPositions: Starting Y position for each row (len = rows + 1)
//   - colSizes: Width of each column
//   - rowSizes: Height of each row
//   - gap: Gap between cells
//
// Returns: Rect with cell's position and size
func CalculateCellBounds(
    cell types.Cell,
    colPositions, rowPositions []float64,
    colSizes, rowSizes []float64,
    gap float64,
) types.Rect {
    // Convert 1-indexed to 0-indexed
    colStart := cell.ColumnStart - 1
    colEnd := cell.ColumnEnd - 1
    rowStart := cell.RowStart - 1
    rowEnd := cell.RowEnd - 1

    // Calculate X position and width
    x := colPositions[colStart]
    width := float64(0)
    for i := colStart; i < colEnd; i++ {
        width += colSizes[i]
        if i < colEnd-1 {
            width += gap // Add gap between spanned columns
        }
    }

    // Calculate Y position and height
    y := rowPositions[rowStart]
    height := float64(0)
    for i := rowStart; i < rowEnd; i++ {
        height += rowSizes[i]
        if i < rowEnd-1 {
            height += gap // Add gap between spanned rows
        }
    }

    return types.Rect{
        X:      x,
        Y:      y,
        Width:  width,
        Height: height,
    }
}

// GetCellAtPoint finds which cell contains the given point
// Returns cell ID or empty string if no cell contains the point
func GetCellAtPoint(cellBounds map[string]types.Rect, point types.Point) string {
    for cellID, bounds := range cellBounds {
        if bounds.Contains(point) {
            return cellID
        }
    }
    return ""
}

// GetAdjacentCells returns cells adjacent to the given cell in each direction
func GetAdjacentCells(
    cellID string,
    cellBounds map[string]types.Rect,
) map[types.Direction][]string {
    result := map[types.Direction][]string{
        types.DirLeft:  {},
        types.DirRight: {},
        types.DirUp:    {},
        types.DirDown:  {},
    }

    current, ok := cellBounds[cellID]
    if !ok {
        return result
    }

    currentCenter := current.Center()

    for id, bounds := range cellBounds {
        if id == cellID {
            continue
        }

        center := bounds.Center()

        // Determine primary direction based on center offset
        dx := center.X - currentCenter.X
        dy := center.Y - currentCenter.Y

        // Check if there's meaningful overlap in the perpendicular axis
        if dx < 0 && overlapsVertically(current, bounds) {
            result[types.DirLeft] = append(result[types.DirLeft], id)
        }
        if dx > 0 && overlapsVertically(current, bounds) {
            result[types.DirRight] = append(result[types.DirRight], id)
        }
        if dy < 0 && overlapsHorizontally(current, bounds) {
            result[types.DirUp] = append(result[types.DirUp], id)
        }
        if dy > 0 && overlapsHorizontally(current, bounds) {
            result[types.DirDown] = append(result[types.DirDown], id)
        }
    }

    return result
}

// overlapsVertically checks if two rects have vertical overlap
func overlapsVertically(a, b types.Rect) bool {
    return a.Y < b.Y+b.Height && a.Y+a.Height > b.Y
}

// overlapsHorizontally checks if two rects have horizontal overlap
func overlapsHorizontally(a, b types.Rect) bool {
    return a.X < b.X+b.Width && a.X+a.Width > b.X
}

// SortCellsByPosition returns cell IDs sorted by visual position (left-to-right, top-to-bottom)
func SortCellsByPosition(cellBounds map[string]types.Rect) []string {
    ids := make([]string, 0, len(cellBounds))
    for id := range cellBounds {
        ids = append(ids, id)
    }

    // Sort by Y first, then X (top-to-bottom, left-to-right)
    for i := 0; i < len(ids)-1; i++ {
        for j := i + 1; j < len(ids); j++ {
            boundsI := cellBounds[ids[i]]
            boundsJ := cellBounds[ids[j]]

            // Compare by row (Y) first, then column (X)
            if boundsJ.Y < boundsI.Y || (boundsJ.Y == boundsI.Y && boundsJ.X < boundsI.X) {
                ids[i], ids[j] = ids[j], ids[i]
            }
        }
    }

    return ids
}
```

### windows.go

```go
package layout

import (
    "github.com/yourusername/grid-cli/internal/types"
)

// CalculateWindowBounds computes bounds for windows stacked in a cell
// Parameters:
//   - cellBounds: The cell's bounds
//   - windowCount: Number of windows in the cell
//   - mode: How windows are stacked (vertical, horizontal, tabs)
//   - ratios: Split ratios (one per window, sum to 1.0). If nil, uses equal splits
//   - padding: Padding between windows in pixels
//
// Returns: Array of Rects, one per window
func CalculateWindowBounds(
    cellBounds types.Rect,
    windowCount int,
    mode types.StackMode,
    ratios []float64,
    padding float64,
) []types.Rect {
    if windowCount == 0 {
        return nil
    }

    // Use equal ratios if not provided
    if ratios == nil || len(ratios) != windowCount {
        ratios = equalRatios(windowCount)
    }

    bounds := make([]types.Rect, windowCount)

    switch mode {
    case types.StackVertical:
        bounds = calculateVerticalStack(cellBounds, ratios, padding)
    case types.StackHorizontal:
        bounds = calculateHorizontalStack(cellBounds, ratios, padding)
    case types.StackTabs:
        // All windows get full cell bounds (only one visible at a time)
        for i := 0; i < windowCount; i++ {
            bounds[i] = cellBounds
        }
    default:
        // Default to vertical
        bounds = calculateVerticalStack(cellBounds, ratios, padding)
    }

    return bounds
}

// calculateVerticalStack arranges windows top-to-bottom
func calculateVerticalStack(cellBounds types.Rect, ratios []float64, padding float64) []types.Rect {
    n := len(ratios)
    totalPadding := padding * float64(n-1)
    availableHeight := cellBounds.Height - totalPadding

    bounds := make([]types.Rect, n)
    y := cellBounds.Y

    for i, ratio := range ratios {
        height := availableHeight * ratio
        bounds[i] = types.Rect{
            X:      cellBounds.X,
            Y:      y,
            Width:  cellBounds.Width,
            Height: height,
        }
        y += height + padding
    }

    return bounds
}

// calculateHorizontalStack arranges windows left-to-right
func calculateHorizontalStack(cellBounds types.Rect, ratios []float64, padding float64) []types.Rect {
    n := len(ratios)
    totalPadding := padding * float64(n-1)
    availableWidth := cellBounds.Width - totalPadding

    bounds := make([]types.Rect, n)
    x := cellBounds.X

    for i, ratio := range ratios {
        width := availableWidth * ratio
        bounds[i] = types.Rect{
            X:      x,
            Y:      cellBounds.Y,
            Width:  width,
            Height: cellBounds.Height,
        }
        x += width + padding
    }

    return bounds
}

// equalRatios returns an array of equal ratios summing to 1.0
func equalRatios(n int) []float64 {
    if n <= 0 {
        return nil
    }
    ratio := 1.0 / float64(n)
    ratios := make([]float64, n)
    for i := range ratios {
        ratios[i] = ratio
    }
    return ratios
}

// NormalizeRatios ensures ratios sum to 1.0
func NormalizeRatios(ratios []float64) []float64 {
    if len(ratios) == 0 {
        return nil
    }

    sum := float64(0)
    for _, r := range ratios {
        sum += r
    }

    if sum == 0 {
        return equalRatios(len(ratios))
    }

    normalized := make([]float64, len(ratios))
    for i, r := range ratios {
        normalized[i] = r / sum
    }
    return normalized
}

// CalculateAllWindowPlacements computes placements for all windows in a layout
// Parameters:
//   - calculatedLayout: Pre-calculated layout with cell bounds
//   - assignments: Map of cellID -> ordered list of window IDs
//   - cellStates: Per-cell state (stack mode, split ratios)
//   - defaultMode: Default stack mode if not specified in cell state
//   - padding: Padding between windows
//
// Returns: Array of WindowPlacement for all windows
func CalculateAllWindowPlacements(
    calculatedLayout *types.CalculatedLayout,
    assignments map[string][]uint32,
    cellModes map[string]types.StackMode,
    cellRatios map[string][]float64,
    defaultMode types.StackMode,
    padding float64,
) []types.WindowPlacement {
    var placements []types.WindowPlacement

    for cellID, windowIDs := range assignments {
        cellBounds, ok := calculatedLayout.CellBounds[cellID]
        if !ok {
            continue
        }

        // Determine stack mode for this cell
        mode := defaultMode
        if m, ok := cellModes[cellID]; ok && m != "" {
            mode = m
        }

        // Get split ratios for this cell
        var ratios []float64
        if r, ok := cellRatios[cellID]; ok {
            ratios = r
        }

        // Calculate window bounds
        windowBounds := CalculateWindowBounds(cellBounds, len(windowIDs), mode, ratios, padding)

        // Create placements
        for i, windowID := range windowIDs {
            if i < len(windowBounds) {
                placements = append(placements, types.WindowPlacement{
                    WindowID: windowID,
                    Bounds:   windowBounds[i],
                })
            }
        }
    }

    return placements
}
```

---

## Algorithm Details

### Track Size Calculation

The algorithm handles CSS Grid-like track definitions:

1. **Fixed Tracks (px)**: Subtract from available space first
2. **Fractional Tracks (fr)**: Distribute remaining space proportionally
3. **Minmax Tracks**: Start at minimum, add fr portion from remaining space
4. **Auto Tracks**: Currently treated as 0 (content-based sizing not supported)

**Example:**
```
Screen width: 3000px
Columns: ["300px", "1fr", "2fr"]
Gap: 10px

Step 1: Subtract gaps
  Available = 3000 - (10 * 2) = 2980px

Step 2: Allocate fixed
  Column 0 = 300px
  Remaining = 2980 - 300 = 2680px

Step 3: Distribute fr
  Total fr = 3
  1fr = 2680 / 3 = 893.33px
  2fr = 893.33 * 2 = 1786.67px

Result: [300, 893.33, 1786.67]
```

### Cell Bounds Calculation

Cells can span multiple tracks. The calculation:

1. Find starting position from column/row positions array
2. Sum widths/heights of spanned tracks
3. Add internal gaps for multi-track spans

### Window Bounds Calculation

Windows within a cell are arranged based on stack mode:

- **Vertical**: Windows stack top-to-bottom, sharing cell width
- **Horizontal**: Windows stack left-to-right, sharing cell height
- **Tabs**: All windows get full cell bounds (visibility controlled separately)

Split ratios control the proportion of space each window gets.

---

## Acceptance Criteria

1. Track calculation handles all track types (fr, px, auto, minmax)
2. Cell bounds correctly account for multi-track spans
3. Window bounds correctly implement all three stack modes
4. Gap/padding is properly applied between tracks and windows
5. Functions handle edge cases (empty inputs, single items, etc.)

---

## Test Scenarios

```go
func TestCalculateTracks_Simple(t *testing.T) {
    tracks := []types.TrackSize{
        {Type: types.TrackFr, Value: 1},
        {Type: types.TrackFr, Value: 1},
    }
    sizes := CalculateTracks(tracks, 1000, 0)
    // Expected: [500, 500]
}

func TestCalculateTracks_Mixed(t *testing.T) {
    tracks := []types.TrackSize{
        {Type: types.TrackPx, Value: 200},
        {Type: types.TrackFr, Value: 1},
        {Type: types.TrackFr, Value: 2},
    }
    sizes := CalculateTracks(tracks, 1000, 0)
    // Expected: [200, 266.67, 533.33]
}

func TestCalculateTracks_WithGaps(t *testing.T) {
    tracks := []types.TrackSize{
        {Type: types.TrackFr, Value: 1},
        {Type: types.TrackFr, Value: 1},
    }
    sizes := CalculateTracks(tracks, 1000, 10)
    // Available = 1000 - 10 = 990
    // Expected: [495, 495]
}

func TestCalculateCellBounds_SingleCell(t *testing.T) {
    cell := types.Cell{ID: "main", ColumnStart: 1, ColumnEnd: 2, RowStart: 1, RowEnd: 2}
    colPositions := []float64{0, 500, 1000}
    rowPositions := []float64{0, 500, 1000}
    colSizes := []float64{500, 500}
    rowSizes := []float64{500, 500}

    bounds := CalculateCellBounds(cell, colPositions, rowPositions, colSizes, rowSizes, 0)
    // Expected: {X: 0, Y: 0, Width: 500, Height: 500}
}

func TestCalculateCellBounds_SpanningCell(t *testing.T) {
    cell := types.Cell{ID: "main", ColumnStart: 1, ColumnEnd: 3, RowStart: 1, RowEnd: 2}
    // Cell spans columns 1-2 (0-indexed: 0-1)
    // Expected width = col[0] + gap + col[1]
}

func TestCalculateWindowBounds_Vertical(t *testing.T) {
    cellBounds := types.Rect{X: 0, Y: 0, Width: 500, Height: 1000}
    bounds := CalculateWindowBounds(cellBounds, 2, types.StackVertical, nil, 0)
    // Expected: [{0, 0, 500, 500}, {0, 500, 500, 500}]
}

func TestCalculateWindowBounds_WithRatios(t *testing.T) {
    cellBounds := types.Rect{X: 0, Y: 0, Width: 500, Height: 1000}
    ratios := []float64{0.3, 0.7}
    bounds := CalculateWindowBounds(cellBounds, 2, types.StackVertical, ratios, 0)
    // Expected: [{0, 0, 500, 300}, {0, 300, 500, 700}]
}

func TestCalculateWindowBounds_Tabs(t *testing.T) {
    cellBounds := types.Rect{X: 0, Y: 0, Width: 500, Height: 500}
    bounds := CalculateWindowBounds(cellBounds, 3, types.StackTabs, nil, 0)
    // All three should equal cellBounds
}
```

---

## Notes for Implementing Agent

1. This is a pure calculation module - no file I/O or network calls
2. All functions should be deterministic
3. Handle edge cases gracefully (empty arrays, zero values)
4. Float precision: use standard float64, don't over-optimize
5. The `CalculateLayout` function is the main entry point for other phases
6. Run `go test ./internal/layout/...` to verify implementation
