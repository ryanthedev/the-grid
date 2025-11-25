# Phase 6: Focus Navigation

## Overview

Implement focus navigation between and within cells. This allows users to move focus directionally between cells and cycle through windows within the same cell.

**Location**: `grid-cli/internal/focus/`

**Dependencies**: Phase 2 (Grid Engine - cell bounds), Phase 3 (State Manager - focus tracking)

**Parallelizes With**: Phase 4, Phase 7

---

## Scope

1. Navigate focus between cells (directional: left/right/up/down)
2. Navigate focus within a cell (next/previous window)
3. Jump to specific cell by ID or number
4. Track focused cell and window in state
5. Integrate with server to actually focus windows

---

## Files to Create

```
grid-cli/internal/focus/
├── focus.go        # Focus management orchestration
├── navigation.go   # Directional navigation algorithms
└── within_cell.go  # Within-cell window cycling
```

---

## Implementation

### focus.go

```go
package focus

import (
    "context"
    "fmt"

    "github.com/yourusername/grid-cli/internal/client"
    "github.com/yourusername/grid-cli/internal/config"
    "github.com/yourusername/grid-cli/internal/layout"
    "github.com/yourusername/grid-cli/internal/state"
    "github.com/yourusername/grid-cli/internal/types"
)

// MoveFocus moves focus to an adjacent cell in the specified direction
func MoveFocus(
    ctx context.Context,
    c *client.Client,
    cfg *config.Config,
    runtimeState *state.RuntimeState,
    direction types.Direction,
) error {
    // Get current space
    serverState, err := c.Dump(ctx)
    if err != nil {
        return fmt.Errorf("failed to get server state: %w", err)
    }

    spaceID := getCurrentSpaceID(serverState)
    spaceState := runtimeState.GetSpaceReadOnly(spaceID)

    if spaceState == nil || spaceState.CurrentLayoutID == "" {
        return fmt.Errorf("no layout applied to current space")
    }

    // Get current layout
    l, err := cfg.GetLayout(spaceState.CurrentLayoutID)
    if err != nil {
        return fmt.Errorf("layout not found: %w", err)
    }

    // Get display bounds
    displayBounds, err := getDisplayBoundsForSpace(serverState, spaceID)
    if err != nil {
        return err
    }

    // Calculate cell bounds
    gap := float64(cfg.Settings.CellPadding)
    calculatedLayout := layout.CalculateLayout(l, displayBounds, gap)

    // Get current focused cell
    currentCellID := spaceState.FocusedCell
    if currentCellID == "" {
        // Default to first cell
        if len(l.Cells) > 0 {
            currentCellID = l.Cells[0].ID
        } else {
            return fmt.Errorf("no cells in layout")
        }
    }

    // Find target cell
    targetCellID, err := FindTargetCell(currentCellID, direction, calculatedLayout.CellBounds, true)
    if err != nil {
        return fmt.Errorf("no cell in direction %s: %w", direction, err)
    }

    // Focus first window in target cell
    return FocusCell(ctx, c, runtimeState, targetCellID)
}

// FocusCell focuses the first window in a specific cell
func FocusCell(
    ctx context.Context,
    c *client.Client,
    runtimeState *state.RuntimeState,
    cellID string,
) error {
    // Get current space from server
    serverState, err := c.Dump(ctx)
    if err != nil {
        return err
    }

    spaceID := getCurrentSpaceID(serverState)
    spaceState := runtimeState.GetSpace(spaceID)

    // Get windows in cell
    cellState, ok := spaceState.Cells[cellID]
    if !ok || len(cellState.Windows) == 0 {
        // Update focus tracking even if no windows
        spaceState.SetFocus(cellID, 0)
        runtimeState.MarkUpdated()
        return runtimeState.Save()
    }

    // Focus first window
    windowID := cellState.Windows[0]
    if err := focusWindow(ctx, c, windowID); err != nil {
        return fmt.Errorf("failed to focus window: %w", err)
    }

    // Update state
    spaceState.SetFocus(cellID, 0)
    runtimeState.MarkUpdated()

    return runtimeState.Save()
}

// CycleFocusInCell cycles focus to the next/previous window within current cell
func CycleFocusInCell(
    ctx context.Context,
    c *client.Client,
    runtimeState *state.RuntimeState,
    forward bool,
) error {
    // Get current space
    serverState, err := c.Dump(ctx)
    if err != nil {
        return err
    }

    spaceID := getCurrentSpaceID(serverState)
    spaceState := runtimeState.GetSpace(spaceID)

    if spaceState.FocusedCell == "" {
        return fmt.Errorf("no cell is focused")
    }

    cellState, ok := spaceState.Cells[spaceState.FocusedCell]
    if !ok || len(cellState.Windows) == 0 {
        return fmt.Errorf("focused cell has no windows")
    }

    // Calculate new window index
    newIndex := CycleWindowIndex(spaceState.FocusedWindow, len(cellState.Windows), forward)

    // Focus the window
    windowID := cellState.Windows[newIndex]
    if err := focusWindow(ctx, c, windowID); err != nil {
        return fmt.Errorf("failed to focus window: %w", err)
    }

    // Update state
    spaceState.SetFocus(spaceState.FocusedCell, newIndex)
    runtimeState.MarkUpdated()

    return runtimeState.Save()
}

// focusWindow tells the server to focus a specific window
func focusWindow(ctx context.Context, c *client.Client, windowID uint32) error {
    // The server may support a focus method, or we use raise/activate
    // Try "window.focus" if available, otherwise use workaround

    params := map[string]interface{}{
        "windowId": windowID,
    }

    // Try dedicated focus method
    _, err := c.CallMethod(ctx, "window.focus", params)
    if err != nil {
        // Fallback: try to raise window by setting it as key window
        // This depends on server capabilities
        _, err = c.CallMethod(ctx, "window.raise", params)
    }

    return err
}

// Helper to get current space ID from server state
func getCurrentSpaceID(serverState map[string]interface{}) string {
    if metadata, ok := serverState["metadata"].(map[string]interface{}); ok {
        if activeSpace, ok := metadata["activeSpace"]; ok {
            return fmt.Sprintf("%v", activeSpace)
        }
    }
    return "1"
}

// Helper to get display bounds
func getDisplayBoundsForSpace(serverState map[string]interface{}, spaceID string) (types.Rect, error) {
    displays, ok := serverState["displays"].([]interface{})
    if !ok {
        return types.Rect{}, fmt.Errorf("no displays in state")
    }

    for _, d := range displays {
        display, ok := d.(map[string]interface{})
        if !ok {
            continue
        }

        if frame, ok := display["visibleFrame"].(map[string]interface{}); ok {
            return types.Rect{
                X:      toFloat64(frame["x"]),
                Y:      toFloat64(frame["y"]),
                Width:  toFloat64(frame["width"]),
                Height: toFloat64(frame["height"]),
            }, nil
        }
    }

    return types.Rect{}, fmt.Errorf("no display found")
}

func toFloat64(v interface{}) float64 {
    switch n := v.(type) {
    case float64:
        return n
    case int:
        return float64(n)
    default:
        return 0
    }
}
```

