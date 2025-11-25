package layout

import (
	"github.com/yourusername/grid-cli/internal/types"
)

// CalculateTracks converts track definitions to pixel sizes.
//
// Parameters:
//   - tracks: Track size definitions from layout
//   - available: Total available space in pixels
//   - gap: Gap between tracks in pixels
//
// Returns: Array of pixel sizes for each track
func CalculateTracks(tracks []types.TrackSize, available float64, gap float64) []float64 {
	if len(tracks) == 0 {
		return nil
	}

	// Subtract gaps from available space
	totalGaps := gap * float64(len(tracks)-1)
	available -= totalGaps

	sizes := make([]float64, len(tracks))
	remaining := available

	// First pass: allocate fixed pixel tracks and collect fr tracks
	var totalFr float64
	var frIndices []int

	for i, track := range tracks {
		switch track.Type {
		case types.TrackPx:
			sizes[i] = track.Value
			remaining -= track.Value
		case types.TrackFr:
			totalFr += track.Value
			frIndices = append(frIndices, i)
		case types.TrackMinMax:
			// Start with minimum, will adjust later
			sizes[i] = track.Min
			remaining -= track.Min
			totalFr += track.Max // Max is in fr units
			frIndices = append(frIndices, i)
		case types.TrackAuto:
			// Auto tracks get minimum size initially
			// Content-based sizing not supported, treat as 0
			sizes[i] = 0
		}
	}

	// Second pass: distribute remaining space to fr tracks
	if totalFr > 0 && remaining > 0 {
		frUnit := remaining / totalFr

		for _, i := range frIndices {
			track := tracks[i]
			switch track.Type {
			case types.TrackFr:
				sizes[i] = frUnit * track.Value
			case types.TrackMinMax:
				// Add fr portion to minimum
				frPortion := frUnit * track.Max
				sizes[i] = track.Min + frPortion
			}
		}
	}

	// Third pass: apply minmax constraints and ensure non-negative
	sizes = applyMinMaxConstraints(tracks, sizes)

	return sizes
}

// applyMinMaxConstraints ensures minmax tracks stay within bounds
// and all sizes are non-negative.
func applyMinMaxConstraints(tracks []types.TrackSize, sizes []float64) []float64 {
	for i, track := range tracks {
		if track.Type == types.TrackMinMax {
			if sizes[i] < track.Min {
				sizes[i] = track.Min
			}
			// Note: max constraint in minmax(Xpx, Yfr) is relative, not absolute
		}

		// Ensure sizes are non-negative
		if sizes[i] < 0 {
			sizes[i] = 0
		}
	}

	return sizes
}

// CalculateTrackPositions returns the starting position of each track.
// The returned slice has length len(sizes)+1, where positions[i] is the
// start of track i, and positions[len(sizes)] is the end of the last track.
func CalculateTrackPositions(sizes []float64, gap float64) []float64 {
	positions := make([]float64, len(sizes)+1)
	positions[0] = 0

	for i, size := range sizes {
		positions[i+1] = positions[i] + size
		if i < len(sizes)-1 {
			positions[i+1] += gap
		}
	}

	return positions
}

// CalculateLayout computes the full layout with all cell bounds.
// This is the main entry point for layout calculation.
//
// Parameters:
//   - layout: Layout definition with columns, rows, and cells
//   - screenRect: Screen bounds to fit the layout into
//   - gap: Gap between cells in pixels
//
// Returns: CalculatedLayout with all cell bounds computed
func CalculateLayout(layout *types.Layout, screenRect types.Rect, gap float64) *types.CalculatedLayout {
	if layout == nil {
		return nil
	}

	// Calculate column and row sizes
	columnSizes := CalculateTracks(layout.Columns, screenRect.Width, gap)
	rowSizes := CalculateTracks(layout.Rows, screenRect.Height, gap)

	// Calculate column and row positions
	colPositions := CalculateTrackPositions(columnSizes, gap)
	rowPositions := CalculateTrackPositions(rowSizes, gap)

	// Calculate bounds for each cell
	cellBounds := make(map[string]types.Rect)
	for _, cell := range layout.Cells {
		bounds := CalculateCellBounds(cell, colPositions, rowPositions, columnSizes, rowSizes, gap)
		// Offset by screen position
		bounds.X += screenRect.X
		bounds.Y += screenRect.Y
		cellBounds[cell.ID] = bounds
	}

	return &types.CalculatedLayout{
		LayoutID:    layout.ID,
		ScreenRect:  screenRect,
		Gap:         gap,
		ColumnSizes: columnSizes,
		RowSizes:    rowSizes,
		CellBounds:  cellBounds,
	}
}
