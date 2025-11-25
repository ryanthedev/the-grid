# Phase 7: Split Ratio Management

## Overview

Implement split ratio management for windows within cells. This allows users to resize windows within a cell by adjusting the split ratios between them.

**Location**: `grid-cli/internal/layout/` (extends Phase 2)

**Dependencies**: Phase 2 (Grid Engine), Phase 3 (State Manager)

**Parallelizes With**: Phase 4, Phase 6

---

## Scope

1. Manage split ratios for windows within cells
2. Adjust ratios when user resizes
3. Recalculate ratios when windows are added/removed
4. Persist ratios in state
5. Enforce minimum window sizes
6. Apply adjusted bounds to server

---

## Files to Create/Extend

```
grid-cli/internal/layout/
├── splits.go       # Split ratio calculations
└── resize.go       # Interactive resize operations
```

---

## Implementation

### splits.go

```go
package layout

import (
    "fmt"
)

const (
    // MinimumRatio is the smallest ratio a window can have
    MinimumRatio = 0.1 // 10% minimum

    // DefaultResizeAmount is the default resize step
    DefaultResizeAmount = 0.1 // 10%
)

// InitializeSplitRatios creates equal ratios for N windows
func InitializeSplitRatios(windowCount int) []float64 {
    if windowCount <= 0 {
        return nil
    }

    ratio := 1.0 / float64(windowCount)
    ratios := make([]float64, windowCount)
    for i := range ratios {
        ratios[i] = ratio
    }
    return ratios
}

// NormalizeSplitRatios ensures ratios sum to 1.0
func NormalizeSplitRatios(ratios []float64) []float64 {
    if len(ratios) == 0 {
        return nil
    }

    sum := 0.0
    for _, r := range ratios {
        sum += r
    }

    if sum == 0 {
        return InitializeSplitRatios(len(ratios))
    }

    normalized := make([]float64, len(ratios))
    for i, r := range ratios {
        normalized[i] = r / sum
    }
    return normalized
}

// AdjustSplitRatio modifies the ratio between two adjacent windows
// Parameters:
//   - ratios: Current split ratios
//   - index: Index of window to grow (will shrink window at index+1)
//   - delta: Change in ratio (positive = grow, negative = shrink)
//   - minRatio: Minimum allowed ratio per window
//
// Returns: New ratios array
func AdjustSplitRatio(ratios []float64, index int, delta float64, minRatio float64) ([]float64, error) {
    if len(ratios) < 2 {
        return ratios, fmt.Errorf("need at least 2 windows to adjust splits")
    }

    if index < 0 || index >= len(ratios)-1 {
        return ratios, fmt.Errorf("invalid index for split adjustment: %d", index)
    }

    newRatios := make([]float64, len(ratios))
    copy(newRatios, ratios)

    // Calculate proposed new values
    newFirst := newRatios[index] + delta
    newSecond := newRatios[index+1] - delta

    // Enforce minimum ratios
    if newFirst < minRatio {
        delta = newRatios[index] - minRatio
        newFirst = minRatio
        newSecond = newRatios[index+1] + (newRatios[index] - minRatio)
    }
    if newSecond < minRatio {
        delta = newRatios[index+1] - minRatio
        newSecond = minRatio
        newFirst = newRatios[index] + (newRatios[index+1] - minRatio)
    }

    newRatios[index] = newFirst
    newRatios[index+1] = newSecond

    // Normalize to ensure sum is exactly 1.0
    return NormalizeSplitRatios(newRatios), nil
}

// AdjustSplitRatioAtBoundary adjusts the split at a specific boundary
// boundaryIndex is the index between windows (0 = between window 0 and 1)
func AdjustSplitRatioAtBoundary(ratios []float64, boundaryIndex int, delta float64) ([]float64, error) {
    return AdjustSplitRatio(ratios, boundaryIndex, delta, MinimumRatio)
}

// RecalculateSplitsAfterRemoval adjusts ratios when a window is removed
// The removed window's ratio is distributed to remaining windows
func RecalculateSplitsAfterRemoval(ratios []float64, removedIndex int) []float64 {
    if len(ratios) <= 1 {
        return []float64{1.0}
    }

    if removedIndex < 0 || removedIndex >= len(ratios) {
        return ratios
    }

    removed := ratios[removedIndex]
    newRatios := make([]float64, 0, len(ratios)-1)

    // Copy all except removed
    for i, r := range ratios {
        if i != removedIndex {
            newRatios = append(newRatios, r)
        }
    }

    // Distribute removed window's ratio equally
    bonus := removed / float64(len(newRatios))
    for i := range newRatios {
        newRatios[i] += bonus
    }

    return NormalizeSplitRatios(newRatios)
}

// RecalculateSplitsAfterAddition adjusts ratios when a window is added
// The new window gets an equal share, existing windows are scaled proportionally
func RecalculateSplitsAfterAddition(ratios []float64, newIndex int) []float64 {
    oldCount := len(ratios)
    newCount := oldCount + 1

    if oldCount == 0 {
        return []float64{1.0}
    }

    // New window gets equal share
    newRatio := 1.0 / float64(newCount)

    // Scale existing ratios
    scale := 1.0 - newRatio
    newRatios := make([]float64, newCount)

    for i, r := range ratios {
        destIndex := i
        if i >= newIndex {
            destIndex = i + 1
        }
        newRatios[destIndex] = r * scale
    }
    newRatios[newIndex] = newRatio

    return NormalizeSplitRatios(newRatios)
}

// RecalculateSplitsAfterReorder adjusts ratios when windows are reordered
// Maintains the ratio at each position, just with different windows
func RecalculateSplitsAfterReorder(ratios []float64, oldIndex, newIndex int) []float64 {
    if oldIndex == newIndex || oldIndex < 0 || newIndex < 0 ||
        oldIndex >= len(ratios) || newIndex >= len(ratios) {
        return ratios
    }

    newRatios := make([]float64, len(ratios))
    copy(newRatios, ratios)

    // Move the ratio along with the window
    ratio := newRatios[oldIndex]
    if oldIndex < newIndex {
        // Shift left
        for i := oldIndex; i < newIndex; i++ {
            newRatios[i] = newRatios[i+1]
        }
    } else {
        // Shift right
        for i := oldIndex; i > newIndex; i-- {
            newRatios[i] = newRatios[i-1]
        }
    }
    newRatios[newIndex] = ratio

    return newRatios
}

// CalculateSplitBoundary returns the position of a split boundary
// For vertical stacking, this is the Y position between windows
// For horizontal stacking, this is the X position
func CalculateSplitBoundary(cellSize float64, ratios []float64, boundaryIndex int, padding float64) float64 {
    if boundaryIndex < 0 || boundaryIndex >= len(ratios) {
        return 0
    }

    // Sum ratios up to and including boundaryIndex
    totalRatio := 0.0
    for i := 0; i <= boundaryIndex; i++ {
        totalRatio += ratios[i]
    }

    // Calculate available space (excluding padding between windows)
    paddingTotal := padding * float64(len(ratios)-1)
    availableSpace := cellSize - paddingTotal

    // Position includes window sizes plus padding between them
    position := availableSpace*totalRatio + padding*float64(boundaryIndex+1)

    return position
}
```