### navigation.go

```go
package focus

import (
    "fmt"
    "math"
    "sort"

    "github.com/yourusername/grid-cli/internal/types"
)

// FindTargetCell finds the cell in the given direction from current cell
// Uses cell center points for distance calculation
// If wrapAround is true, wraps to opposite edge when no cell in direction
func FindTargetCell(
    currentCellID string,
    direction types.Direction,
    cellBounds map[string]types.Rect,
    wrapAround bool,
) (string, error) {
    current, ok := cellBounds[currentCellID]
    if !ok {
        return "", fmt.Errorf("current cell not found: %s", currentCellID)
    }

    currentCenter := current.Center()

    // Find all candidates in the specified direction
    var candidates []candidateCell
    for id, bounds := range cellBounds {
        if id == currentCellID {
            continue
        }

        c := bounds.Center()

        if isInDirection(currentCenter, c, direction) {
            candidates = append(candidates, candidateCell{
                id:       id,
                bounds:   bounds,
                distance: distanceInDirection(currentCenter, c, direction),
            })
        }
    }

    if len(candidates) == 0 {
        if wrapAround {
            return findWrapAroundCell(currentCellID, direction, cellBounds)
        }
        return "", fmt.Errorf("no cell in direction %s", direction)
    }

    // Sort by distance and return closest
    sort.Slice(candidates, func(i, j int) bool {
        return candidates[i].distance < candidates[j].distance
    })

    return candidates[0].id, nil
}

type candidateCell struct {
    id       string
    bounds   types.Rect
    distance float64
}

// isInDirection checks if target center is in the specified direction from source
func isInDirection(source, target types.Point, direction types.Direction) bool {
    switch direction {
    case types.DirLeft:
        return target.X < source.X
    case types.DirRight:
        return target.X > source.X
    case types.DirUp:
        return target.Y < source.Y
    case types.DirDown:
        return target.Y > source.Y
    }
    return false
}

// distanceInDirection calculates a weighted distance that prefers
// cells that are more directly in the specified direction
func distanceInDirection(source, target types.Point, direction types.Direction) float64 {
    dx := target.X - source.X
    dy := target.Y - source.Y

    // Calculate primary and perpendicular distances
    var primary, perpendicular float64

    switch direction {
    case types.DirLeft:
        primary = -dx // Negative because we're going left
        perpendicular = math.Abs(dy)
    case types.DirRight:
        primary = dx
        perpendicular = math.Abs(dy)
    case types.DirUp:
        primary = -dy // Negative because we're going up (smaller Y)
        perpendicular = math.Abs(dx)
    case types.DirDown:
        primary = dy
        perpendicular = math.Abs(dx)
    }

    // Weight perpendicular distance more heavily to prefer cells
    // that are directly in line with the current cell
    return primary + perpendicular*2
}

// findWrapAroundCell finds a cell on the opposite edge for wrap-around
func findWrapAroundCell(
    currentCellID string,
    direction types.Direction,
    cellBounds map[string]types.Rect,
) (string, error) {
    current := cellBounds[currentCellID]
    currentCenter := current.Center()

    var bestID string
    bestScore := math.MaxFloat64

    for id, bounds := range cellBounds {
        if id == currentCellID {
            continue
        }

        center := bounds.Center()
        var score float64

        // Find the cell on the opposite edge that's closest in the perpendicular axis
        switch direction {
        case types.DirLeft:
            // Wrap to rightmost cell, prefer same Y
            score = -center.X + math.Abs(center.Y-currentCenter.Y)*1000
        case types.DirRight:
            // Wrap to leftmost cell, prefer same Y
            score = center.X + math.Abs(center.Y-currentCenter.Y)*1000
        case types.DirUp:
            // Wrap to bottommost cell, prefer same X
            score = -center.Y + math.Abs(center.X-currentCenter.X)*1000
        case types.DirDown:
            // Wrap to topmost cell, prefer same X
            score = center.Y + math.Abs(center.X-currentCenter.X)*1000
        }

        if score < bestScore {
            bestScore = score
            bestID = id
        }
    }

    if bestID == "" {
        return "", fmt.Errorf("no cell found for wrap-around")
    }

    return bestID, nil
}

// GetCellInDirection is a simpler version that just checks if a cell exists in direction
func GetCellInDirection(
    currentCellID string,
    direction types.Direction,
    cellBounds map[string]types.Rect,
) (string, bool) {
    targetID, err := FindTargetCell(currentCellID, direction, cellBounds, false)
    if err != nil {
        return "", false
    }
    return targetID, true
}
```

