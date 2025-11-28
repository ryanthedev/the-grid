package reconcile

import (
	"github.com/yourusername/grid-cli/internal/server"
	"github.com/yourusername/grid-cli/internal/state"
)

// Sync updates runtimeState to match server reality.
// It removes windows from cells that no longer exist on the server.
// This should be called before any command execution to ensure
// local state is accurate.
func Sync(snap *server.Snapshot, rs *state.RuntimeState) error {
	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil {
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

	if changed {
		rs.MarkUpdated()
		return rs.Save()
	}

	return nil
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
