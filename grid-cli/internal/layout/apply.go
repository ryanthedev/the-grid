package layout

import (
	"context"
	"fmt"

	"github.com/ryanthedev/grid-cli/internal/client"
	"github.com/ryanthedev/grid-cli/internal/config"
	"github.com/ryanthedev/grid-cli/internal/jsonlog"
	"github.com/ryanthedev/grid-cli/internal/server"
	"github.com/ryanthedev/grid-cli/internal/state"
	"github.com/ryanthedev/grid-cli/internal/types"
)

// ApplyLayoutOptions configures layout application
type ApplyLayoutOptions struct {
	Strategy              types.AssignmentStrategy // Window assignment strategy
	BaseSpacing           float64                  // Base unit for "Nx" padding syntax
	SettingsPadding       *types.Padding           // Global default padding from settings
	SettingsWindowSpacing *types.PaddingValue      // Global default window spacing from settings
	SendBorders           bool                     // Whether to send border config/assignments
	DisplayFilter         string                   // If non-empty, only refresh this display UUID
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

	jsonlog.Log("layout.apply.start", jsonlog.WithData(map[string]any{"lid": layoutID, "sid": snap.SpaceID}))

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

	// 6b. Adjust ratios to match actual assignment counts
	// This handles cases where windows disappeared between state save and now
	for cellID, windowIDs := range assignment.Assignments {
		if existingRatios, ok := cellRatios[cellID]; ok {
			if len(existingRatios) != len(windowIDs) {
				cellRatios[cellID] = AdjustRatiosForWindowCount(existingRatios, len(windowIDs))
			}
		}
	}

	// 7. Build focused indices for tab stack position indicators
	focusedIndices := make(map[string]int)
	for cellID, cellState := range spaceState.Cells {
		focusedIndices[cellID] = cellState.LastFocusedIdx
	}

	// 7b. Resolve tab indicator inset
	tabIndicatorInset := opts.BaseSpacing
	if insetVal := cfg.GetTabIndicatorInset(); insetVal != nil {
		tabIndicatorInset = insetVal.Resolve(opts.BaseSpacing)
	}

	// 8. Calculate window placements
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
		focusedIndices,
		tabIndicatorInset,
	)

	// 8b. Apply per-display offset if configured
	displayUUID := snap.GetCurrentDisplayUUID()
	displayName := snap.GetCurrentDisplayName()
	offset := cfg.GetDisplayOffset(displayUUID, displayName)

	// Log display diagnostics
	jsonlog.Log("pos.display", jsonlog.WithData(map[string]any{
		"uuid": displayUUID,
		"name": displayName,
		"bounds": map[string]float64{
			"x": snap.DisplayBounds.X, "y": snap.DisplayBounds.Y,
			"w": snap.DisplayBounds.Width, "h": snap.DisplayBounds.Height,
		},
		"offset": map[string]float64{"x": offset.X, "y": offset.Y},
	}))

	if offset.X != 0 || offset.Y != 0 {
		for i := range placements {
			placements[i].Bounds.X += offset.X
			placements[i].Bounds.Y += offset.Y
		}
	}

	// Log focused window placement only
	if snap.FocusedWindowID != 0 {
		for _, p := range placements {
			if p.WindowID == snap.FocusedWindowID {
				jsonlog.Log("pos.apply", jsonlog.WithData(map[string]any{
					"wid": p.WindowID,
					"bounds": map[string]float64{
						"x": p.Bounds.X, "y": p.Bounds.Y,
						"w": p.Bounds.Width, "h": p.Bounds.Height,
					},
				}))
				break
			}
		}
	}

	// 9. Apply placements via server
	if err := ApplyPlacements(ctx, c, placements); err != nil {
		return fmt.Errorf("failed to apply placements: %w", err)
	}

	// Log layout application event
	cellIDs := make([]string, 0, len(layout.Cells))
	for _, cell := range layout.Cells {
		cellIDs = append(cellIDs, cell.ID)
	}
	jsonlog.Log("layout.apply", jsonlog.WithData(map[string]any{
		"name":  layoutID,
		"cells": cellIDs,
	}))

	// 9b. Send border config and cell assignments to server
	if opts.SendBorders {
		if err := sendBorderConfig(ctx, c, cfg); err != nil {
			// Log but don't fail - borders are optional
			jsonlog.Log("warn.border_config", jsonlog.WithData(map[string]any{"err": err.Error()}))
		}

		if displayUUID == "" {
			jsonlog.Log("warn.display_uuid", jsonlog.WithMsg("could not determine display UUID"))
		} else if err := sendCellAssignments(ctx, c, displayUUID, layout, assignment.Assignments, calculatedLayout.CellBounds, opts.BaseSpacing, opts.SettingsPadding); err != nil {
			// Log but don't fail - borders are optional
			jsonlog.Log("warn.cell_assignments", jsonlog.WithData(map[string]any{"err": err.Error()}))
		}
	}

	// 10. Update local state
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

	// 11. Save state
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