### within_cell.go

```go
package focus

// CycleWindowIndex calculates the next/previous window index within a cell
// Handles wrapping at boundaries
func CycleWindowIndex(current, total int, forward bool) int {
    if total <= 0 {
        return 0
    }

    if forward {
        return (current + 1) % total
    }

    // Backward with wrap
    return (current - 1 + total) % total
}

// GetWindowAtIndex safely returns window ID at index, or 0 if invalid
func GetWindowAtIndex(windows []uint32, index int) uint32 {
    if index < 0 || index >= len(windows) {
        if len(windows) > 0 {
            return windows[0]
        }
        return 0
    }
    return windows[index]
}

// FindWindowIndex returns the index of a window in the list, or -1 if not found
func FindWindowIndex(windows []uint32, windowID uint32) int {
    for i, wid := range windows {
        if wid == windowID {
            return i
        }
    }
    return -1
}
```

---

## Navigation Algorithm Details

### Directional Navigation

The algorithm uses center points of cells to determine navigation:

1. **Filter candidates**: Find all cells whose center is in the specified direction
2. **Calculate distance**: Use weighted distance that prefers cells directly in line
3. **Select closest**: Return the cell with minimum weighted distance

**Distance Weighting:**
```
distance = primary_distance + perpendicular_distance * 2
```

