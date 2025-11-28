package layout

import (
	"context"
	"fmt"

	"github.com/yourusername/grid-cli/internal/client"
	"github.com/yourusername/grid-cli/internal/config"
	"github.com/yourusername/grid-cli/internal/logging"
	"github.com/yourusername/grid-cli/internal/server"
	"github.com/yourusername/grid-cli/internal/state"
	"github.com/yourusername/grid-cli/internal/types"
)

// ApplyLayoutOptions configures layout application
type ApplyLayoutOptions struct {
	Strategy types.AssignmentStrategy // Window assignment strategy
	Gap      float64                  // Gap between cells in pixels
	Padding  float64                  // Padding between windows in same cell
}

// DefaultApplyOptions returns sensible default options
func DefaultApplyOptions() ApplyLayoutOptions {
	return ApplyLayoutOptions{
		Strategy: types.AssignPosition,
		Gap:      8,
		Padding:  4,
	}
}

// ApplyLayout is the main orchestration function for applying a layout.
// It coordinates config, layout calculations, state, and server communication.
//
// snap: Pre-fetched server snapshot (for display bounds and window list)
// rs: Local state (already reconciled)
func ApplyLayout(
	ctx context.Context,
	c *client.Client,
	snap *server.Snapshot,
	cfg *config.Config,
	rs *state.RuntimeState,
	layoutID string,
	opts ApplyLayoutOptions,
) error {
	// 1. Get layout from config
	layout, err := cfg.GetLayout(layoutID)
	if err != nil {
		return fmt.Errorf("layout not found: %w", err)
	}

	logging.Log("ApplyLayout: %s on space %s", layoutID, snap.SpaceID)

	// 2. Calculate grid layout using snapshot's display bounds
	calculatedLayout := CalculateLayout(layout, snap.DisplayBounds, opts.Gap)

	// 3. Convert snapshot windows to layout windows
	windows := convertWindows(snap.Windows)

	// 4. Get previous assignments from local state
	spaceState := rs.GetSpace(snap.SpaceID)
	previousAssignments := make(map[string][]uint32)
	for cellID, cellState := range spaceState.Cells {
		previousAssignments[cellID] = cellState.Windows
	}

	// 5. Assign windows to cells
	assignment := AssignWindows(
		windows,
		layout,
		calculatedLayout.CellBounds,
		cfg.AppRules,
		previousAssignments,
		opts.Strategy,
	)

	// 6. Get cell modes and ratios from config/state
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

	// 7. Calculate window placements
	placements := CalculateAllWindowPlacements(
		calculatedLayout,
		assignment.Assignments,
		cellModes,
		cellRatios,
		cfg.Settings.DefaultStackMode,
		opts.Padding,
	)

	// 8. Apply placements via server
	if err := ApplyPlacements(ctx, c, placements); err != nil {
		return fmt.Errorf("failed to apply placements: %w", err)
	}

	// 9. Update local state
	spaceState.SetCurrentLayout(layoutID, findLayoutIndex(cfg, layoutID))
	rs.SetWindowAssignments(snap.SpaceID, assignment.Assignments)
	rs.MarkUpdated()

	// 10. Save state
	if err := rs.Save(); err != nil {
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

// convertWindows converts server.WindowInfo slice to layout.Window slice.
func convertWindows(windows []server.WindowInfo) []Window {
	result := make([]Window, 0, len(windows))
	for _, w := range windows {
		result = append(result, Window{
			ID:          w.ID,
			Title:       w.Title,
			AppName:     w.AppName,
			BundleID:    w.BundleID,
			Frame:       w.Frame,
			IsMinimized: w.IsMinimized,
			IsHidden:    w.IsHidden,
			Level:       w.Level,
		})
	}
	return result
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

// CycleLayout cycles to the next layout for the current space.
func CycleLayout(
	ctx context.Context,
	c *client.Client,
	snap *server.Snapshot,
	cfg *config.Config,
	rs *state.RuntimeState,
	opts ApplyLayoutOptions,
) (string, error) {
	// Get available layouts for this space
	availableLayouts := cfg.GetLayoutIDs()
	if spaceConfig := cfg.GetSpaceConfig(snap.SpaceID); spaceConfig != nil && len(spaceConfig.Layouts) > 0 {
		availableLayouts = spaceConfig.Layouts
	}

	if len(availableLayouts) == 0 {
		return "", fmt.Errorf("no layouts available")
	}

	// Cycle in state
	spaceState := rs.GetSpace(snap.SpaceID)
	newLayoutID := spaceState.CycleLayout(availableLayouts)

	// Apply the new layout
	if err := ApplyLayout(ctx, c, snap, cfg, rs, newLayoutID, opts); err != nil {
		return "", err
	}

	return newLayoutID, nil
}

// ReapplyLayout reapplies the current layout.
func ReapplyLayout(
	ctx context.Context,
	c *client.Client,
	snap *server.Snapshot,
	cfg *config.Config,
	rs *state.RuntimeState,
	opts ApplyLayoutOptions,
) error {
	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil || spaceState.CurrentLayoutID == "" {
		return fmt.Errorf("no layout currently applied")
	}

	return ApplyLayout(ctx, c, snap, cfg, rs, spaceState.CurrentLayoutID, opts)
}
