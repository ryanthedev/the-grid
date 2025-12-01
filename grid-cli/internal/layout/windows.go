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
//   - layout: The layout definition (for padding and windowSpacing information)
//   - assignments: Map of cellID -> ordered list of window IDs
//   - cellModes: Per-cell stack mode overrides (nil uses defaultMode)
//   - cellRatios: Per-cell split ratios (nil uses equal splits)
//   - defaultMode: Default stack mode if not specified in cellModes
//   - baseSpacing: Base spacing unit for resolving "Nx" padding/spacing values
//   - settingsPadding: Global default padding from settings (nil = no default)
//   - settingsWindowSpacing: Global default window spacing from settings (nil = no default)
//
// Returns: Array of WindowPlacement for all windows
func CalculateAllWindowPlacements(
	calculatedLayout *types.CalculatedLayout,
	layout *types.Layout,
	assignments map[string][]uint32,
	cellModes map[string]types.StackMode,
	cellRatios map[string][]float64,
	defaultMode types.StackMode,
	baseSpacing float64,
	settingsPadding *types.Padding,
	settingsWindowSpacing *types.PaddingValue,
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

		// Apply cell padding inset (cell -> layout -> settings hierarchy)
		cellPadding := getEffectivePadding(layout, cellID, settingsPadding)
		if cellPadding != nil {
			resolved := cellPadding.Resolve(baseSpacing)
			cellBounds = applyPaddingInset(cellBounds, resolved)
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

		// Determine window spacing for this cell (cell -> layout -> settings hierarchy)
		windowSpacing := float64(0)
		if ws := getEffectiveWindowSpacing(layout, cellID, settingsWindowSpacing); ws != nil {
			windowSpacing = ws.Resolve(baseSpacing)
		}

		// Calculate window bounds within the (possibly padded) cell
		windowBounds := CalculateWindowBounds(cellBounds, len(windowIDs), mode, ratios, windowSpacing)

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

// getEffectivePadding returns the effective padding for a cell.
// Priority: cell override > layout default > settings default
func getEffectivePadding(layout *types.Layout, cellID string, settingsPadding *types.Padding) *types.Padding {
	if layout != nil {
		// Check cell-level override first
		for _, cell := range layout.Cells {
			if cell.ID == cellID && cell.Padding != nil {
				return cell.Padding
			}
		}
		// Fall back to layout default
		if layout.Padding != nil {
			return layout.Padding
		}
	}
	// Fall back to settings default
	return settingsPadding
}

// getEffectiveWindowSpacing returns the effective window spacing for a cell.
// Priority: cell override > layout default > settings default
func getEffectiveWindowSpacing(layout *types.Layout, cellID string, settingsSpacing *types.PaddingValue) *types.PaddingValue {
	if layout != nil {
		// Check cell-level override first
		for _, cell := range layout.Cells {
			if cell.ID == cellID && cell.WindowSpacing != nil {
				return cell.WindowSpacing
			}
		}
		// Fall back to layout default
		if layout.WindowSpacing != nil {
			return layout.WindowSpacing
		}
	}
	// Fall back to settings default
	return settingsSpacing
}

// applyPaddingInset shrinks bounds by the resolved padding values.
func applyPaddingInset(bounds types.Rect, p types.ResolvedPadding) types.Rect {
	return types.Rect{
		X:      bounds.X + p.Left,
		Y:      bounds.Y + p.Top,
		Width:  max(0, bounds.Width-p.Left-p.Right),
		Height: max(0, bounds.Height-p.Top-p.Bottom),
	}
}
