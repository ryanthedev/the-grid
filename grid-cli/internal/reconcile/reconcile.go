package reconcile

import (
	"context"

	"github.com/ryanthedev/grid-cli/internal/client"
	"github.com/ryanthedev/grid-cli/internal/config"
	"github.com/ryanthedev/grid-cli/internal/jsonlog"
	"github.com/ryanthedev/grid-cli/internal/layout"
	"github.com/ryanthedev/grid-cli/internal/server"
	"github.com/ryanthedev/grid-cli/internal/state"
	"github.com/ryanthedev/grid-cli/internal/types"
)

// Sync updates runtimeState to match server reality.
// It removes windows from cells that no longer exist on the server,
// and syncs the focused cell to match the OS-focused window.
// This should be called before any command execution to ensure
// local state is accurate.
func Sync(ctx context.Context, c *client.Client, snap *server.Snapshot, rs *state.RuntimeState, cfg *config.Config) error {
	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil {
		// Still try to sync borders even with no local state
		syncBorders(ctx, c, snap, rs, cfg)
		return nil
	}

	changed := false
	for cellID, cell := range spaceState.Cells {
		var valid []uint32
		var removed []uint32
		for _, wid := range cell.Windows {
			if snap.WindowIDs[wid] {
				valid = append(valid, wid)
			} else {
				removed = append(removed, wid)
			}
		}

		if len(valid) != len(cell.Windows) {
			// [OBERDEBUG] Log detailed info about each removed window
			for _, wid := range removed {
				// Check why window isn't in WindowIDs
				reason := "unknown"
				windowInfo := snap.GetWindowByID(wid)
				if windowInfo == nil {
					reason = "not_in_space_windows"
				} else {
					// Window exists in space but failed IsTileable
					reason = "failed_istileable"
				}

				logData := map[string]any{
					"wid":            wid,
					"cell":           cellID,
					"space":          snap.SpaceID,
					"reason":         reason,
					"cell_before":    cell.Windows,
					"cell_after":     valid,
					"snap_window_ct": len(snap.Windows),
					"snap_wid_ct":    len(snap.WindowIDs),
				}

				// If window exists in space, log why IsTileable failed
				if windowInfo != nil {
					logData["win_title"] = windowInfo.Title
					logData["win_app"] = windowInfo.AppName
					logData["win_role"] = windowInfo.Role
					logData["win_subrole"] = windowInfo.Subrole
					logData["win_level"] = windowInfo.Level
					logData["win_minimized"] = windowInfo.IsMinimized
					logData["win_hidden"] = windowInfo.IsHidden
					logData["win_frame_w"] = windowInfo.Frame.Width
					logData["win_frame_h"] = windowInfo.Frame.Height
					logData["win_tileable"] = windowInfo.IsTileable()

					// Detailed IsTileable failure reason
					if windowInfo.Title == "" {
						logData["tileable_fail"] = "empty_title"
					} else if windowInfo.IsMinimized || windowInfo.IsHidden || windowInfo.Level != 0 {
						logData["tileable_fail"] = "state_check"
					} else if windowInfo.Frame.Height < server.MinTileableDimension || windowInfo.Frame.Width < server.MinTileableDimension {
						logData["tileable_fail"] = "dimension_check"
					} else if windowInfo.Subrole != "" && windowInfo.Subrole != "AXStandardWindow" {
						logData["tileable_fail"] = "subrole_check"
					} else if windowInfo.Role != "AXWindow" {
						logData["tileable_fail"] = "role_check"
					}
				}

				jsonlog.Log("dbg.reconcile.window_removed", jsonlog.WithData(logData))
			}

			// Windows were removed, update cell
			mutableCell := rs.GetSpace(snap.SpaceID).GetCell(cellID)
			mutableCell.Windows = valid
			mutableCell.SplitRatios = equalRatios(len(valid))
			changed = true
		}
	}

	// Sync focus: if OS-focused window is in a different cell, update state
	if snap.FocusedWindowID != 0 {
		if syncFocus(snap, rs) {
			changed = true
		}
	}

	if changed {
		rs.MarkUpdated()
		if err := rs.Save(); err != nil {
			return err
		}
	}

	// Sync borders to server (errors logged but don't fail reconcile)
	syncBorders(ctx, c, snap, rs, cfg)

	return nil
}

