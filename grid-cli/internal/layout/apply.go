package layout

import (
	"context"
	"fmt"

	"github.com/yourusername/grid-cli/internal/client"
	"github.com/yourusername/grid-cli/internal/config"
	"github.com/yourusername/grid-cli/internal/logging"
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

// DefaultApplyOptions returns sensible default options
func DefaultApplyOptions() ApplyLayoutOptions {
	return ApplyLayoutOptions{
		Strategy: types.AssignAutoFlow,
		Gap:      8,
		Padding:  4,
	}
}

// ApplyLayout is the main orchestration function for applying a layout.
// It coordinates config, layout calculations, state, and server communication.
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

	// 2.5 Log context
	logging.Log("ApplyLayout: %s", layoutID)
	logContextChange(runtimeState, serverState)

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

	// 9. Get cell modes and ratios from config/state
	cellModes := make(map[string]types.StackMode)
	cellRatios := make(map[string][]float64)

	for cellID := range assignment.Assignments {
		// Check individual cell's StackMode first
		for _, cell := range layout.Cells {
			if cell.ID == cellID && cell.StackMode != "" {
				cellModes[cellID] = cell.StackMode
				break
			}
		}
		// CellModes map can override individual cell settings
		if layout.CellModes != nil {
			if mode, ok := layout.CellModes[cellID]; ok {
				cellModes[cellID] = mode
			}
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

// ApplyPlacements sends window placements to the server.
// Continues on individual errors to apply as many windows as possible.
func ApplyPlacements(ctx context.Context, c *client.Client, placements []types.WindowPlacement) error {
	successCount := 0
	errorCount := 0

	for _, p := range placements {
		updates := map[string]interface{}{
			"x":      p.Bounds.X,
			"y":      p.Bounds.Y,
			"width":  p.Bounds.Width,
			"height": p.Bounds.Height,
		}

		_, err := c.UpdateWindow(ctx, int(p.WindowID), updates)
		if err != nil {
			// Log warning but continue with other windows
			fmt.Printf("Warning: failed to update window %d: %v\n", p.WindowID, err)
			errorCount++
		} else {
			successCount++
		}
	}

	// Only fail if NO windows could be updated
	if successCount == 0 && errorCount > 0 {
		return fmt.Errorf("failed to update all %d windows", errorCount)
	}

	return nil
}

// CycleLayout applies the next layout in the cycle for a space.
// Returns the new layout ID.
func CycleLayout(
	ctx context.Context,
	c *client.Client,
	cfg *config.Config,
	runtimeState *state.RuntimeState,
	spaceID string,
	opts ApplyLayoutOptions,
) (string, error) {
	// Determine space ID if not provided
	if spaceID == "" {
		serverState, err := c.Dump(ctx)
		if err != nil {
			return "", fmt.Errorf("failed to get server state: %w", err)
		}
		spaceID = getCurrentSpaceID(serverState)
	}

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

	// Apply the new layout with preserve strategy
	opts.SpaceID = spaceID
	opts.Strategy = types.AssignPreserve
	if err := ApplyLayout(ctx, c, cfg, runtimeState, newLayoutID, opts); err != nil {
		return "", err
	}

	return newLayoutID, nil
}

// PreviousLayout applies the previous layout in the cycle for a space.
// Returns the new layout ID.
func PreviousLayout(
	ctx context.Context,
	c *client.Client,
	cfg *config.Config,
	runtimeState *state.RuntimeState,
	spaceID string,
	opts ApplyLayoutOptions,
) (string, error) {
	// Determine space ID if not provided
	if spaceID == "" {
		serverState, err := c.Dump(ctx)
		if err != nil {
			return "", fmt.Errorf("failed to get server state: %w", err)
		}
		spaceID = getCurrentSpaceID(serverState)
	}

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

	// Cycle to previous layout
	spaceState := runtimeState.GetSpace(spaceID)
	newLayoutID := spaceState.PreviousLayout(availableLayouts)

	// Apply the new layout with preserve strategy
	opts.SpaceID = spaceID
	opts.Strategy = types.AssignPreserve
	if err := ApplyLayout(ctx, c, cfg, runtimeState, newLayoutID, opts); err != nil {
		return "", err
	}

	return newLayoutID, nil
}

// Helper functions

// getCurrentSpaceID extracts the current space ID from server state.
func getCurrentSpaceID(serverState map[string]interface{}) string {
	// Try metadata.activeSpace first
	if metadata, ok := serverState["metadata"].(map[string]interface{}); ok {
		if activeSpace, ok := metadata["activeSpace"]; ok {
			return fmt.Sprintf("%v", activeSpace)
		}
	}
	// Fallback to "1" (first space)
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

// filterWindowsForSpace extracts windows that belong to a specific space.
func filterWindowsForSpace(serverState map[string]interface{}, spaceID string) []Window {
	var windows []Window

	rawWindows, ok := serverState["windows"].(map[string]interface{})
	if !ok {
		// Try as array
		if rawArr, ok := serverState["windows"].([]interface{}); ok {
			for _, w := range rawArr {
				if win := parseWindow(w, spaceID); win != nil {
					windows = append(windows, *win)
				}
			}
		}
		return windows
	}

	for _, w := range rawWindows {
		if win := parseWindow(w, spaceID); win != nil {
			windows = append(windows, *win)
		}
	}

	return windows
}

// parseWindow parses a window from server state and checks if it's on the given space.
func parseWindow(w interface{}, spaceID string) *Window {
	win, ok := w.(map[string]interface{})
	if !ok {
		return nil
	}

	// Skip windows with no app name (system UI elements like "borders")
	appName := toString(win["appName"])
	if appName == "" {
		return nil
	}

	// Check if window is on this space
	spaces, ok := win["spaces"].([]interface{})
	if ok {
		onSpace := false
		for _, s := range spaces {
			if fmt.Sprintf("%v", s) == spaceID {
				onSpace = true
				break
			}
		}
		if !onSpace {
			return nil
		}
	}

	// Build Window struct
	window := Window{
		ID:          uint32(toFloat64(win["id"])),
		Title:       toString(win["title"]),
		AppName:     appName,
		BundleID:    toString(win["bundleId"]),
		IsMinimized: toBool(win["isMinimized"]),
		IsHidden:    toBool(win["isHidden"]),
		Level:       int(toFloat64(win["level"])),

		// AX properties for floating/popup detection
		Role:              toString(win["role"]),
		Subrole:           toString(win["subrole"]),
		HasCloseButton:    toBool(win["hasCloseButton"]),
		HasFullscreenButton: toBool(win["hasFullscreenButton"]),
		HasMinimizeButton: toBool(win["hasMinimizeButton"]),
		HasZoomButton:     toBool(win["hasZoomButton"]),
		IsModal:           toBool(win["isModal"]),
	}

	// Parse frame (handles both object and array format)
	if rect, ok := parseFrame(win["frame"]); ok {
		window.Frame = rect
	}

	return &window
}

// findLayoutIndex returns the index of a layout in the config.
func findLayoutIndex(cfg *config.Config, layoutID string) int {
	for i, l := range cfg.Layouts {
		if l.ID == layoutID {
			return i
		}
	}
	return 0
}

// Type conversion helpers

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