### resize.go

```go
package layout

import (
    "context"
    "fmt"

    "github.com/yourusername/grid-cli/internal/client"
    "github.com/yourusername/grid-cli/internal/config"
    "github.com/yourusername/grid-cli/internal/state"
    "github.com/yourusername/grid-cli/internal/types"
)

// ResizeDirection indicates which direction to resize
type ResizeDirection int

const (
    ResizeGrow ResizeDirection = iota
    ResizeShrink
)

// AdjustSplit adjusts the split ratio for the focused window
// delta is the change in ratio (positive = grow, negative = shrink)
func AdjustSplit(
    ctx context.Context,
    c *client.Client,
    cfg *config.Config,
    runtimeState *state.RuntimeState,
    delta float64,
) error {
    // Get current space
    serverState, err := c.Dump(ctx)
    if err != nil {
        return err
    }

    spaceID := getCurrentSpaceID(serverState)
    spaceState := runtimeState.GetSpace(spaceID)

    if spaceState.CurrentLayoutID == "" {
        return fmt.Errorf("no layout applied")
    }

    if spaceState.FocusedCell == "" {
        return fmt.Errorf("no cell is focused")
    }

    cellState, ok := spaceState.Cells[spaceState.FocusedCell]
    if !ok || len(cellState.Windows) < 2 {
        return fmt.Errorf("need at least 2 windows in cell to adjust splits")
    }

    // Determine which boundary to adjust based on focused window
    // Positive delta grows the focused window, shrinks the next one
    boundaryIndex := spaceState.FocusedWindow
    if boundaryIndex >= len(cellState.Windows)-1 {
        // Last window - adjust boundary before it
        boundaryIndex = len(cellState.Windows) - 2
        delta = -delta // Invert because we're adjusting from the other side
    }

    // Adjust ratios
    newRatios, err := AdjustSplitRatio(cellState.SplitRatios, boundaryIndex, delta, MinimumRatio)
    if err != nil {
        return err
    }

    cellState.SplitRatios = newRatios

    // Recalculate and apply window bounds
    if err := reapplyCell(ctx, c, cfg, runtimeState, spaceID, spaceState.FocusedCell); err != nil {
        return err
    }

    // Save state
    runtimeState.MarkUpdated()
    return runtimeState.Save()
}

// ResetSplits resets all splits in the focused cell to equal
func ResetSplits(
    ctx context.Context,
    c *client.Client,
    cfg *config.Config,
    runtimeState *state.RuntimeState,
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
    if !ok {
        return fmt.Errorf("focused cell not found in state")
    }

    // Reset to equal ratios
    cellState.SplitRatios = InitializeSplitRatios(len(cellState.Windows))

    // Recalculate and apply window bounds
    if err := reapplyCell(ctx, c, cfg, runtimeState, spaceID, spaceState.FocusedCell); err != nil {
        return err
    }

    // Save state
    runtimeState.MarkUpdated()
    return runtimeState.Save()
}

// ResetAllSplits resets splits in all cells of the current layout
func ResetAllSplits(
    ctx context.Context,
    c *client.Client,
    cfg *config.Config,
    runtimeState *state.RuntimeState,
) error {
    serverState, err := c.Dump(ctx)
    if err != nil {
        return err
    }

    spaceID := getCurrentSpaceID(serverState)
    spaceState := runtimeState.GetSpace(spaceID)

    // Reset all cells
    for _, cellState := range spaceState.Cells {
        cellState.SplitRatios = InitializeSplitRatios(len(cellState.Windows))
    }

    // Reapply entire layout
    opts := DefaultApplyOptions()
    opts.SpaceID = spaceID
    opts.Strategy = types.AssignPreserve

    if err := ApplyLayout(ctx, c, cfg, runtimeState, spaceState.CurrentLayoutID, opts); err != nil {
        return err
    }

    return nil
}

// reapplyCell recalculates and applies bounds for a single cell
func reapplyCell(
    ctx context.Context,
    c *client.Client,
    cfg *config.Config,
    runtimeState *state.RuntimeState,
    spaceID string,
    cellID string,
) error {
    spaceState := runtimeState.GetSpace(spaceID)

    // Get layout
    l, err := cfg.GetLayout(spaceState.CurrentLayoutID)
    if err != nil {
        return err
    }

    // Get display bounds
    serverState, err := c.Dump(ctx)
    if err != nil {
        return err
    }

    displayBounds, err := getDisplayBoundsForSpace(serverState, spaceID)
    if err != nil {
        return err
    }

    // Calculate layout
    gap := float64(cfg.Settings.CellPadding)
    calculatedLayout := CalculateLayout(l, displayBounds, gap)

    // Get cell bounds
    cellBounds, ok := calculatedLayout.CellBounds[cellID]
    if !ok {
        return fmt.Errorf("cell not found: %s", cellID)
    }

    // Get cell state
    cellState := spaceState.Cells[cellID]
    if cellState == nil || len(cellState.Windows) == 0 {
        return nil // Nothing to apply
    }

    // Determine stack mode
    mode := cfg.Settings.DefaultStackMode
    if m, ok := l.CellModes[cellID]; ok && m != "" {
        mode = m
    }
    if cellState.StackMode != "" {
        mode = cellState.StackMode
    }

    // Calculate window bounds
    padding := float64(cfg.Settings.CellPadding) / 2 // Use half padding between windows
    windowBounds := CalculateWindowBounds(cellBounds, len(cellState.Windows), mode, cellState.SplitRatios, padding)

    // Apply bounds to server
    for i, windowID := range cellState.Windows {
        if i >= len(windowBounds) {
            break
        }

        params := map[string]interface{}{
            "windowId": windowID,
            "x":        windowBounds[i].X,
            "y":        windowBounds[i].Y,
            "width":    windowBounds[i].Width,
            "height":   windowBounds[i].Height,
        }

        if _, err := c.CallMethod(ctx, "updateWindow", params); err != nil {
            fmt.Printf("Warning: failed to update window %d: %v\n", windowID, err)
        }
    }

    return nil
}

// GetSplitInfo returns information about splits in the focused cell
func GetSplitInfo(runtimeState *state.RuntimeState, spaceID string) (*SplitInfo, error) {
    spaceState := runtimeState.GetSpaceReadOnly(spaceID)
    if spaceState == nil {
        return nil, fmt.Errorf("no state for space %s", spaceID)
    }

    if spaceState.FocusedCell == "" {
        return nil, fmt.Errorf("no cell is focused")
    }

    cellState, ok := spaceState.Cells[spaceState.FocusedCell]
    if !ok {
        return nil, fmt.Errorf("focused cell not found")
    }

    return &SplitInfo{
        CellID:        spaceState.FocusedCell,
        WindowCount:   len(cellState.Windows),
        Ratios:        cellState.SplitRatios,
        FocusedIndex:  spaceState.FocusedWindow,
    }, nil
}

// SplitInfo contains information about splits in a cell
type SplitInfo struct {
    CellID       string
    WindowCount  int
    Ratios       []float64
    FocusedIndex int
}

// Helper to get current space ID
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
        return types.Rect{}, fmt.Errorf("no displays")
    }

    for _, d := range displays {
        display, ok := d.(map[string]interface{})
        if !ok {
            continue
        }

        if frame, ok := display["visibleFrame"].(map[string]interface{}); ok {
            return types.Rect{
                X:      toFloat(frame["x"]),
                Y:      toFloat(frame["y"]),
                Width:  toFloat(frame["width"]),
                Height: toFloat(frame["height"]),
            }, nil
        }
    }

    return types.Rect{}, fmt.Errorf("no display found")
}

func toFloat(v interface{}) float64 {
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

---

## Split Ratio Concepts

### Ratio Representation

Split ratios are stored as an array of floats that sum to 1.0:
- 2 windows: `[0.5, 0.5]` (equal) or `[0.7, 0.3]` (unequal)
- 3 windows: `[0.33, 0.33, 0.34]` (equal) or `[0.5, 0.25, 0.25]`

### Adjustment Model

When adjusting splits:
1. User specifies a delta (e.g., +0.1 to grow 10%)
2. The focused window's ratio increases by delta
3. The adjacent window's ratio decreases by delta
4. Minimum ratio (10%) is enforced for both
5. Ratios are normalized to sum to 1.0

### Boundary Model

For N windows, there are N-1 boundaries:
```
Window 0 | Window 1 | Window 2
       ↑          ↑
   Boundary 0  Boundary 1