// ApplyCellLayout applies layout changes to a single cell's windows only.
// More efficient than ReapplyLayout when only one cell needs updating.
// Does not save state - caller is responsible for state management.
func ApplyCellLayout(
	ctx context.Context,
	c *client.Client,
	snap *server.Snapshot,
	cfg *config.Config,
	rs *state.RuntimeState,
	cellID string,
	opts ApplyLayoutOptions,
) error {
	jsonlog.Log("layout.cell.start", jsonlog.WithData(map[string]any{"cellID": cellID, "spaceID": snap.SpaceID}))

	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil || spaceState.CurrentLayoutID == "" {
		return fmt.Errorf("no layout currently applied")
	}

	// 1. Get layout definition
	layout, err := cfg.GetLayout(spaceState.CurrentLayoutID)
	if err != nil {
		return fmt.Errorf("layout not found: %w", err)
	}

	// 2. Calculate full layout (needed for cell bounds with track ratios)
	calculatedLayout := CalculateLayoutWithRatios(
		layout, snap.DisplayBounds, 0,
		spaceState.ColumnRatios, spaceState.RowRatios,
	)

	// 3. Get target cell's windows
	cellState, ok := spaceState.Cells[cellID]
	if !ok {
		jsonlog.Log("layout.cell.skip", jsonlog.WithData(map[string]any{"reason": "cell not found", "cellID": cellID}))
		return nil
	}
	if len(cellState.Windows) == 0 {
		jsonlog.Log("layout.cell.skip", jsonlog.WithData(map[string]any{"reason": "no windows", "cellID": cellID}))
		return nil
	}
	jsonlog.Log("layout.cell.found", jsonlog.WithData(map[string]any{
		"cellID": cellID, "windows": cellState.Windows, "mode": cellState.StackMode,
	}))

	// 4. Build single-cell assignment
	singleCellAssignment := map[string][]uint32{
		cellID: cellState.Windows,
	}

	// 5. Build cell modes map
	cellModes := make(map[string]types.StackMode)
	if cellState.StackMode != "" {
		cellModes[cellID] = cellState.StackMode
	}

	// 6. Build cell ratios map
	cellRatios := make(map[string][]float64)
	if len(cellState.SplitRatios) > 0 {
		cellRatios[cellID] = cellState.SplitRatios
	}

	// 7. Build focused indices for tab positioning
	focusedIndices := map[string]int{
		cellID: cellState.LastFocusedIdx,
	}

	// 8. Resolve tab indicator inset
	tabIndicatorInset := opts.BaseSpacing
	if insetVal := cfg.GetTabIndicatorInset(); insetVal != nil {
		tabIndicatorInset = insetVal.Resolve(opts.BaseSpacing)
	}

	// 9. Calculate placements for this cell only
	placements := CalculateAllWindowPlacements(
		calculatedLayout,
		layout,
		singleCellAssignment,
		cellModes,
		cellRatios,
		cfg.Settings.DefaultStackMode,
		opts.BaseSpacing,
		opts.SettingsPadding,
		opts.SettingsWindowSpacing,
		focusedIndices,
		tabIndicatorInset,
	)

	// 9b. Apply per-display offset if configured
	displayUUID := snap.GetCurrentDisplayUUID()
	displayName := snap.GetCurrentDisplayName()
	offset := cfg.GetDisplayOffset(displayUUID, displayName)

	// Log display diagnostics
	jsonlog.Log("pos.display", jsonlog.WithData(map[string]any{
		"uuid": displayUUID,
		"name": displayName,
		"bounds": map[string]float64{
			"x": snap.DisplayBounds.X, "y": snap.DisplayBounds.Y,
			"w": snap.DisplayBounds.Width, "h": snap.DisplayBounds.Height,
		},
		"offset": map[string]float64{"x": offset.X, "y": offset.Y},
	}))

	if offset.X != 0 || offset.Y != 0 {
		for i := range placements {
			placements[i].Bounds.X += offset.X
			placements[i].Bounds.Y += offset.Y
		}
	}

	// Log focused window placement only
	if snap.FocusedWindowID != 0 {
		for _, p := range placements {
			if p.WindowID == snap.FocusedWindowID {
				jsonlog.Log("pos.apply", jsonlog.WithData(map[string]any{
					"wid": p.WindowID,
					"bounds": map[string]float64{
						"x": p.Bounds.X, "y": p.Bounds.Y,
						"w": p.Bounds.Width, "h": p.Bounds.Height,
					},
				}))
				break
			}
		}
	}

	// 10. Apply placements
	jsonlog.Log("layout.cell.placements", jsonlog.WithData(map[string]any{
		"count": len(placements), "cellID": cellID,
	}))
	if err := ApplyPlacements(ctx, c, placements); err != nil {
		return fmt.Errorf("failed to apply placements: %w", err)
	}

	// 11. Send border updates for this cell
	if opts.SendBorders {
		if err := sendBorderConfig(ctx, c, cfg); err != nil {
			jsonlog.Log("warn.border_config", jsonlog.WithData(map[string]any{"err": err.Error()}))
		}

		if displayUUID == "" {
			jsonlog.Log("warn.display_uuid", jsonlog.WithMsg("could not determine display UUID"))
		} else if err := sendCellAssignments(ctx, c, displayUUID, layout, singleCellAssignment,
			calculatedLayout.CellBounds, opts.BaseSpacing, opts.SettingsPadding); err != nil {
			jsonlog.Log("warn.cell_assignments", jsonlog.WithData(map[string]any{"err": err.Error()}))
		}
	}

	return nil
}

