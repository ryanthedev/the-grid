# Phase 4: Window Assignment & Layout Application

## Overview

Implement the window assignment algorithms and layout application orchestration. This module ties together configuration, grid calculations, and state management to apply layouts to windows.

**Location**: `grid-cli/internal/layout/` (extends Phase 2)

**Dependencies**: Phase 2 (Grid Engine), Phase 3 (State Manager)

**Parallelizes With**: Phase 6, Phase 7

---

## Scope

1. Assign windows to cells using multiple strategies (auto-flow, pinned, preserve)
2. Orchestrate full layout application flow
3. Generate window placement commands for the server
4. Reconcile state with actual window list from server
5. Handle window filtering (exclude floating, minimized, etc.)

---

## Files to Create

```
grid-cli/internal/layout/
├── assignment.go   # Window-to-cell assignment algorithms
├── apply.go        # Layout application orchestration
└── reconcile.go    # State synchronization with server
```

---

## Implementation

### assignment.go

```go
package layout

import (
    "sort"

    "github.com/yourusername/grid-cli/internal/config"
    "github.com/yourusername/grid-cli/internal/types"
)

// Window represents a window from the server
// This should match the structure returned by the server's dump command
type Window struct {
    ID          uint32
    Title       string
    AppName     string
    BundleID    string
    PID         int
    Frame       types.Rect
    SpaceIDs    []uint64  // Spaces this window is on
    IsMinimized bool
    IsHidden    bool
    Level       int       // Window level (normal, floating, etc.)
}

// AssignmentResult contains the result of window assignment
type AssignmentResult struct {
    Assignments map[string][]uint32 // cellID -> window IDs
    Floating    []uint32            // Windows that should float (not tiled)
    Excluded    []uint32            // Windows excluded from layout
}

// AssignWindows distributes windows to cells
// Parameters:
//   - windows: Windows from server (filtered to current space)
//   - layout: The layout being applied
//   - cellBounds: Pre-calculated cell bounds
//   - appRules: Application-specific rules
//   - previousAssignments: Previous window-to-cell mappings (for preserve strategy)
//   - strategy: How to assign windows
//
// Returns: AssignmentResult with cell assignments and floating windows
func AssignWindows(
    windows []Window,
    layout *types.Layout,
    cellBounds map[string]types.Rect,
    appRules []config.AppRule,
    previousAssignments map[string][]uint32,
    strategy types.AssignmentStrategy,
) *AssignmentResult {
    result := &AssignmentResult{
        Assignments: make(map[string][]uint32),
        Floating:    make([]uint32, 0),
        Excluded:    make([]uint32, 0),
    }

    // Initialize empty assignments for all cells
    for _, cell := range layout.Cells {
        result.Assignments[cell.ID] = make([]uint32, 0)
    }

    // Filter windows and identify floating
    var tileable []Window
    for _, w := range windows {
        // Check if window should float
        if shouldFloat(w, appRules) {
            result.Floating = append(result.Floating, w.ID)
            continue
        }

        // Check if window should be excluded
        if shouldExclude(w) {
            result.Excluded = append(result.Excluded, w.ID)
            continue
        }

        tileable = append(tileable, w)
    }

    // Apply assignment strategy
    switch strategy {
    case types.AssignPinned:
        assignPinned(tileable, layout, appRules, result)
    case types.AssignPreserve:
        assignPreserve(tileable, layout, previousAssignments, result)
    default:
        assignAutoFlow(tileable, layout, cellBounds, result)
    }

    return result
}

// shouldFloat checks if a window should be floating based on rules
func shouldFloat(w Window, rules []config.AppRule) bool {
    for _, rule := range rules {
        if rule.App == w.AppName || rule.App == w.BundleID {
            return rule.Float
        }
    }
    return false
}

// shouldExclude checks if a window should be excluded from layout
func shouldExclude(w Window) bool {
    // Exclude minimized windows
    if w.IsMinimized {
        return true
    }

    // Exclude hidden windows
    if w.IsHidden {
        return true
    }

    // Exclude special window levels (e.g., menus, tooltips)
    // Level 0 is normal, higher levels are overlay windows
    if w.Level > 0 {
        return true
    }

    return false
}

// assignAutoFlow distributes windows evenly across cells
func assignAutoFlow(windows []Window, layout *types.Layout, cellBounds map[string]types.Rect, result *AssignmentResult) {
    if len(windows) == 0 {
        return
    }

    // Sort cells by visual position (left-to-right, top-to-bottom)
    sortedCells := SortCellsByPosition(cellBounds)

    // Round-robin assignment
    cellIndex := 0
    for _, w := range windows {
        cellID := sortedCells[cellIndex%len(sortedCells)]
        result.Assignments[cellID] = append(result.Assignments[cellID], w.ID)
        cellIndex++
    }
}

// assignPinned assigns windows to preferred cells based on app rules
func assignPinned(windows []Window, layout *types.Layout, rules []config.AppRule, result *AssignmentResult) {
    var unpinned []Window

    // First pass: assign pinned windows
    for _, w := range windows {
        assigned := false
        for _, rule := range rules {
            if (rule.App == w.AppName || rule.App == w.BundleID) && rule.PreferredCell != "" {
                // Check if cell exists in layout
                if _, ok := result.Assignments[rule.PreferredCell]; ok {
                    result.Assignments[rule.PreferredCell] = append(result.Assignments[rule.PreferredCell], w.ID)
                    assigned = true
                    break
                }
            }
        }
        if !assigned {
            unpinned = append(unpinned, w)
        }
    }

    // Second pass: distribute unpinned windows
    if len(unpinned) > 0 {
        // Find cells with no windows yet
        emptyCells := make([]string, 0)
        for cellID, windows := range result.Assignments {
            if len(windows) == 0 {
                emptyCells = append(emptyCells, cellID)
            }
        }

        // Sort empty cells for consistent ordering
        sort.Strings(emptyCells)

        // Assign unpinned windows to empty cells first, then round-robin
        for i, w := range unpinned {
            var cellID string
            if i < len(emptyCells) {
                cellID = emptyCells[i]
            } else {
                // Round-robin to cells with fewest windows
                cellID = findLeastPopulatedCell(result.Assignments)
            }
            result.Assignments[cellID] = append(result.Assignments[cellID], w.ID)
        }
    }
}

// assignPreserve tries to maintain previous window-to-cell mappings
func assignPreserve(windows []Window, layout *types.Layout, previous map[string][]uint32, result *AssignmentResult) {
    var unassigned []Window

    // Build a lookup of previous cell assignments
    prevCellMap := make(map[uint32]string)
    for cellID, windowIDs := range previous {
        for _, wid := range windowIDs {
            prevCellMap[wid] = cellID
        }
    }

    // First pass: preserve previous assignments
    for _, w := range windows {
        if prevCellID, ok := prevCellMap[w.ID]; ok {
            // Check if cell exists in new layout
            if _, cellExists := result.Assignments[prevCellID]; cellExists {
                result.Assignments[prevCellID] = append(result.Assignments[prevCellID], w.ID)
                continue
            }
        }
        unassigned = append(unassigned, w)
    }

    // Second pass: auto-flow unassigned windows
    if len(unassigned) > 0 {
        for _, w := range unassigned {
            cellID := findLeastPopulatedCell(result.Assignments)
            result.Assignments[cellID] = append(result.Assignments[cellID], w.ID)
        }
    }
}

// findLeastPopulatedCell returns the cell ID with fewest windows
func findLeastPopulatedCell(assignments map[string][]uint32) string {
    var minCellID string
    minCount := -1

    // Sort keys for deterministic behavior
    var cellIDs []string
    for id := range assignments {
        cellIDs = append(cellIDs, id)
    }
    sort.Strings(cellIDs)

    for _, id := range cellIDs {
        count := len(assignments[id])
        if minCount < 0 || count < minCount {
            minCount = count
            minCellID = id
        }
    }

    return minCellID
}
```