This ensures that a cell directly to the left is preferred over one that's diagonally left.

### Wrap-Around

When no cell exists in the specified direction:
1. Find cells on the opposite edge
2. Prefer cells at the same position in the perpendicular axis
3. Return the best match

**Example:** Going left from the leftmost cell wraps to the rightmost cell at approximately the same Y position.

---

## Integration with Server

Focus changes require the server to activate/raise windows. The implementation tries:

1. `window.focus` method if available
2. `window.raise` as fallback

If neither is available, the focus change is tracked in state only (visual focus) without actually activating the window.

---

## Acceptance Criteria

1. Directional navigation moves to correct adjacent cell
2. Wrap-around works when enabled
3. Within-cell cycling works correctly
4. Focus state is persisted
5. Server is notified to focus windows
6. Empty cells are handled gracefully

---

## Test Scenarios

```go
func TestFindTargetCell_Right(t *testing.T) {
    cellBounds := map[string]types.Rect{
        "left":   {X: 0, Y: 0, Width: 500, Height: 1000},
        "right":  {X: 500, Y: 0, Width: 500, Height: 1000},
    }

    target, err := FindTargetCell("left", types.DirRight, cellBounds, false)
    if err != nil {
        t.Fatal(err)
    }
    if target != "right" {
        t.Errorf("expected 'right', got '%s'", target)
    }
}

func TestFindTargetCell_NoCell(t *testing.T) {
    cellBounds := map[string]types.Rect{
        "left":   {X: 0, Y: 0, Width: 500, Height: 1000},
        "right":  {X: 500, Y: 0, Width: 500, Height: 1000},
    }

    // Going left from left should fail without wrap
    _, err := FindTargetCell("left", types.DirLeft, cellBounds, false)
    if err == nil {
        t.Error("expected error for no cell in direction")
    }
}

func TestFindTargetCell_WrapAround(t *testing.T) {
    cellBounds := map[string]types.Rect{
        "left":   {X: 0, Y: 0, Width: 500, Height: 1000},
        "right":  {X: 500, Y: 0, Width: 500, Height: 1000},
    }

    // Going left from left should wrap to right
    target, err := FindTargetCell("left", types.DirLeft, cellBounds, true)
    if err != nil {
        t.Fatal(err)
    }
    if target != "right" {
        t.Errorf("expected 'right' (wrap), got '%s'", target)
    }
}

func TestCycleWindowIndex(t *testing.T) {
    // Forward cycling
    if CycleWindowIndex(0, 3, true) != 1 {
        t.Error("0 -> 1 forward")
    }
    if CycleWindowIndex(2, 3, true) != 0 {
        t.Error("2 -> 0 wrap forward")
    }

    // Backward cycling
    if CycleWindowIndex(1, 3, false) != 0 {
        t.Error("1 -> 0 backward")
    }
    if CycleWindowIndex(0, 3, false) != 2 {
        t.Error("0 -> 2 wrap backward")
    }
}

func TestDistanceInDirection(t *testing.T) {
    source := types.Point{X: 100, Y: 100}

    // Cell directly to the right should have lower distance than diagonal
    directRight := types.Point{X: 200, Y: 100}
    diagonalRight := types.Point{X: 200, Y: 200}

    d1 := distanceInDirection(source, directRight, types.DirRight)
    d2 := distanceInDirection(source, diagonalRight, types.DirRight)

    if d1 >= d2 {
        t.Errorf("direct should be closer: %f >= %f", d1, d2)
    }
}
```

---

## Notes for Implementing Agent

1. Focus navigation depends on having an active layout
2. The server may not support window focus - handle gracefully
3. State tracking allows focus to work even without server focus support
4. Wrap-around can be controlled by configuration (future enhancement)
5. Consider adding audible/visual feedback on wrap-around
6. Run `go test ./internal/focus/...` to verify implementation