// sendBorderConfig sends the border configuration to the server.
func sendBorderConfig(ctx context.Context, c *client.Client, cfg *config.Config) error {
	if cfg.Borders == nil || !cfg.Borders.GetEnabled() {
		return nil // Borders not configured or disabled
	}

	return c.SendBorderConfig(ctx, cfg.Borders)
}

// sendCellAssignments sends window-to-cell mappings to the server for border coloring.
// Cell bounds are adjusted with padding to match actual window placement areas.
// displayUUID is required for per-display caching in the server.
func sendCellAssignments(ctx context.Context, c *client.Client, displayUUID string, layout *types.Layout, assignments map[string][]uint32, cellBounds map[string]types.Rect, baseSpacing float64, settingsPadding *types.Padding) error {
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

	return c.SendCellAssignments(ctx, displayUUID, cellAssignments)
}

// reconcileSpace removes windows from state that no longer exist in the snapshot.
// This is a simplified inline version of reconcile.Sync to avoid import cycles
// (reconcile imports layout, so layout cannot import reconcile).
// Note: This does not sync focus state like the full reconcile.Sync does,
// which is acceptable here since ApplyLayout will update focus state anyway.
func reconcileSpace(snap *server.Snapshot, rs *state.RuntimeState) error {
	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil {
		return nil
	}

	changed := false
	for cellID, cell := range spaceState.Cells {
		var valid []uint32
		for _, wid := range cell.Windows {
			if snap.WindowIDs[wid] {
				valid = append(valid, wid)
			}
		}

		if len(valid) != len(cell.Windows) {
			// Windows were removed, update cell
			mutableCell := rs.GetSpace(snap.SpaceID).GetCell(cellID)
			mutableCell.Windows = valid
			mutableCell.SplitRatios = reconcileEqualRatios(len(valid))
			changed = true
		}
	}

	if changed {
		rs.MarkUpdated()
		if err := rs.Save(); err != nil {
			return err
		}
	}

	return nil
}

