package layout

import (
	"github.com/yourusername/grid-cli/internal/types"
)

// CalculateWindowBounds computes bounds for windows stacked in a cell.
//
// Parameters:
//   - cellBounds: The cell's bounds
//   - windowCount: Number of windows in the cell
//   - mode: How windows are stacked (vertical, horizontal, tabs)
//   - ratios: Split ratios (one per window, should sum to 1.0). If nil, uses equal splits
//   - padding: Padding between windows in pixels
//
// Returns: Array of Rects, one per window
func CalculateWindowBounds(
	cellBounds types.Rect,
	windowCount int,
	mode types.StackMode,
	ratios []float64,
	padding float64,
) []types.Rect {
	if windowCount == 0 {
		return nil
	}

	// Use equal ratios if not provided or wrong length
	if ratios == nil || len(ratios) != windowCount {
		ratios = equalRatios(windowCount)
	}

	var bounds []types.Rect

	switch mode {
	case types.StackVertical:
		bounds = calculateVerticalStack(cellBounds, ratios, padding)
	case types.StackHorizontal:
		bounds = calculateHorizontalStack(cellBounds, ratios, padding)
	case types.StackTabs:
		// All windows get full cell bounds (only one visible at a time)
		bounds = make([]types.Rect, windowCount)
		for i := 0; i < windowCount; i++ {
			bounds[i] = cellBounds
		}
	default:
		// Default to vertical stacking
		bounds = calculateVerticalStack(cellBounds, ratios, padding)
	}

	return bounds
}

// calculateVerticalStack arranges windows top-to-bottom.
func calculateVerticalStack(cellBounds types.Rect, ratios []float64, padding float64) []types.Rect {
	n := len(ratios)
	if n == 0 {
		return nil
	}

	totalPadding := padding * float64(n-1)
	availableHeight := cellBounds.Height - totalPadding

	bounds := make([]types.Rect, n)
	y := cellBounds.Y

	for i, ratio := range ratios {
		height := availableHeight * ratio
		bounds[i] = types.Rect{
			X:      cellBounds.X,
			Y:      y,
			Width:  cellBounds.Width,
			Height: height,
		}
		y += height + padding
	}

	return bounds
}

// calculateHorizontalStack arranges windows left-to-right.
func calculateHorizontalStack(cellBounds types.Rect, ratios []float64, padding float64) []types.Rect {
	n := len(ratios)
	if n == 0 {
		return nil
	}

	totalPadding := padding * float64(n-1)
	availableWidth := cellBounds.Width - totalPadding

	bounds := make([]types.Rect, n)
	x := cellBounds.X

	for i, ratio := range ratios {
		width := availableWidth * ratio
		bounds[i] = types.Rect{
			X:      x,
			Y:      cellBounds.Y,
			Width:  width,
			Height: cellBounds.Height,
		}
		x += width + padding
	}

	return bounds
}

// equalRatios returns an array of equal ratios summing to 1.0.
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

// NormalizeRatios ensures ratios sum to 1.0.
// If all ratios are zero, returns equal ratios.
func NormalizeRatios(ratios []float64) []float64 {
	if len(ratios) == 0 {
		return nil
	}

	sum := float64(0)
	for _, r := range ratios {
		sum += r
	}

	if sum == 0 {
		return equalRatios(len(ratios))
	}

	normalized := make([]float64, len(ratios))
	for i, r := range ratios {
		normalized[i] = r / sum
	}
	return normalized
}

// CalculateAllWindowPlacements computes placements for all windows in a layout.
//
// Parameters:
//   - calculatedLayout: Pre-calculated layout with cell bounds
//   - assignments: Map of cellID -> ordered list of window IDs
//   - cellModes: Per-cell stack mode overrides (nil uses defaultMode)
//   - cellRatios: Per-cell split ratios (nil uses equal splits)
//   - defaultMode: Default stack mode if not specified in cellModes
//   - padding: Padding between windows in pixels
//
// Returns: Array of WindowPlacement for all windows
func CalculateAllWindowPlacements(
	calculatedLayout *types.CalculatedLayout,
	assignments map[string][]uint32,
	cellModes map[string]types.StackMode,
	cellRatios map[string][]float64,
	defaultMode types.StackMode,
	padding float64,
) []types.WindowPlacement {
	if calculatedLayout == nil {
		return nil
	}

	var placements []types.WindowPlacement

	for cellID, windowIDs := range assignments {
		cellBounds, ok := calculatedLayout.CellBounds[cellID]
		if !ok {
			continue
		}

		// Determine stack mode for this cell
		mode := defaultMode
		if cellModes != nil {
			if m, ok := cellModes[cellID]; ok && m != "" {
				mode = m
			}
		}

		// Get split ratios for this cell
		var ratios []float64
		if cellRatios != nil {
			if r, ok := cellRatios[cellID]; ok {
				ratios = r
			}
		}

		// Calculate window bounds
		windowBounds := CalculateWindowBounds(cellBounds, len(windowIDs), mode, ratios, padding)

		// Create placements
		for i, windowID := range windowIDs {
			if i < len(windowBounds) {
				placements = append(placements, types.WindowPlacement{
					WindowID: windowID,
					Bounds:   windowBounds[i],
				})
			}
		}
	}

	return placements
}
