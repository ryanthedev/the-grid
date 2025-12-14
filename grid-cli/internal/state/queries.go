package state

import "github.com/yourusername/grid-cli/internal/types"

// GetAllWindowIDs returns all window IDs across all spaces
func (rs *RuntimeState) GetAllWindowIDs() []uint32 {
	rs.mu.RLock()
	defer rs.mu.RUnlock()

	var ids []uint32
	seen := make(map[uint32]bool)

	for _, space := range rs.Spaces {
		for _, cell := range space.Cells {
			for _, wid := range cell.Windows {
				if !seen[wid] {
					seen[wid] = true
					ids = append(ids, wid)
				}
			}
		}
	}

	return ids
}

// GetCellWindows returns window IDs for a specific cell in a space
func (rs *RuntimeState) GetCellWindows(spaceID, cellID string) []uint32 {
	rs.mu.RLock()
	defer rs.mu.RUnlock()

	space, ok := rs.Spaces[spaceID]
	if !ok {
		return nil
	}

	cell, ok := space.Cells[cellID]
	if !ok {
		return nil
	}

	// Return a copy to prevent modification
	result := make([]uint32, len(cell.Windows))
	copy(result, cell.Windows)
	return result
}

// GetCellSplitRatios returns split ratios for a cell
func (rs *RuntimeState) GetCellSplitRatios(spaceID, cellID string) []float64 {
	rs.mu.RLock()
	defer rs.mu.RUnlock()

	space, ok := rs.Spaces[spaceID]
	if !ok {
		return nil
	}

	cell, ok := space.Cells[cellID]
	if !ok {
		return nil
	}

	// Return a copy to prevent modification
	result := make([]float64, len(cell.SplitRatios))
	copy(result, cell.SplitRatios)
	return result
}

// GetCellStackMode returns the stack mode override for a cell
func (rs *RuntimeState) GetCellStackMode(spaceID, cellID string) types.StackMode {
	rs.mu.RLock()
	defer rs.mu.RUnlock()

	space, ok := rs.Spaces[spaceID]
	if !ok {
		return ""
	}

	cell, ok := space.Cells[cellID]
	if !ok {
		return ""
	}

	return cell.StackMode
}

// SetCellStackMode sets the stack mode override for a cell
func (rs *RuntimeState) SetCellStackMode(spaceID, cellID string, mode types.StackMode) {
	rs.mu.Lock()
	defer rs.mu.Unlock()

	space, ok := rs.Spaces[spaceID]
	if !ok {
		space = NewSpaceState(spaceID)
		rs.Spaces[spaceID] = space
	}

	cell := space.GetCell(cellID)
	cell.StackMode = mode
}

// GetCurrentLayoutForSpace returns the current layout ID for a space
func (rs *RuntimeState) GetCurrentLayoutForSpace(spaceID string) string {
	rs.mu.RLock()
	defer rs.mu.RUnlock()

	space, ok := rs.Spaces[spaceID]
	if !ok {
		return ""
	}

	return space.CurrentLayoutID
}

// GetWindowAssignments returns a map of cellID -> windowIDs for a space
func (rs *RuntimeState) GetWindowAssignments(spaceID string) map[string][]uint32 {
	rs.mu.RLock()
	defer rs.mu.RUnlock()

	space, ok := rs.Spaces[spaceID]
	if !ok {
		return nil
	}

	assignments := make(map[string][]uint32)
	for cellID, cell := range space.Cells {
		if len(cell.Windows) > 0 {
			// Copy the windows slice
			windows := make([]uint32, len(cell.Windows))
			copy(windows, cell.Windows)
			assignments[cellID] = windows
		}
	}

	return assignments
}

