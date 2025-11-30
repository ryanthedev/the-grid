package reconcile

import (
	"github.com/yourusername/grid-cli/internal/logging"
	"github.com/yourusername/grid-cli/internal/server"
	"github.com/yourusername/grid-cli/internal/state"
)

// Sync updates runtimeState to match server reality.
// It removes windows from cells that no longer exist on the server,
// and syncs the focused cell to match the OS-focused window.
// This should be called before any command execution to ensure
// local state is accurate.
func Sync(snap *server.Snapshot, rs *state.RuntimeState) error {
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
