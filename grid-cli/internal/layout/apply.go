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
	Strategy              types.AssignmentStrategy // Window assignment strategy
	BaseSpacing           float64                  // Base unit for "Nx" padding syntax
	SettingsPadding       *types.Padding           // Global default padding from settings
	SettingsWindowSpacing *types.PaddingValue      // Global default window spacing from settings
	SendBorders           bool                     // Whether to send border config/assignments
}

// DefaultApplyOptions returns sensible default options
func DefaultApplyOptions() ApplyLayoutOptions {
	return ApplyLayoutOptions{
		Strategy:    types.AssignPosition,
		BaseSpacing: 8,    // Default base spacing unit
		SendBorders: true, // Send border config by default
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

	logging.Info().Str("layout", layoutID).Str("space", snap.SpaceID).Msg("applying layout")

	// 2. Get existing track ratios if reapplying same layout
	var columnRatios, rowRatios []float64
	existingState := rs.GetSpaceReadOnly(snap.SpaceID)
	if existingState != nil && existingState.CurrentLayoutID == layoutID {
		// Preserve existing track ratios when reapplying same layout
		columnRatios = existingState.ColumnRatios
		rowRatios = existingState.RowRatios
	}

	// 3. Calculate grid layout using snapshot's display bounds (gap=0, padding handles spacing)
	calculatedLayout := CalculateLayoutWithRatios(layout, snap.DisplayBounds, 0, columnRatios, rowRatios)

	// 4. Filter and convert windows (exclude transient windows)
	exclusions := cfg.GetWindowExclusions()
	tileableWindows := snap.FilterTileable(exclusions)
	windows := convertWindows(tileableWindows)

	// DEBUG: Log tileable window IDs
	var tileableIDs []uint32
	for _, w := range tileableWindows {
		tileableIDs = append(tileableIDs, w.ID)
	}
	logging.Debug().Interface("tileableWindowIDs", tileableIDs).Int("count", len(tileableIDs)).Msg("filtered tileable windows")

	// 4. Get previous assignments from local state
	spaceState := rs.GetSpace(snap.SpaceID)
	previousAssignments := make(map[string][]uint32)
	for cellID, cellState := range spaceState.Cells {
		previousAssignments[cellID] = cellState.Windows
	}

	// DEBUG: Log previous assignments from state (may contain ghost windows)
	logging.Debug().Interface("previousAssignments", previousAssignments).Msg("loaded previous assignments from state")

	// 5. Assign windows to cells
	assignment := AssignWindows(
		windows,
		layout,
		calculatedLayout.CellBounds,
		cfg.AppRules,
		previousAssignments,
		opts.Strategy,
	)

	// DEBUG: Log new assignments (should only contain existing windows)
	logging.Debug().Interface("newAssignments", assignment.Assignments).Msg("computed new assignments")

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

	// 6b. Adjust ratios to match actual assignment counts
	// This handles cases where windows disappeared between state save and now
	for cellID, windowIDs := range assignment.Assignments {
		if existingRatios, ok := cellRatios[cellID]; ok {
			if len(existingRatios) != len(windowIDs) {
				logging.Debug().
					Str("cell", cellID).
					Int("ratioCount", len(existingRatios)).
					Int("windowCount", len(windowIDs)).
					Interface("oldRatios", existingRatios).
					Msg("MISMATCH: adjusting ratios for window count change")
				cellRatios[cellID] = AdjustRatiosForWindowCount(existingRatios, len(windowIDs))
				logging.Debug().
					Str("cell", cellID).
					Interface("newRatios", cellRatios[cellID]).
					Msg("adjusted ratios")
			}
		}
	}

	// 7. Calculate window placements
	placements := CalculateAllWindowPlacements(
		calculatedLayout,
		layout,
		assignment.Assignments,
		cellModes,
		cellRatios,
		cfg.Settings.DefaultStackMode,
		opts.BaseSpacing,
		opts.SettingsPadding,
		opts.SettingsWindowSpacing,
	)

	// DEBUG: Log final placements
	for _, p := range placements {
		logging.Debug().
			Uint32("windowID", p.WindowID).
			Float64("x", p.Bounds.X).
			Float64("y", p.Bounds.Y).
			Float64("w", p.Bounds.Width).
			Float64("h", p.Bounds.Height).
			Msg("placement")
	}

	// 8. Apply placements via server
	if err := ApplyPlacements(ctx, c, placements); err != nil {
		return fmt.Errorf("failed to apply placements: %w", err)
	}

	// 8b. Send border config and cell assignments to server
	if opts.SendBorders {
		if err := sendBorderConfig(ctx, c, cfg); err != nil {
			// Log but don't fail - borders are optional
			logging.Warn().Err(err).Msg("failed to send border config")
		}

		if err := sendCellAssignments(ctx, c, layout, assignment.Assignments); err != nil {
			// Log but don't fail - borders are optional
			logging.Warn().Err(err).Msg("failed to send cell assignments")
		}
	}

	// 9. Update local state
	// Only call SetCurrentLayout (which clears ratios) if switching to a different layout
	if existingState == nil || existingState.CurrentLayoutID != layoutID {
		spaceState.SetCurrentLayout(layoutID, findLayoutIndex(cfg, layoutID))
	} else {
		// Same layout - preserve track ratios, just update other fields
		spaceState.CurrentLayoutID = layoutID
		spaceState.LayoutIndex = findLayoutIndex(cfg, layoutID)
	}
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
			ID:                  w.ID,
			Title:               w.Title,
			AppName:             w.AppName,
			BundleID:            w.BundleID,
			Frame:               w.Frame,
			IsMinimized:         w.IsMinimized,
			IsHidden:            w.IsHidden,
			Level:               w.Level,
			Role:                w.Role,
			Subrole:             w.Subrole,
			HasCloseButton:      w.HasCloseButton,
			HasFullscreenButton: w.HasFullscreenButton,
			HasMinimizeButton:   w.HasMinimizeButton,
			HasZoomButton:       w.HasZoomButton,
			IsModal:             w.IsModal,
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

// sendBorderConfig sends the border configuration to the server.
func sendBorderConfig(ctx context.Context, c *client.Client, cfg *config.Config) error {
	if cfg.Borders == nil || !cfg.Borders.GetEnabled() {
		return nil // Borders not configured or disabled
	}

	logging.Debug().Msg("sending border config to server")
	return c.SendBorderConfig(ctx, cfg.Borders)
}

// sendCellAssignments sends window-to-cell mappings to the server for border coloring.
func sendCellAssignments(ctx context.Context, c *client.Client, layout *types.Layout, assignments map[string][]uint32) error {
	// Build cell assignments list
	var cellAssignments []client.CellAssignment
	for cellID, windowIDs := range assignments {
		for _, windowID := range windowIDs {
			cellAssignments = append(cellAssignments, client.CellAssignment{
				WindowID: windowID,
				CellID:   cellID,
			})
		}
	}

	if len(cellAssignments) == 0 {
		return nil // No assignments to send
	}

	// Build cell overrides from layout cells that have border config
	overrides := make(map[string]client.CellOverride)
	for _, cell := range layout.Cells {
		if cell.Border != nil {
			override := client.CellOverride{}
			if cell.Border.ActiveCellColor != nil {
				override.ActiveCellColor = *cell.Border.ActiveCellColor
			}
			if cell.Border.InactiveColor != nil {
				override.InactiveColor = *cell.Border.InactiveColor
			}
			if cell.Border.Style != nil {
				override.Style = *cell.Border.Style
			}
			// Only add if at least one field is set
			if override.ActiveCellColor != "" || override.InactiveColor != "" || override.Style != "" {
				overrides[cell.ID] = override
			}
		}
	}

	logging.Debug().
		Int("assignmentCount", len(cellAssignments)).
		Int("overrideCount", len(overrides)).
		Msg("sending cell assignments to server")

	// TODO: Phase 1.2 - pass actual cellBounds from CalculatedLayout
	return c.SendCellAssignments(ctx, cellAssignments, overrides, nil)
}
