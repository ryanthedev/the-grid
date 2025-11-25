package cell

import (
	"context"
	"fmt"

	"github.com/yourusername/grid-cli/internal/client"
	"github.com/yourusername/grid-cli/internal/config"
	"github.com/yourusername/grid-cli/internal/focus"
	"github.com/yourusername/grid-cli/internal/layout"
	"github.com/yourusername/grid-cli/internal/state"
	"github.com/yourusername/grid-cli/internal/types"
)

// SendOptions configures send operations
type SendOptions struct {
	SpaceID string // Space to operate on (empty = current)
}

// DefaultSendOptions returns sensible default options
func DefaultSendOptions() SendOptions {
	return SendOptions{}
}

// SendResult contains the result of a send operation
type SendResult struct {
	SourceCell string // Cell the window was moved from
	TargetCell string // Cell the window was moved to
	WindowID   uint32 // Window that was moved
	Moved      bool   // Whether the window was actually moved
	Message    string // Informational message
}

// SendWindow moves the focused window to an adjacent cell in the given direction.
// Returns a SendResult indicating what happened.
func SendWindow(
	ctx context.Context,
	c *client.Client,
	cfg *config.Config,
	runtimeState *state.RuntimeState,
	direction types.Direction,
	opts SendOptions,
) (*SendResult, error) {
	// 1. Get server state
	serverState, err := c.Dump(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get server state: %w", err)
	}

	// 2. Determine which space to use
	spaceID := opts.SpaceID
	if spaceID == "" {
		spaceID = getCurrentSpaceID(serverState)
	}

	// 3. Get space state
	spaceState := runtimeState.GetSpaceReadOnly(spaceID)
	if spaceState == nil {
		return nil, fmt.Errorf("no layout applied to space %s", spaceID)
	}

	if spaceState.CurrentLayoutID == "" {
		return nil, fmt.Errorf("no layout applied to space %s", spaceID)
	}

	// 4. Get focused window ID
	focusedWindowID := spaceState.GetFocusedWindow()
	if focusedWindowID == 0 {
		// Try to get from server's focused window
		focusedWindowID = getFocusedWindowFromServer(serverState)
		if focusedWindowID == 0 {
			return nil, fmt.Errorf("no focused window")
		}
	}

	// 5. Find current cell containing the focused window
	sourceCell := spaceState.GetWindowCell(focusedWindowID)
	if sourceCell == "" {
		return nil, fmt.Errorf("focused window is not in any cell")
	}

	// 6. Get layout and calculate cell bounds
	layoutDef, err := cfg.GetLayout(spaceState.CurrentLayoutID)
	if err != nil {
		return nil, fmt.Errorf("layout not found: %w", err)
	}

	displayBounds, err := getDisplayBoundsForSpace(serverState, spaceID)
	if err != nil {
		return nil, fmt.Errorf("failed to get display bounds: %w", err)
	}

	calculatedLayout := layout.CalculateLayout(layoutDef, displayBounds, 8) // Default gap

	// 7. Find target cell using focus navigation logic (no wrap)
	targetCell, found := focus.FindTargetCell(sourceCell, direction, calculatedLayout.CellBounds, false)
	if !found {
		return &SendResult{
			SourceCell: sourceCell,
			WindowID:   focusedWindowID,
			Moved:      false,
			Message:    fmt.Sprintf("No cell %s", direction.String()),
		}, nil
	}

	// 8. Move window: remove from source, prepend to target
	mutableSpaceState := runtimeState.GetSpace(spaceID)
	mutableSpaceState.PrependWindowToCell(focusedWindowID, targetCell)

	// 9. Get cell modes and ratios for recalculating placements
	cellModes := make(map[string]types.StackMode)
	cellRatios := make(map[string][]float64)

	// Build affected cells map
	affectedCells := make(map[string][]uint32)

	// Source cell
	if sourceCellState, ok := mutableSpaceState.Cells[sourceCell]; ok {
		affectedCells[sourceCell] = sourceCellState.Windows
		if sourceCellState.StackMode != "" {
			cellModes[sourceCell] = sourceCellState.StackMode
		}
		if len(sourceCellState.SplitRatios) > 0 {
			cellRatios[sourceCell] = sourceCellState.SplitRatios
		}
	}

	// Target cell
	if targetCellState, ok := mutableSpaceState.Cells[targetCell]; ok {
		affectedCells[targetCell] = targetCellState.Windows
		if targetCellState.StackMode != "" {
			cellModes[targetCell] = targetCellState.StackMode
		}
		if len(targetCellState.SplitRatios) > 0 {
			cellRatios[targetCell] = targetCellState.SplitRatios
		}
	}

	// Check layout cell modes
	for cellID := range affectedCells {
		for _, cell := range layoutDef.Cells {
			if cell.ID == cellID && cell.StackMode != "" {
				if _, exists := cellModes[cellID]; !exists {
					cellModes[cellID] = cell.StackMode
				}
				break
			}
		}
		if layoutDef.CellModes != nil {
			if mode, ok := layoutDef.CellModes[cellID]; ok {
				if _, exists := cellModes[cellID]; !exists {
					cellModes[cellID] = mode
				}
			}
		}
	}

	// 10. Calculate window placements for affected cells
	placements := layout.CalculateAllWindowPlacements(
		calculatedLayout,
		affectedCells,
		cellModes,
		cellRatios,
		cfg.Settings.DefaultStackMode,
		4, // Default padding
	)

	// 11. Apply placements via server
	if err := layout.ApplyPlacements(ctx, c, placements); err != nil {
		return nil, fmt.Errorf("failed to apply placements: %w", err)
	}

	// 12. Update focus state to target cell (window is at index 0 since we prepended)
	mutableSpaceState.SetFocus(targetCell, 0)

	// 13. Focus the window on the server
	_, _ = c.CallMethod(ctx, "window.focus", map[string]interface{}{
		"windowId": focusedWindowID,
	})

	// 14. Save runtime state
	runtimeState.MarkUpdated()
	if err := runtimeState.Save(); err != nil {
		return nil, fmt.Errorf("failed to save state: %w", err)
	}

	return &SendResult{
		SourceCell: sourceCell,
		TargetCell: targetCell,
		WindowID:   focusedWindowID,
		Moved:      true,
	}, nil
}

// Helper functions

// getCurrentSpaceID extracts the current space ID from server state.
func getCurrentSpaceID(serverState map[string]interface{}) string {
	if metadata, ok := serverState["metadata"].(map[string]interface{}); ok {
		if activeSpace, ok := metadata["activeSpace"]; ok {
			return fmt.Sprintf("%v", activeSpace)
		}
	}
	return "1"
}

// getFocusedWindowFromServer extracts the focused window ID from server state.
func getFocusedWindowFromServer(serverState map[string]interface{}) uint32 {
	if metadata, ok := serverState["metadata"].(map[string]interface{}); ok {
		if focusedWindow, ok := metadata["focusedWindow"]; ok {
			return uint32(toFloat64(focusedWindow))
		}
	}
	return 0
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