### apply.go

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

// ApplyLayoutOptions configures layout application
type ApplyLayoutOptions struct {
    SpaceID  string                   // Space to apply layout to (empty = current)
    Strategy types.AssignmentStrategy // Window assignment strategy
    Gap      float64                  // Gap between cells in pixels
    Padding  float64                  // Padding between windows in same cell
}

// DefaultApplyOptions returns default options
func DefaultApplyOptions() ApplyLayoutOptions {
    return ApplyLayoutOptions{
        Strategy: types.AssignAutoFlow,
        Gap:      8,
        Padding:  4,
    }
}

// ApplyLayout is the main orchestration function for applying a layout
func ApplyLayout(
    ctx context.Context,
    c *client.Client,
    cfg *config.Config,
    runtimeState *state.RuntimeState,
    layoutID string,
    opts ApplyLayoutOptions,
) error {
    // 1. Get layout from config
    layout, err := cfg.GetLayout(layoutID)
    if err != nil {
        return fmt.Errorf("layout not found: %w", err)
    }

    // 2. Get current state from server
    serverState, err := c.Dump(ctx)
    if err != nil {
        return fmt.Errorf("failed to get server state: %w", err)
    }

    // 3. Determine which space to use
    spaceID := opts.SpaceID
    if spaceID == "" {
        spaceID = getCurrentSpaceID(serverState)
    }

    // 4. Get display bounds for the space
    displayBounds, err := getDisplayBoundsForSpace(serverState, spaceID)
    if err != nil {
        return fmt.Errorf("failed to get display bounds: %w", err)
    }

    // 5. Calculate grid layout
    calculatedLayout := CalculateLayout(layout, displayBounds, opts.Gap)

    // 6. Filter windows for this space
    windows := filterWindowsForSpace(serverState, spaceID)

    // 7. Get previous assignments from state
    spaceState := runtimeState.GetSpace(spaceID)
    previousAssignments := make(map[string][]uint32)
    for cellID, cellState := range spaceState.Cells {
        previousAssignments[cellID] = cellState.Windows
    }

    // 8. Assign windows to cells
    assignment := AssignWindows(
        windows,
        layout,
        calculatedLayout.CellBounds,
        cfg.AppRules,
        previousAssignments,
        opts.Strategy,
    )

    // 9. Get cell modes and ratios from state/config
    cellModes := make(map[string]types.StackMode)
    cellRatios := make(map[string][]float64)

    for cellID := range assignment.Assignments {
        // Check config first
        if mode, ok := layout.CellModes[cellID]; ok {
            cellModes[cellID] = mode
        }
        // State override
        if cellState, ok := spaceState.Cells[cellID]; ok {
            if cellState.StackMode != "" {
                cellModes[cellID] = cellState.StackMode
            }
            if len(cellState.SplitRatios) > 0 {
                cellRatios[cellID] = cellState.SplitRatios
            }
        }
    }

    // 10. Calculate window placements
    placements := CalculateAllWindowPlacements(
        calculatedLayout,
        assignment.Assignments,
        cellModes,
        cellRatios,
        cfg.Settings.DefaultStackMode,
        opts.Padding,
    )

    // 11. Apply placements via server
    if err := ApplyPlacements(ctx, c, placements); err != nil {
        return fmt.Errorf("failed to apply placements: %w", err)
    }

    // 12. Update runtime state
    spaceState.SetCurrentLayout(layoutID, findLayoutIndex(cfg, layoutID))
    runtimeState.SetWindowAssignments(spaceID, assignment.Assignments)
    runtimeState.MarkUpdated()

    // 13. Save state
    if err := runtimeState.Save(); err != nil {
        return fmt.Errorf("failed to save state: %w", err)
    }

    return nil
}