```

Adjusting boundary 0 affects windows 0 and 1.

---

## Acceptance Criteria

1. Equal ratios are correctly initialized
2. Ratio adjustments respect minimum bounds
3. Ratios always sum to 1.0
4. Window removal redistributes ratios correctly
5. Window addition scales existing ratios correctly
6. Changes are persisted to state
7. Server receives updated window bounds

---

## Test Scenarios

```go
func TestInitializeSplitRatios(t *testing.T) {
    tests := []struct {
        count    int
        expected []float64
    }{
        {1, []float64{1.0}},
        {2, []float64{0.5, 0.5}},
        {3, []float64{0.333..., 0.333..., 0.333...}},
    }
    // ... verify each case
}

func TestAdjustSplitRatio(t *testing.T) {
    ratios := []float64{0.5, 0.5}

    // Grow first window by 10%
    newRatios, err := AdjustSplitRatio(ratios, 0, 0.1, 0.1)
    if err != nil {
        t.Fatal(err)
    }

    if newRatios[0] != 0.6 || newRatios[1] != 0.4 {
        t.Errorf("expected [0.6, 0.4], got %v", newRatios)
    }
}

func TestAdjustSplitRatio_MinimumEnforced(t *testing.T) {
    ratios := []float64{0.15, 0.85}

    // Try to shrink first window beyond minimum
    newRatios, err := AdjustSplitRatio(ratios, 0, -0.1, 0.1)
    if err != nil {
        t.Fatal(err)
    }

    // First window should be clamped at minimum
    if newRatios[0] < 0.1 {
        t.Errorf("first ratio below minimum: %f", newRatios[0])
    }
}

