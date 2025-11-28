package focus

import (
	"context"
	"fmt"
	"math"

	"github.com/yourusername/grid-cli/internal/client"
	"github.com/yourusername/grid-cli/internal/config"
	"github.com/yourusername/grid-cli/internal/layout"
	"github.com/yourusername/grid-cli/internal/server"
	"github.com/yourusername/grid-cli/internal/state"
	"github.com/yourusername/grid-cli/internal/types"
)

// CycleFocus cycles to the next/prev window in the focused cell.
// Operates entirely on LOCAL state (which must be reconciled first).
// Returns the window ID that was focused.
func CycleFocus(
	ctx context.Context,
	c *client.Client,
	rs *state.RuntimeState,
	spaceID string,
	forward bool,
) (uint32, error) {
	spaceState := rs.GetSpaceReadOnly(spaceID)
	if spaceState == nil {
		return 0, fmt.Errorf("no layout applied to space %s", spaceID)
	}

	cellID := spaceState.FocusedCell
	if cellID == "" {
		// Auto-select first cell with windows
		cellID = findFirstCellWithWindows(spaceState)
		if cellID == "" {
			return 0, fmt.Errorf("no cells with windows")
		}
	}

	cell := spaceState.Cells[cellID]
	if cell == nil || len(cell.Windows) == 0 {
		return 0, fmt.Errorf("no windows in focused cell %s", cellID)
	}

	// Calculate next window index
	idx := spaceState.FocusedWindow
	if idx < 0 || idx >= len(cell.Windows) {
		idx = 0
	}

	if len(cell.Windows) == 1 {
		// Only one window, just ensure it's focused
		windowID := cell.Windows[0]
		if err := focusWindow(ctx, c, windowID); err != nil {
			return 0, err
		}
		// Update state
		mutableSpace := rs.GetSpace(spaceID)
		mutableSpace.SetFocus(cellID, 0)
		rs.MarkUpdated()
		rs.Save()
		return windowID, nil
	}

	// Cycle to next/prev window
	if forward {
		idx = (idx + 1) % len(cell.Windows)
	} else {
		idx = (idx - 1 + len(cell.Windows)) % len(cell.Windows)
	}

	windowID := cell.Windows[idx]

	// Focus via server
	if err := focusWindow(ctx, c, windowID); err != nil {
		return 0, err
	}

	// Update local state
	mutableSpace := rs.GetSpace(spaceID)
	mutableSpace.SetFocus(cellID, idx)
	rs.MarkUpdated()
	rs.Save()

	return windowID, nil
}

// findFirstCellWithWindows returns the first cell ID that has windows.
func findFirstCellWithWindows(spaceState *state.SpaceState) string {
	for cellID, cell := range spaceState.Cells {
		if len(cell.Windows) > 0 {
			return cellID
		}
	}
	return ""
}

// focusWindow requests the server to focus a window.
func focusWindow(ctx context.Context, c *client.Client, windowID uint32) error {
	// Try window.focus first
	_, err := c.CallMethod(ctx, "window.focus", map[string]interface{}{
		"windowId": windowID,
	})
	if err == nil {
		return nil
	}

	// Fallback to window.raise
	_, err = c.CallMethod(ctx, "window.raise", map[string]interface{}{
		"windowId": windowID,
	})
	if err != nil {
		return fmt.Errorf("focus/raise failed for window %d: %w", windowID, err)
	}

	return nil
}

// MoveFocus moves focus to adjacent cell in direction.
// Requires config and snapshot to calculate layout bounds.
func MoveFocus(
	ctx context.Context,
	c *client.Client,
	snap *server.Snapshot,
	cfg *config.Config,
	rs *state.RuntimeState,
	direction types.Direction,
	wrapAround bool,
) (uint32, error) {
	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil || spaceState.CurrentLayoutID == "" {
		return 0, fmt.Errorf("no layout applied")
	}

	// Get current layout and calculate bounds
	layoutDef, err := cfg.GetLayout(spaceState.CurrentLayoutID)
	if err != nil {
		return 0, fmt.Errorf("layout not found: %w", err)
	}
	calculated := layout.CalculateLayout(layoutDef, snap.DisplayBounds, float64(cfg.Settings.CellPadding))

	// Find current cell
	currentCell := spaceState.FocusedCell
	if currentCell == "" {
		currentCell = findFirstCellWithWindows(spaceState)
		if currentCell == "" {
			return 0, fmt.Errorf("no cells with windows")
		}
	}

	// Find adjacent cells
	adjacentMap := layout.GetAdjacentCells(currentCell, calculated.CellBounds)
	candidates := adjacentMap[direction]

	if len(candidates) == 0 {
		if !wrapAround {
			return 0, fmt.Errorf("no cell in direction %s", direction.String())
		}
		// Wrap: find cell on opposite edge
		candidates = findWrapTarget(direction, currentCell, calculated.CellBounds)
		if len(candidates) == 0 {
			return 0, fmt.Errorf("no cell in direction %s (wrap)", direction.String())
		}
	}

	// Pick closest candidate
	targetCell := pickClosestCell(currentCell, candidates, calculated.CellBounds)

	// Focus the target cell
	return focusCellByID(ctx, c, rs, snap.SpaceID, targetCell)
}