// ApplyPlacements sends window placements to the server
func ApplyPlacements(ctx context.Context, c *client.Client, placements []types.WindowPlacement) error {
    for _, p := range placements {
        params := map[string]interface{}{
            "windowId": p.WindowID,
            "x":        p.Bounds.X,
            "y":        p.Bounds.Y,
            "width":    p.Bounds.Width,
            "height":   p.Bounds.Height,
        }

        _, err := c.CallMethod(ctx, "updateWindow", params)
        if err != nil {
            // Log error but continue with other windows
            fmt.Printf("Warning: failed to update window %d: %v\n", p.WindowID, err)
        }
    }

    return nil
}

// CycleLayout applies the next layout in the cycle for a space
func CycleLayout(
    ctx context.Context,
    c *client.Client,
    cfg *config.Config,
    runtimeState *state.RuntimeState,
    spaceID string,
    opts ApplyLayoutOptions,
) (string, error) {
    // Get available layouts for space
    spaceConfig := cfg.GetSpaceConfig(spaceID)
    var availableLayouts []string
    if spaceConfig != nil && len(spaceConfig.Layouts) > 0 {
        availableLayouts = spaceConfig.Layouts
    } else {
        availableLayouts = cfg.GetLayoutIDs()
    }

    if len(availableLayouts) == 0 {
        return "", fmt.Errorf("no layouts available")
    }

    // Cycle to next layout
    spaceState := runtimeState.GetSpace(spaceID)
    newLayoutID := spaceState.CycleLayout(availableLayouts)

    // Apply the new layout
    opts.SpaceID = spaceID
    opts.Strategy = types.AssignPreserve // Preserve assignments when cycling
    if err := ApplyLayout(ctx, c, cfg, runtimeState, newLayoutID, opts); err != nil {
        return "", err
    }

    return newLayoutID, nil
}

