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

// Options configures focus operations
type Options struct {
	SpaceID    string // Space to operate on (empty = current)
	WrapAround bool   // Enable wrap-around navigation
}

// DefaultOptions returns sensible default options
func DefaultOptions() Options {
	return Options{
		WrapAround: true,
	}
}

// MoveFocus moves focus to an adjacent cell in the given direction.
// Returns the new focused cell ID.
func MoveFocus(
	ctx context.Context,
	c *client.Client,
	cfg *config.Config,
	runtimeState *state.RuntimeState,
	direction types.Direction,
	opts Options,
) (string, error) {
	// Refresh state to handle window changes (reconcile stale windows)
	if _, err := layout.RefreshSpaceState(ctx, c, cfg, runtimeState, opts.SpaceID); err != nil {
		// Log warning but continue - don't fail the focus operation
		fmt.Printf("Warning: state refresh failed: %v\n", err)
	}

	// Get server state for current space
	serverState, err := c.Dump(ctx)
	if err != nil {
		return "", fmt.Errorf("failed to get server state: %w", err)
	}

	spaceID := opts.SpaceID
	if spaceID == "" {
		spaceID = getCurrentSpaceID(serverState)
	}

	// Get space state
	spaceState := runtimeState.GetSpaceReadOnly(spaceID)
	if spaceState == nil {
		return "", fmt.Errorf("no layout applied to space %s", spaceID)
	}

	if spaceState.CurrentLayoutID == "" {
		return "", fmt.Errorf("no layout applied to space %s", spaceID)
	}

	// Get current layout
	layoutDef, err := cfg.GetLayout(spaceState.CurrentLayoutID)
	if err != nil {
		return "", fmt.Errorf("layout not found: %w", err)
	}

	// Get display bounds and calculate cell bounds
	displayBounds, err := getDisplayBoundsForSpace(serverState, spaceID)
	if err != nil {
		return "", fmt.Errorf("failed to get display bounds: %w", err)
	}

	calculatedLayout := layout.CalculateLayout(layoutDef, displayBounds, 8) // Default gap

	// Determine current cell
	currentCell := spaceState.FocusedCell
	if currentCell == "" {
		// No focused cell, pick first cell
		if len(layoutDef.Cells) > 0 {
			currentCell = layoutDef.Cells[0].ID
		} else {
			return "", fmt.Errorf("layout has no cells")
		}
	}

	// Find target cell
	targetCell, found := FindTargetCell(currentCell, direction, calculatedLayout.CellBounds, opts.WrapAround)
	if !found {
		return currentCell, fmt.Errorf("no cell in direction %s", direction.String())
	}

	// Focus the target cell
	return FocusCell(ctx, c, cfg, runtimeState, spaceID, targetCell)
}

// FocusCell focuses a specific cell by ID.
// Returns the focused cell ID.
func FocusCell(
	ctx context.Context,
	c *client.Client,
	cfg *config.Config,
	runtimeState *state.RuntimeState,
	spaceID string,
	cellID string,
) (string, error) {
	// Refresh state to handle window changes (reconcile stale windows)
	if _, err := layout.RefreshSpaceState(ctx, c, cfg, runtimeState, spaceID); err != nil {
		fmt.Printf("Warning: state refresh failed: %v\n", err)
	}

	// Get space state (create if needed)
	spaceState := runtimeState.GetSpace(spaceID)

	// Get cell state
	cellState, ok := spaceState.Cells[cellID]
	if !ok || len(cellState.Windows) == 0 {
		// Cell exists in layout but has no windows - just update focus state
		spaceState.SetFocus(cellID, 0)
		runtimeState.MarkUpdated()
		if err := runtimeState.Save(); err != nil {
			return cellID, fmt.Errorf("failed to save state: %w", err)
		}
		return cellID, nil
	}

	// Focus first window in cell
	windowID := cellState.Windows[0]
	if err := focusWindow(ctx, c, windowID); err != nil {
		// Even if server focus fails, update state
		spaceState.SetFocus(cellID, 0)
		runtimeState.MarkUpdated()
		runtimeState.Save()
		return cellID, fmt.Errorf("failed to focus window: %w", err)
	}

	// Update state
	spaceState.SetFocus(cellID, 0)
	runtimeState.MarkUpdated()
	if err := runtimeState.Save(); err != nil {
		return cellID, fmt.Errorf("failed to save state: %w", err)
	}

	return cellID, nil
}