func TestRecalculateSplitsAfterRemoval(t *testing.T) {
    ratios := []float64{0.4, 0.3, 0.3}

    // Remove middle window
    newRatios := RecalculateSplitsAfterRemoval(ratios, 1)

    if len(newRatios) != 2 {
        t.Fatalf("expected 2 ratios, got %d", len(newRatios))
    }

    // Each remaining window should get half of removed window's ratio
    // 0.4 + 0.15 = 0.55, 0.3 + 0.15 = 0.45
    if newRatios[0] != 0.55 || newRatios[1] != 0.45 {
        t.Errorf("expected [0.55, 0.45], got %v", newRatios)
    }
}

func TestRecalculateSplitsAfterAddition(t *testing.T) {
    ratios := []float64{0.6, 0.4}

    // Add window at position 1
    newRatios := RecalculateSplitsAfterAddition(ratios, 1)

    if len(newRatios) != 3 {
        t.Fatalf("expected 3 ratios, got %d", len(newRatios))
    }

    // New window gets 1/3, existing scaled by 2/3
    // 0.6 * 2/3 = 0.4, new = 0.33, 0.4 * 2/3 = 0.267
    sum := newRatios[0] + newRatios[1] + newRatios[2]
    if sum < 0.99 || sum > 1.01 {
        t.Errorf("ratios should sum to 1.0, got %f", sum)
    }
}

func TestNormalizeSplitRatios(t *testing.T) {
    // Should handle non-normalized input
    ratios := []float64{1, 2, 3} // Sum = 6
    normalized := NormalizeSplitRatios(ratios)

    expected := []float64{1.0/6, 2.0/6, 3.0/6}
    for i := range normalized {
        if normalized[i] != expected[i] {
            t.Errorf("index %d: expected %f, got %f", i, expected[i], normalized[i])
        }
    }
}
```

---

## Notes for Implementing Agent

1. Split ratios are stored in state per cell, not per layout
2. Minimum ratio prevents windows from becoming too small
3. The adjustment delta is typically 0.1 (10%) but can be customized
4. When applying changes, only the affected cell needs to be re-rendered
5. Consider animation support in the future (server-side or client-side)
6. Run `go test ./internal/layout/...` to verify implementation