// Helper functions

func getCurrentSpaceID(serverState map[string]interface{}) string {
    // Extract current space ID from server state
    // This depends on the server's state format
    if metadata, ok := serverState["metadata"].(map[string]interface{}); ok {
        if activeSpace, ok := metadata["activeSpace"]; ok {
            return fmt.Sprintf("%v", activeSpace)
        }
    }
    return "1" // Default fallback
}

func getDisplayBoundsForSpace(serverState map[string]interface{}, spaceID string) (types.Rect, error) {
    // Find the display that contains the space and return its visible frame
    // This depends on the server's state format

    displays, ok := serverState["displays"].([]interface{})
    if !ok {
        return types.Rect{}, fmt.Errorf("no displays in state")
    }

    for _, d := range displays {
        display, ok := d.(map[string]interface{})
        if !ok {
            continue
        }

        // Get visible frame (excludes menu bar and dock)
        if frame, ok := display["visibleFrame"].(map[string]interface{}); ok {
            return types.Rect{
                X:      toFloat64(frame["x"]),
                Y:      toFloat64(frame["y"]),
                Width:  toFloat64(frame["width"]),
                Height: toFloat64(frame["height"]),
            }, nil
        }
    }

    return types.Rect{}, fmt.Errorf("no display found for space %s", spaceID)
}

func filterWindowsForSpace(serverState map[string]interface{}, spaceID string) []Window {
    var windows []Window

    rawWindows, ok := serverState["windows"].(map[string]interface{})
    if !ok {
        return windows
    }

    for _, w := range rawWindows {
        win, ok := w.(map[string]interface{})
        if !ok {
            continue
        }

        // Check if window is on this space
        spaces, ok := win["spaces"].([]interface{})
        if !ok {
            continue
        }

        onSpace := false
        for _, s := range spaces {
            if fmt.Sprintf("%v", s) == spaceID {
                onSpace = true
                break
            }
        }

        if !onSpace {
            continue
        }

        // Build Window struct
        window := Window{
            ID:          uint32(toFloat64(win["id"])),
            Title:       toString(win["title"]),
            AppName:     toString(win["appName"]),
            IsMinimized: toBool(win["isMinimized"]),
            IsHidden:    toBool(win["isHidden"]),
            Level:       int(toFloat64(win["level"])),
        }

        if frame, ok := win["frame"].(map[string]interface{}); ok {
            window.Frame = types.Rect{
                X:      toFloat64(frame["x"]),
                Y:      toFloat64(frame["y"]),
                Width:  toFloat64(frame["width"]),
                Height: toFloat64(frame["height"]),
            }
        }

        windows = append(windows, window)
    }

    return windows
}