// syncFocus updates local focus state to match the OS-focused window.
// Returns true if state was changed.
func syncFocus(snap *server.Snapshot, rs *state.RuntimeState) bool {
	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil {
		return false
	}

	// Find which cell contains the OS-focused window
	focusedCell := spaceState.GetWindowCell(snap.FocusedWindowID)
	if focusedCell == "" {
		return false // focused window not in any cell
	}

	cell := spaceState.Cells[focusedCell]
	if cell == nil {
		return false
	}

	// Find window index in the cell
	windowIndex := -1
	for i, wid := range cell.Windows {
		if wid == snap.FocusedWindowID {
			windowIndex = i
			break
		}
	}
	if windowIndex == -1 {
		return false
	}

	// Already correct?
	if focusedCell == spaceState.FocusedCell && windowIndex == spaceState.FocusedWindow {
		return false
	}

	// Update focus
	jsonlog.Log("dbg.sync_focus", jsonlog.WithData(map[string]any{
		"snap_focused_wid": snap.FocusedWindowID,
		"old_cell":         spaceState.FocusedCell,
		"old_idx":          spaceState.FocusedWindow,
		"new_cell":         focusedCell,
		"new_idx":          windowIndex,
	}))
	rs.GetSpace(snap.SpaceID).SetFocus(focusedCell, windowIndex)
	return true
}

// equalRatios returns equal split ratios for n windows.
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

// calculateCellBounds computes cell bounds from layout definition and display geometry.
func calculateCellBounds(layoutDef *types.Layout, snap *server.Snapshot, spaceState *state.SpaceState) map[string]client.CellRect {
	if layoutDef == nil || len(layoutDef.Cells) == 0 {
		return nil
	}

	// Use ratio overrides from space state if available
	calculated := layout.CalculateLayoutWithRatios(
		layoutDef,
		snap.DisplayBounds,
		0, // gap handled by layout
		spaceState.ColumnRatios,
		spaceState.RowRatios,
	)

	if calculated == nil || len(calculated.CellBounds) == 0 {
		return nil
	}

	// Convert types.Rect to client.CellRect
	result := make(map[string]client.CellRect, len(calculated.CellBounds))
	for cellID, rect := range calculated.CellBounds {
		result[cellID] = client.CellRect{
			X:      rect.X,
			Y:      rect.Y,
			Width:  rect.Width,
			Height: rect.Height,
		}
	}

	return result
}

// buildCellAssignments builds the window-to-cell assignment list from space state.
func buildCellAssignments(spaceState *state.SpaceState) []client.CellAssignment {
	var assignments []client.CellAssignment

	for cellID, cellState := range spaceState.Cells {
		for _, windowID := range cellState.Windows {
			assignments = append(assignments, client.CellAssignment{
				WindowID: windowID,
				CellID:   cellID,
			})
		}
	}

	return assignments
}

// syncBorders sends cell assignments and bounds to the server for border rendering.
// This is called after reconcile to keep server border state in sync with CLI state.
// Errors are logged but don't fail the reconcile - borders are a visual enhancement.
func syncBorders(ctx context.Context, c *client.Client, snap *server.Snapshot, rs *state.RuntimeState, cfg *config.Config) {
	// 1. Check if borders are configured
	if cfg == nil || cfg.Borders == nil || !cfg.Borders.GetEnabled() {
		return
	}

	// 2. Get space state
	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil {
		return
	}

	// 3. Get current layout ID
	layoutID := spaceState.CurrentLayoutID
	if layoutID == "" {
		return
	}

	// 4. Get layout definition from config
	layoutDef, err := cfg.GetLayout(layoutID)
	if err != nil {
		jsonlog.Log("warn.sync_borders", jsonlog.WithData(map[string]any{"lid": layoutID, "err": err.Error()}))
		return
	}

	// 5. Calculate cell bounds
	calculated := calculateCellBounds(layoutDef, snap, spaceState)
	if calculated == nil {
		return
	}

	// 6. Build cell assignments from space state
	assignments := buildCellAssignments(spaceState)
	if len(assignments) == 0 {
		return
	}

	// 7. Apply padding to cell bounds to match window placement
	baseSpacing := cfg.GetBaseSpacing()
	settingsPadding, _ := cfg.GetSettingsPadding()
	paddedCellBounds := applyCellPadding(calculated, layoutDef, baseSpacing, settingsPadding)

	// 8. Get display UUID for per-display caching
	displayUUID := snap.GetCurrentDisplayUUID()
	if displayUUID == "" {
		jsonlog.Log("warn.sync_borders", jsonlog.WithMsg("could not determine display UUID"))
		return
	}

	// 9. Send to server
	if err := c.SendCellAssignments(ctx, displayUUID, assignments, nil, paddedCellBounds); err != nil {
		jsonlog.Log("warn.sync_borders", jsonlog.WithData(map[string]any{"err": err.Error()}))
		return
	}
}