// SetWindowAssignments bulk-sets window assignments for a space.
// Preserves existing cell state (SplitRatios, StackMode, LastFocusedIdx)
// when possible, adjusting ratios for window count changes.
func (rs *RuntimeState) SetWindowAssignments(spaceID string, assignments map[string][]uint32) {
	rs.mu.Lock()
	defer rs.mu.Unlock()

	space, ok := rs.Spaces[spaceID]
	if !ok {
		space = NewSpaceState(spaceID)
		rs.Spaces[spaceID] = space
	}

	// Save existing cell state to preserve splitRatios, stackMode, etc.
	existingCells := space.Cells

	// Create new cells map
	space.Cells = make(map[string]*CellState)

	// Set new assignments, preserving existing state where appropriate
	for cellID, windowIDs := range assignments {
		cell := space.GetCell(cellID)
		cell.Windows = make([]uint32, len(windowIDs))
		copy(cell.Windows, windowIDs)

		// Preserve existing cell state if cell existed
		if existingCell, ok := existingCells[cellID]; ok {
			// Preserve stack mode and focus
			cell.StackMode = existingCell.StackMode
			cell.LastFocusedIdx = existingCell.LastFocusedIdx

			// Preserve or adjust splitRatios
			if len(existingCell.SplitRatios) > 0 {
				if len(existingCell.SplitRatios) == len(windowIDs) {
					// Same window count - preserve ratios as-is
					cell.SplitRatios = make([]float64, len(existingCell.SplitRatios))
					copy(cell.SplitRatios, existingCell.SplitRatios)
				} else {
					// Window count changed - adjust ratios
					cell.SplitRatios = adjustRatiosForCount(existingCell.SplitRatios, len(windowIDs))
				}
			} else {
				cell.SplitRatios = equalRatios(len(windowIDs))
			}
		} else {
			cell.SplitRatios = equalRatios(len(windowIDs))
		}
	}
}

// adjustRatiosForCount adjusts split ratios when window count changes.
// When shrinking: drops the last N ratios and renormalizes.
// When growing: takes space equally from all existing ratios for new windows.
func adjustRatiosForCount(ratios []float64, newCount int) []float64 {
	if newCount <= 0 {
		return nil
	}

	if len(ratios) == 0 {
		return equalRatios(newCount)
	}

	oldCount := len(ratios)
	if oldCount == newCount {
		return normalizeRatios(ratios)
	}

	if newCount < oldCount {
		// Shrinking: take first newCount ratios and renormalize
		kept := ratios[:newCount]
		return normalizeRatios(kept)
	}

	// Growing: give new windows equal share from existing
	newRatios := make([]float64, newCount)
	addedCount := newCount - oldCount
	sharePerNew := 1.0 / float64(newCount)
	totalTaken := sharePerNew * float64(addedCount)
	scale := (1.0 - totalTaken)

	for i := 0; i < oldCount; i++ {
		newRatios[i] = ratios[i] * scale
	}
	for i := oldCount; i < newCount; i++ {
		newRatios[i] = sharePerNew
	}

	return normalizeRatios(newRatios)
}

// normalizeRatios ensures ratios sum to 1.0
func normalizeRatios(ratios []float64) []float64 {
	if len(ratios) == 0 {
		return nil
	}

	sum := 0.0
	for _, r := range ratios {
		sum += r
	}

	if sum == 0 {
		return equalRatios(len(ratios))
	}

	result := make([]float64, len(ratios))
	for i, r := range ratios {
		result[i] = r / sum
	}
	return result
}

// HasState returns true if there is any state for the given space
func (rs *RuntimeState) HasState(spaceID string) bool {
	rs.mu.RLock()
	defer rs.mu.RUnlock()

	space, ok := rs.Spaces[spaceID]
	if !ok {
		return false
	}

	return space.CurrentLayoutID != "" || len(space.Cells) > 0
}

// Summary returns a summary of the current state for display/debugging
func (rs *RuntimeState) Summary() map[string]interface{} {
	rs.mu.RLock()
	defer rs.mu.RUnlock()

	spaces := make(map[string]interface{})
	for spaceID, space := range rs.Spaces {
		windowCount := 0
		for _, cell := range space.Cells {
			windowCount += len(cell.Windows)
		}

		spaces[spaceID] = map[string]interface{}{
			"currentLayout": space.CurrentLayoutID,
			"cellCount":     len(space.Cells),
			"windowCount":   windowCount,
			"focusedCell":   space.FocusedCell,
		}
	}

	return map[string]interface{}{
		"version":     rs.Version,
		"lastUpdated": rs.LastUpdated,
		"spaceCount":  len(rs.Spaces),
		"spaces":      spaces,
	}
}
