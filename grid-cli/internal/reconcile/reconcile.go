package reconcile

import (
	"context"

	"github.com/yourusername/grid-cli/internal/client"
	"github.com/yourusername/grid-cli/internal/config"
	"github.com/yourusername/grid-cli/internal/layout"
	"github.com/yourusername/grid-cli/internal/logging"
	"github.com/yourusername/grid-cli/internal/server"
	"github.com/yourusername/grid-cli/internal/state"
	"github.com/yourusername/grid-cli/internal/types"
)

// Sync updates runtimeState to match server reality.
// It removes windows from cells that no longer exist on the server,
// and syncs the focused cell to match the OS-focused window.
// This should be called before any command execution to ensure
// local state is accurate.
func Sync(ctx context.Context, c *client.Client, snap *server.Snapshot, rs *state.RuntimeState, cfg *config.Config) error {
	logging.Debug().
		Str("spaceID", snap.SpaceID).
		Uint32("focusedWindowID", snap.FocusedWindowID).
		Int("windowCount", len(snap.Windows)).
		Msg("reconcile: starting sync")

	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil {
		logging.Debug().
			Str("spaceID", snap.SpaceID).
			Msg("reconcile: no local state for space")
		return nil // Nothing to reconcile - no local state for this space
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
		return rs.Save()
	}

	return nil
}

// syncFocus updates local focus state to match the OS-focused window.
// Returns true if state was changed.
func syncFocus(snap *server.Snapshot, rs *state.RuntimeState) bool {
	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil {
		logging.Debug().
			Str("spaceID", snap.SpaceID).
			Msg("syncFocus: no local state for space")
		return false
	}

	logging.Debug().
		Uint32("focusedWindowID", snap.FocusedWindowID).
		Str("spaceID", snap.SpaceID).
		Str("currentFocusedCell", spaceState.FocusedCell).
		Msg("syncFocus: checking focus")

	// Find which cell contains the OS-focused window
	focusedCell := spaceState.GetWindowCell(snap.FocusedWindowID)
	if focusedCell == "" {
		logging.Debug().
			Uint32("focusedWindowID", snap.FocusedWindowID).
			Msg("syncFocus: focused window not in any cell")
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
		logging.Debug().
			Str("cell", focusedCell).
			Int("windowIndex", windowIndex).
			Msg("syncFocus: focus already in sync")
		return false
	}

	// Update focus
	logging.Debug().
		Str("oldCell", spaceState.FocusedCell).
		Str("newCell", focusedCell).
		Int("oldWindowIndex", spaceState.FocusedWindow).
		Int("newWindowIndex", windowIndex).
		Uint32("windowID", snap.FocusedWindowID).
		Msg("syncFocus: updating focus to match OS")

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
		logging.Debug().Msg("syncBorders: borders not enabled, skipping")
		return
	}

	// 2. Get space state
	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil {
		logging.Debug().
			Str("spaceID", snap.SpaceID).
			Msg("syncBorders: no local state for space, skipping")
		return
	}

	// 3. Get current layout ID
	layoutID := spaceState.CurrentLayoutID
	if layoutID == "" {
		logging.Debug().
			Str("spaceID", snap.SpaceID).
			Msg("syncBorders: no layout applied to space, skipping")
		return
	}

	// 4. Get layout definition from config
	layoutDef, err := cfg.GetLayout(layoutID)
	if err != nil {
		logging.Warn().
			Str("layoutID", layoutID).
			Err(err).
			Msg("syncBorders: failed to get layout definition")
		return
	}

	// 5. Calculate cell bounds
	calculated := calculateCellBounds(layoutDef, snap, spaceState)
	if calculated == nil {
		logging.Debug().Msg("syncBorders: no cell bounds calculated")
		return
	}

	// 6. Build cell assignments from space state
	assignments := buildCellAssignments(spaceState)
	if len(assignments) == 0 {
		logging.Debug().Msg("syncBorders: no cell assignments to send")
		return
	}

	// 7. Send to server
	if err := c.SendCellAssignments(ctx, assignments, nil, calculated); err != nil {
		logging.Warn().Err(err).Msg("syncBorders: failed to send cell assignments")
		return
	}

	logging.Debug().
		Int("assignments", len(assignments)).
		Int("cellBounds", len(calculated)).
		Msg("syncBorders: sent cell assignments to server")
}