// SyncBordersForDisplay sends cell assignments for a specific display/space.
// Used when focus crosses displays and we need to sync borders for the target.
// This is similar to syncBorders but uses a DisplayInfo instead of a Snapshot,
// which is necessary when syncing borders for a display other than the current one.
//
// Error handling: Errors are logged but not returned. Border sync is best-effort
// and should not block focus operations.
func SyncBordersForDisplay(ctx context.Context, c *client.Client, displayInfo server.DisplayInfo, spaceID string, rs *state.RuntimeState, cfg *config.Config) {
	if cfg == nil || cfg.Borders == nil || !cfg.Borders.GetEnabled() {
		return
	}

	spaceState := rs.GetSpaceReadOnly(spaceID)
	if spaceState == nil || spaceState.CurrentLayoutID == "" {
		return
	}

	layoutDef, err := cfg.GetLayout(spaceState.CurrentLayoutID)
	if err != nil {
		jsonlog.Log("warn.sync_borders_display", jsonlog.WithData(map[string]any{"lid": spaceState.CurrentLayoutID, "err": err.Error()}))
		return
	}

	// Use display's visible frame for bounds calculation
	displayBounds := displayInfo.VisibleFrame
	if displayBounds == (types.Rect{}) {
		displayBounds = displayInfo.Frame
	}
	if displayBounds == (types.Rect{}) {
		jsonlog.Log("warn.sync_borders_display", jsonlog.WithData(map[string]any{"display": displayInfo.UUID, "msg": "no frame info"}))
		return
	}

	// Create a minimal Snapshot with only the fields needed by calculateCellBounds.
	// calculateCellBounds only uses SpaceID (for logging) and DisplayBounds (for layout calculation).
	pseudoSnap := &server.Snapshot{
		SpaceID:       spaceID,
		DisplayBounds: displayBounds,
	}

	cellBounds := calculateCellBounds(layoutDef, pseudoSnap, spaceState)
	if cellBounds == nil {
		return
	}

	assignments := buildCellAssignments(spaceState)
	if len(assignments) == 0 {
		return
	}

	baseSpacing := cfg.GetBaseSpacing()
	settingsPadding, _ := cfg.GetSettingsPadding()
	paddedBounds := applyCellPadding(cellBounds, layoutDef, baseSpacing, settingsPadding)

	if err := c.SendCellAssignments(ctx, displayInfo.UUID, assignments, nil, paddedBounds); err != nil {
		jsonlog.Log("warn.sync_borders_display", jsonlog.WithData(map[string]any{"err": err.Error()}))
		return
	}
}

// applyCellPadding applies padding to cell bounds to match window placement areas.
// Uses layout.GetEffectivePadding to ensure consistent padding resolution.
func applyCellPadding(cellBounds map[string]client.CellRect, layoutDef *types.Layout, baseSpacing float64, settingsPadding *types.Padding) map[string]client.CellRect {
	result := make(map[string]client.CellRect, len(cellBounds))

	for cellID, rect := range cellBounds {
		// Use the same padding resolution logic as window placement
		effectivePadding := layout.GetEffectivePadding(layoutDef, cellID, settingsPadding)

		if effectivePadding != nil {
			resolved := effectivePadding.Resolve(baseSpacing)
			width := max(0, rect.Width-resolved.Left-resolved.Right)
			height := max(0, rect.Height-resolved.Top-resolved.Bottom)

			// Warn if padding results in zero-size bounds
			if width == 0 || height == 0 {
				jsonlog.Log("warn.cell_padding_zero", jsonlog.WithData(map[string]any{
					"cell": cellID, "origW": rect.Width, "origH": rect.Height,
				}))
			}

			result[cellID] = client.CellRect{
				X:      rect.X + resolved.Left,
				Y:      rect.Y + resolved.Top,
				Width:  width,
				Height: height,
			}
		} else {
			result[cellID] = rect
		}
	}

	return result
}
