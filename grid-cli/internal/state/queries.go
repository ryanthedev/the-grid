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

// SetWindowAssignments bulk-sets window assignments for a space
func (rs *RuntimeState) SetWindowAssignments(spaceID string, assignments map[string][]uint32) {
	rs.mu.Lock()
	defer rs.mu.Unlock()

	space, ok := rs.Spaces[spaceID]
	if !ok {
		space = NewSpaceState(spaceID)
		rs.Spaces[spaceID] = space
	}

	// Clear existing cells
	space.Cells = make(map[string]*CellState)

	// Set new assignments
	for cellID, windowIDs := range assignments {
		cell := space.GetCell(cellID)
		cell.Windows = make([]uint32, len(windowIDs))
		copy(cell.Windows, windowIDs)
		cell.SplitRatios = equalRatios(len(windowIDs))
	}
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
