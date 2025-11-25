package focus

// CycleWindowIndex calculates the next window index when cycling through windows.
// Wraps around at boundaries.
func CycleWindowIndex(current, total int, forward bool) int {
	if total <= 0 {
		return 0
	}

	if forward {
		return (current + 1) % total
	}

	// Backward - handle wrap-around
	return (current - 1 + total) % total
}

// GetWindowAtIndex safely returns the window ID at the given index.
// Returns 0 if index is out of bounds or windows is empty.
func GetWindowAtIndex(windows []uint32, index int) uint32 {
	if len(windows) == 0 || index < 0 || index >= len(windows) {
		return 0
	}
	return windows[index]
}

// FindWindowIndex finds the index of a window ID in the slice.
// Returns -1 if not found.
func FindWindowIndex(windows []uint32, windowID uint32) int {
	for i, wid := range windows {
		if wid == windowID {
			return i
		}
	}
	return -1
}

// NextWindowInCell returns the next window ID when cycling forward.
// Returns the window ID and its index, or (0, -1) if no windows.
func NextWindowInCell(windows []uint32, currentIndex int) (uint32, int) {
	if len(windows) == 0 {
		return 0, -1
	}

	nextIndex := CycleWindowIndex(currentIndex, len(windows), true)
	return windows[nextIndex], nextIndex
}

// PrevWindowInCell returns the previous window ID when cycling backward.
// Returns the window ID and its index, or (0, -1) if no windows.
func PrevWindowInCell(windows []uint32, currentIndex int) (uint32, int) {
	if len(windows) == 0 {
		return 0, -1
	}

	prevIndex := CycleWindowIndex(currentIndex, len(windows), false)
	return windows[prevIndex], prevIndex
}

// FirstWindowInCell returns the first window in a cell.
// Returns 0 if cell has no windows.
func FirstWindowInCell(windows []uint32) uint32 {
	return GetWindowAtIndex(windows, 0)
}

// HasMultipleWindows returns true if the cell has more than one window.
func HasMultipleWindows(windows []uint32) bool {
	return len(windows) > 1
}