func findLayoutIndex(cfg *config.Config, layoutID string) int {
    for i, l := range cfg.Layouts {
        if l.ID == layoutID {
            return i
        }
    }
    return 0
}

func toFloat64(v interface{}) float64 {
    switch n := v.(type) {
    case float64:
        return n
    case int:
        return float64(n)
    case int64:
        return float64(n)
    default:
        return 0
    }
}

func toString(v interface{}) string {
    if s, ok := v.(string); ok {
        return s
    }
    return ""
}

func toBool(v interface{}) bool {
    if b, ok := v.(bool); ok {
        return b
    }
    return false
}
```

### reconcile.go

```go
package layout

import (
    "context"

    "github.com/yourusername/grid-cli/internal/client"
    "github.com/yourusername/grid-cli/internal/state"
)

// ReconcileState synchronizes runtime state with actual windows
// This should be called when windows might have changed externally
func ReconcileState(
    ctx context.Context,
    c *client.Client,
    runtimeState *state.RuntimeState,
    spaceID string,
) error {
    // Get current windows from server
    serverState, err := c.Dump(ctx)
    if err != nil {
        return err
    }

    actualWindows := filterWindowsForSpace(serverState, spaceID)
    actualWindowIDs := make(map[uint32]bool)
    for _, w := range actualWindows {
        actualWindowIDs[w.ID] = true
    }

    // Get space state
    spaceState := runtimeState.GetSpaceReadOnly(spaceID)
    if spaceState == nil {
        return nil // No state to reconcile
    }

    // Remove windows that no longer exist
    for cellID, cellState := range spaceState.Cells {
        var validWindows []uint32
        for _, wid := range cellState.Windows {
            if actualWindowIDs[wid] {
                validWindows = append(validWindows, wid)
            }
        }

        if len(validWindows) != len(cellState.Windows) {
            // Windows were removed, update cell
            cell := runtimeState.GetSpace(spaceID).GetCell(cellID)
            cell.Windows = validWindows
            cell.SplitRatios = equalRatios(len(validWindows))
        }
    }

    // Mark state updated and save
    runtimeState.MarkUpdated()
    return runtimeState.Save()
}

// CheckForNewWindows identifies windows not yet assigned to cells
func CheckForNewWindows(
    ctx context.Context,
    c *client.Client,
    runtimeState *state.RuntimeState,
    spaceID string,
) ([]uint32, error) {
    serverState, err := c.Dump(ctx)
    if err != nil {
        return nil, err
    }

    actualWindows := filterWindowsForSpace(serverState, spaceID)

    // Build set of assigned windows
    assignedWindows := make(map[uint32]bool)
    if spaceState := runtimeState.GetSpaceReadOnly(spaceID); spaceState != nil {
        for _, cellState := range spaceState.Cells {
            for _, wid := range cellState.Windows {
                assignedWindows[wid] = true
            }
        }
    }

    // Find unassigned windows
    var newWindows []uint32
    for _, w := range actualWindows {
        if !assignedWindows[w.ID] && !shouldExclude(w) {
            newWindows = append(newWindows, w.ID)
        }
    }

    return newWindows, nil
}