// reconcileEqualRatios returns equal split ratios for n windows.
func reconcileEqualRatios(n int) []float64 {
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

// DisplayError represents an error that occurred while refreshing a specific display.
type DisplayError struct {
	DisplayUUID string
	DisplayName string
	Err         error
}

func (e DisplayError) Error() string {
	return fmt.Sprintf("display %s (%s): %v", e.DisplayName, e.DisplayUUID, e.Err)
}

// RefreshAllDisplays refreshes layouts on all connected displays.
// This is the core algorithm for the "layout refresh" feature.
// It iterates through all displays, fetches a snapshot for each display's space,
// reconciles state, and applies the appropriate layout.
// Returns a slice of DisplayErrors for any displays that failed (best-effort approach).
func RefreshAllDisplays(
	ctx context.Context,
	c *client.Client,
	cfg *config.Config,
	rs *state.RuntimeState,
	opts ApplyLayoutOptions,
) []DisplayError {
	// Start span for the entire refresh operation
	span := jsonlog.StartSpan("layout.refresh_all", jsonlog.WithData(map[string]any{}))
	defer span.End()

	// Fetch initial snapshot to get all displays
	initialSnap, err := server.Fetch(ctx, c)
	if err != nil {
		return []DisplayError{{
			DisplayUUID: "",
			DisplayName: "unknown",
			Err:         fmt.Errorf("failed to fetch initial snapshot: %w", err),
		}}
	}

	jsonlog.Log("layout.refresh_all.displays", jsonlog.WithData(map[string]any{
		"count": len(initialSnap.AllDisplays),
	}))

	var errors []DisplayError
	processedCount := 0

	for _, display := range initialSnap.AllDisplays {
		// Skip if DisplayFilter is set and doesn't match this display
		if opts.DisplayFilter != "" && display.UUID != opts.DisplayFilter {
			continue
		}
		processedCount++
		// Convert CurrentSpaceID to string
		spaceID := ""
		switch v := display.CurrentSpaceID.(type) {
		case float64:
			spaceID = fmt.Sprintf("%.0f", v)
		case int:
			spaceID = fmt.Sprintf("%d", v)
		case int64:
			spaceID = fmt.Sprintf("%d", v)
		case string:
			spaceID = v
		}

		if spaceID == "" {
			errors = append(errors, DisplayError{
				DisplayUUID: display.UUID,
				DisplayName: display.Name,
				Err:         fmt.Errorf("could not determine space ID"),
			})
			continue
		}

		jsonlog.Log("layout.refresh_all.display", jsonlog.WithData(map[string]any{
			"uuid":    display.UUID,
			"name":    display.Name,
			"spaceID": spaceID,
		}))

		// 1. Fetch snapshot for this display's space
		snap, err := server.FetchForSpace(ctx, c, spaceID)
		if err != nil {
			errors = append(errors, DisplayError{
				DisplayUUID: display.UUID,
				DisplayName: display.Name,
				Err:         fmt.Errorf("failed to fetch snapshot for space %s: %w", spaceID, err),
			})
			continue
		}

		// 2. Reconcile state (clean up dead windows)
		// Inline reconcile logic to avoid import cycle with reconcile package
		if err := reconcileSpace(snap, rs); err != nil {
			errors = append(errors, DisplayError{
				DisplayUUID: display.UUID,
				DisplayName: display.Name,
				Err:         fmt.Errorf("failed to reconcile state: %w", err),
			})
			continue
		}

		// 3. Check if space has existing state
		spaceState := rs.GetSpaceReadOnly(spaceID)

		var layoutID string
		displayOpts := opts

		if spaceState != nil && spaceState.CurrentLayoutID != "" {
			// Existing state: reapply with preserved ratios
			layoutID = spaceState.CurrentLayoutID
			displayOpts.Strategy = types.AssignPreserve
			jsonlog.Log("layout.refresh_all.reapply", jsonlog.WithData(map[string]any{
				"spaceID":  spaceID,
				"layoutID": layoutID,
			}))
		} else {
			// No state: apply default layout
			layoutID = "default"
			// Check if "default" layout exists
			if _, err := cfg.GetLayout("default"); err != nil {
				// Fall back to built-in "single-tabbed"
				layoutID = "single-tabbed"
			}
			displayOpts.Strategy = types.AssignPosition
			jsonlog.Log("layout.refresh_all.fresh", jsonlog.WithData(map[string]any{
				"spaceID":  spaceID,
				"layoutID": layoutID,
			}))
		}

		// 4. Apply layout
		if err := ApplyLayout(ctx, c, snap, cfg, rs, layoutID, displayOpts); err != nil {
			errors = append(errors, DisplayError{
				DisplayUUID: display.UUID,
				DisplayName: display.Name,
				Err:         fmt.Errorf("failed to apply layout %s: %w", layoutID, err),
			})
			continue
		}
	}

	// If a display filter was specified but no displays matched, return an error
	if opts.DisplayFilter != "" && processedCount == 0 {
		errors = append(errors, DisplayError{
			DisplayUUID: opts.DisplayFilter,
			DisplayName: "unknown",
			Err:         fmt.Errorf("no display found with UUID %q", opts.DisplayFilter),
		})
	}

	jsonlog.Log("layout.refresh_all.done", jsonlog.WithData(map[string]any{
		"processed": processedCount,
		"errors":    len(errors),
	}))

	return errors
}