// CycleFocusInCell cycles focus to the next/previous window within the current cell.
// Returns the new focused window ID.
func CycleFocusInCell(
	ctx context.Context,
	c *client.Client,
	cfg *config.Config,
	runtimeState *state.RuntimeState,
	spaceID string,
	forward bool,
) (uint32, error) {
	// Refresh state to handle window changes (reconcile stale windows)
	if _, err := layout.RefreshSpaceState(ctx, c, cfg, runtimeState, spaceID); err != nil {
		fmt.Printf("Warning: state refresh failed: %v\n", err)
	}

	// Get server state for current space if spaceID not provided
	if spaceID == "" {
		serverState, err := c.Dump(ctx)
		if err != nil {
			return 0, fmt.Errorf("failed to get server state: %w", err)
		}
		spaceID = getCurrentSpaceID(serverState)
	}

	// Get space state
	spaceState := runtimeState.GetSpaceReadOnly(spaceID)
	if spaceState == nil {
		return 0, fmt.Errorf("no layout applied to space %s", spaceID)
	}

	currentCell := spaceState.FocusedCell
	if currentCell == "" {
		// Auto-focus first cell with windows
		for cellID, cellState := range spaceState.Cells {
			if len(cellState.Windows) > 0 {
				currentCell = cellID
				// Update state with new focus
				mutableSpace := runtimeState.GetSpace(spaceID)
				mutableSpace.SetFocus(cellID, 0)
				runtimeState.MarkUpdated()
				runtimeState.Save()
				break
			}
		}
		if currentCell == "" {
			return 0, fmt.Errorf("no cells with windows")
		}
	}

	// Get cell state
	cellState, ok := spaceState.Cells[currentCell]
	if !ok || len(cellState.Windows) == 0 {
		return 0, fmt.Errorf("focused cell has no windows")
	}

	// Only one window, nothing to cycle
	if len(cellState.Windows) == 1 {
		return cellState.Windows[0], nil
	}

	// Calculate next window index
	currentIndex := spaceState.FocusedWindow
	if currentIndex < 0 || currentIndex >= len(cellState.Windows) {
		currentIndex = 0
	}

	var newWindowID uint32
	var newIndex int
	if forward {
		newWindowID, newIndex = NextWindowInCell(cellState.Windows, currentIndex)
	} else {
		newWindowID, newIndex = PrevWindowInCell(cellState.Windows, currentIndex)
	}

	// Focus the window
	if err := focusWindow(ctx, c, newWindowID); err != nil {
		return 0, fmt.Errorf("failed to focus window: %w", err)
	}

	// Update state (need mutable reference)
	mutableSpace := runtimeState.GetSpace(spaceID)
	mutableSpace.SetFocus(currentCell, newIndex)
	runtimeState.MarkUpdated()
	if err := runtimeState.Save(); err != nil {
		return newWindowID, fmt.Errorf("failed to save state: %w", err)
	}

	return newWindowID, nil
}

// focusWindow requests the server to focus a window.
// Tries window.focus first, falls back to window.raise.
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
		return fmt.Errorf("focus/raise failed: %w", err)
	}

	return nil
}

// Helper functions (duplicated from layout/apply.go for package independence)

// getCurrentSpaceID extracts the current space ID from server state.
func getCurrentSpaceID(serverState map[string]interface{}) string {
	if metadata, ok := serverState["metadata"].(map[string]interface{}); ok {
		if activeSpace, ok := metadata["activeSpace"]; ok {
			return fmt.Sprintf("%v", activeSpace)
		}
	}
	return "1"
}

// getDisplayBoundsForSpace finds the display for a space and returns its visible frame.
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

		// Get visible frame (excludes menu bar and dock)
		if rect, ok := parseFrame(display["visibleFrame"]); ok {
			return rect, nil
		}

		// Fallback to regular frame
		if rect, ok := parseFrame(display["frame"]); ok {
			return rect, nil
		}
	}

	return types.Rect{}, fmt.Errorf("no display found for space %s", spaceID)
}

// parseFrame handles both object format {x,y,width,height} and array format [[x,y],[w,h]]
func parseFrame(frame interface{}) (types.Rect, bool) {
	if frame == nil {
		return types.Rect{}, false
	}

	// Try object format: {x, y, width, height}
	if obj, ok := frame.(map[string]interface{}); ok {
		return types.Rect{
			X:      toFloat64(obj["x"]),
			Y:      toFloat64(obj["y"]),
			Width:  toFloat64(obj["width"]),
			Height: toFloat64(obj["height"]),
		}, true
	}

	// Try array format: [[x, y], [width, height]]
	if arr, ok := frame.([]interface{}); ok && len(arr) == 2 {
		origin, okOrigin := arr[0].([]interface{})
		size, okSize := arr[1].([]interface{})

		if okOrigin && okSize && len(origin) >= 2 && len(size) >= 2 {
			return types.Rect{
				X:      toFloat64(origin[0]),
				Y:      toFloat64(origin[1]),
				Width:  toFloat64(size[0]),
				Height: toFloat64(size[1]),
			}, true
		}
	}

	return types.Rect{}, false
}

func toFloat64(v interface{}) float64 {
	switch n := v.(type) {
	case float64:
		return n
	case float32:
		return float64(n)
	case int:
		return float64(n)
	case int64:
		return float64(n)
	case int32:
		return float64(n)
	default:
		return 0
	}
}