// equalRatios returns equal split ratios
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
```

---

## Integration Points

### Server Communication

The module uses these server methods:
- `dump` - Get complete window manager state
- `updateWindow` - Set window position and size

### State Manager

Interacts with Phase 3 state module:
- Reads previous window assignments
- Writes new assignments after layout application
- Manages layout cycling state

### Config

Uses Phase 1 config module:
- Gets layout definitions
- Gets space configuration
- Gets app rules for pinning/floating

---

## Acceptance Criteria

1. Auto-flow assignment distributes windows evenly
2. Pinned assignment respects app rules
3. Preserve assignment maintains previous positions
4. Floating windows are excluded from tiling
5. Layout application sends correct bounds to server
6. State is properly updated after application
7. Layout cycling works correctly

---

## Test Scenarios

```go
func TestAssignAutoFlow(t *testing.T) {
    windows := []Window{
        {ID: 1}, {ID: 2}, {ID: 3}, {ID: 4},
    }
    layout := &types.Layout{
        Cells: []types.Cell{
            {ID: "left"}, {ID: "right"},
        },
    }
    cellBounds := map[string]types.Rect{
        "left":  {X: 0, Y: 0, Width: 500, Height: 1000},
        "right": {X: 500, Y: 0, Width: 500, Height: 1000},
    }

    result := AssignWindows(windows, layout, cellBounds, nil, nil, types.AssignAutoFlow)

    // Expect 2 windows per cell
    if len(result.Assignments["left"]) != 2 {
        t.Error("expected 2 windows in left cell")
    }
    if len(result.Assignments["right"]) != 2 {
        t.Error("expected 2 windows in right cell")
    }
}

func TestAssignPinned(t *testing.T) {
    windows := []Window{
        {ID: 1, AppName: "Terminal"},
        {ID: 2, AppName: "Safari"},
        {ID: 3, AppName: "Finder"},
    }
    layout := &types.Layout{
        Cells: []types.Cell{
            {ID: "main"}, {ID: "side"},
        },
    }
    appRules := []config.AppRule{
        {App: "Terminal", PreferredCell: "side"},
    }

    result := AssignWindows(windows, layout, nil, appRules, nil, types.AssignPinned)

    // Terminal should be in side
    found := false
    for _, wid := range result.Assignments["side"] {
        if wid == 1 {
            found = true
            break
        }
    }
    if !found {
        t.Error("Terminal should be in side cell")
    }
}

func TestAssignPreserve(t *testing.T) {
    windows := []Window{
        {ID: 1}, {ID: 2}, {ID: 3},
    }
    layout := &types.Layout{
        Cells: []types.Cell{
            {ID: "a"}, {ID: "b"},
        },
    }
    previous := map[string][]uint32{
        "a": {1, 3},
        "b": {2},
    }

    result := AssignWindows(windows, layout, nil, nil, previous, types.AssignPreserve)

    // Windows should maintain previous cells
    if len(result.Assignments["a"]) != 2 || result.Assignments["a"][0] != 1 {
        t.Error("window 1 should be in cell a")
    }
    if len(result.Assignments["b"]) != 1 || result.Assignments["b"][0] != 2 {
        t.Error("window 2 should be in cell b")
    }
}

func TestFloatingWindows(t *testing.T) {
    windows := []Window{
        {ID: 1, AppName: "Finder"},
        {ID: 2, AppName: "Safari"},
    }
    appRules := []config.AppRule{
        {App: "Finder", Float: true},
    }

    result := AssignWindows(windows, &types.Layout{Cells: []types.Cell{{ID: "main"}}}, nil, appRules, nil, types.AssignAutoFlow)

    if len(result.Floating) != 1 || result.Floating[0] != 1 {
        t.Error("Finder should be floating")
    }
}
```

---

## Notes for Implementing Agent

1. The Window struct should match the server's response format
2. Error handling should be graceful - one failed window shouldn't stop others
3. State updates should be atomic where possible
4. The `Dump` method returns the full server state as a map
5. Consider adding logging for debugging assignment decisions
6. Window IDs are uint32, matching the server's format
7. Run `go test ./internal/layout/...` to verify implementation