// FocusCell focuses a specific cell by ID.
func FocusCell(
	ctx context.Context,
	c *client.Client,
	rs *state.RuntimeState,
	spaceID string,
	cellID string,
) (uint32, error) {
	return focusCellByID(ctx, c, rs, spaceID, cellID)
}

// focusCellByID is internal helper to focus a cell.
func focusCellByID(ctx context.Context, c *client.Client, rs *state.RuntimeState, spaceID string, cellID string) (uint32, error) {
	mutableSpace := rs.GetSpace(spaceID)
	cell := mutableSpace.Cells[cellID]
	if cell == nil || len(cell.Windows) == 0 {
		return 0, fmt.Errorf("no windows in cell %s", cellID)
	}

	windowID := cell.Windows[0]
	if err := focusWindow(ctx, c, windowID); err != nil {
		return 0, err
	}
	mutableSpace.SetFocus(cellID, 0)
	rs.MarkUpdated()
	rs.Save()
	return windowID, nil
}

// findWrapTarget finds cells on the opposite edge for wrap-around navigation.
func findWrapTarget(direction types.Direction, currentCell string, cellBounds map[string]types.Rect) []string {
	current, ok := cellBounds[currentCell]
	if !ok {
		return nil
	}

	var candidates []string

	for cellID, bounds := range cellBounds {
		if cellID == currentCell {
			continue
		}

		switch direction {
		case types.DirLeft:
			// Wrap to right edge: find rightmost cells that overlap vertically
			if overlapsVertically(current, bounds) {
				candidates = append(candidates, cellID)
			}
		case types.DirRight:
			// Wrap to left edge: find leftmost cells that overlap vertically
			if overlapsVertically(current, bounds) {
				candidates = append(candidates, cellID)
			}
		case types.DirUp:
			// Wrap to bottom: find bottommost cells that overlap horizontally
			if overlapsHorizontally(current, bounds) {
				candidates = append(candidates, cellID)
			}
		case types.DirDown:
			// Wrap to top: find topmost cells that overlap horizontally
			if overlapsHorizontally(current, bounds) {
				candidates = append(candidates, cellID)
			}
		}
	}

	// Sort by position based on direction (find the extremes)
	if len(candidates) > 0 {
		// For wrap, we want the cells on the opposite edge
		switch direction {
		case types.DirLeft:
			// Find rightmost
			candidates = filterByEdge(candidates, cellBounds, func(a, b types.Rect) bool {
				return a.X+a.Width > b.X+b.Width
			})
		case types.DirRight:
			// Find leftmost
			candidates = filterByEdge(candidates, cellBounds, func(a, b types.Rect) bool {
				return a.X < b.X
			})
		case types.DirUp:
			// Find bottommost
			candidates = filterByEdge(candidates, cellBounds, func(a, b types.Rect) bool {
				return a.Y+a.Height > b.Y+b.Height
			})
		case types.DirDown:
			// Find topmost
			candidates = filterByEdge(candidates, cellBounds, func(a, b types.Rect) bool {
				return a.Y < b.Y
			})
		}
	}

	return candidates
}

// filterByEdge returns cells that are at the extreme edge.
func filterByEdge(cells []string, cellBounds map[string]types.Rect, better func(a, b types.Rect) bool) []string {
	if len(cells) == 0 {
		return nil
	}

	best := cells[0]
	bestBounds := cellBounds[best]

	for _, cellID := range cells[1:] {
		bounds := cellBounds[cellID]
		if better(bounds, bestBounds) {
			best = cellID
			bestBounds = bounds
		}
	}

	// Return all cells at the same edge position
	var result []string
	for _, cellID := range cells {
		bounds := cellBounds[cellID]
		if !better(bestBounds, bounds) && !better(bounds, bestBounds) {
			result = append(result, cellID)
		} else if bounds == bestBounds {
			result = append(result, cellID)
		}
	}

	if len(result) == 0 {
		result = []string{best}
	}

	return result
}

// pickClosestCell picks the cell closest to the current cell's center.
func pickClosestCell(currentCell string, candidates []string, cellBounds map[string]types.Rect) string {
	if len(candidates) == 0 {
		return ""
	}
	if len(candidates) == 1 {
		return candidates[0]
	}

	currentBounds, ok := cellBounds[currentCell]
	if !ok {
		return candidates[0]
	}
	currentCenter := currentBounds.Center()

	closest := candidates[0]
	closestDist := math.MaxFloat64

	for _, cellID := range candidates {
		bounds := cellBounds[cellID]
		center := bounds.Center()
		dist := math.Sqrt(math.Pow(center.X-currentCenter.X, 2) + math.Pow(center.Y-currentCenter.Y, 2))
		if dist < closestDist {
			closestDist = dist
			closest = cellID
		}
	}

	return closest
}

// overlapsVertically checks if two rects have vertical overlap.
func overlapsVertically(a, b types.Rect) bool {
	return a.Y < b.Y+b.Height && a.Y+a.Height > b.Y
}

// overlapsHorizontally checks if two rects have horizontal overlap.
func overlapsHorizontally(a, b types.Rect) bool {
	return a.X < b.X+b.Width && a.X+a.Width > b.X
}
