package layout

import (
	"sort"

	"github.com/yourusername/grid-cli/internal/types"
)

// CalculateCellBounds computes the pixel rect for a cell.
//
// Parameters:
//   - cell: Cell definition with column/row spans (1-indexed, exclusive end)
//   - colPositions: Starting X position for each column (len = columns + 1)
//   - rowPositions: Starting Y position for each row (len = rows + 1)
//   - colSizes: Width of each column
//   - rowSizes: Height of each row
//   - gap: Gap between cells
//
// Returns: Rect with cell's position and size
func CalculateCellBounds(
	cell types.Cell,
	colPositions, rowPositions []float64,
	colSizes, rowSizes []float64,
	gap float64,
) types.Rect {
	// Convert 1-indexed to 0-indexed
	colStart := cell.ColumnStart - 1
	colEnd := cell.ColumnEnd - 1
	rowStart := cell.RowStart - 1
	rowEnd := cell.RowEnd - 1

	// Bounds checking
	if colStart < 0 || colEnd > len(colSizes) || colStart >= colEnd {
		return types.Rect{}
	}
	if rowStart < 0 || rowEnd > len(rowSizes) || rowStart >= rowEnd {
		return types.Rect{}
	}

	// Calculate X position and width
	x := colPositions[colStart]
	width := float64(0)
	for i := colStart; i < colEnd; i++ {
		width += colSizes[i]
		if i < colEnd-1 {
			width += gap // Add gap between spanned columns
		}
	}

	// Calculate Y position and height
	y := rowPositions[rowStart]
	height := float64(0)
	for i := rowStart; i < rowEnd; i++ {
		height += rowSizes[i]
		if i < rowEnd-1 {
			height += gap // Add gap between spanned rows
		}
	}

	return types.Rect{
		X:      x,
		Y:      y,
		Width:  width,
		Height: height,
	}
}

// GetCellAtPoint finds which cell contains the given point.
// Returns cell ID or empty string if no cell contains the point.
func GetCellAtPoint(cellBounds map[string]types.Rect, point types.Point) string {
	for cellID, bounds := range cellBounds {
		if bounds.Contains(point) {
			return cellID
		}
	}
	return ""
}

// GetAdjacentCells returns cells adjacent to the given cell in each direction.
// Adjacency is determined by visual overlap in the perpendicular axis.
func GetAdjacentCells(
	cellID string,
	cellBounds map[string]types.Rect,
) map[types.Direction][]string {
	result := map[types.Direction][]string{
		types.DirLeft:  {},
		types.DirRight: {},
		types.DirUp:    {},
		types.DirDown:  {},
	}

	current, ok := cellBounds[cellID]
	if !ok {
		return result
	}

	currentCenter := current.Center()

	for id, bounds := range cellBounds {
		if id == cellID {
			continue
		}

		center := bounds.Center()

		// Determine primary direction based on center offset
		dx := center.X - currentCenter.X
		dy := center.Y - currentCenter.Y

		// Check if there's meaningful overlap in the perpendicular axis
		if dx < 0 && overlapsVertically(current, bounds) {
			result[types.DirLeft] = append(result[types.DirLeft], id)
		}
		if dx > 0 && overlapsVertically(current, bounds) {
			result[types.DirRight] = append(result[types.DirRight], id)
		}
		if dy < 0 && overlapsHorizontally(current, bounds) {
			result[types.DirUp] = append(result[types.DirUp], id)
		}
		if dy > 0 && overlapsHorizontally(current, bounds) {
			result[types.DirDown] = append(result[types.DirDown], id)
		}
	}

	return result
}

// overlapsVertically checks if two rects have vertical overlap.
func overlapsVertically(a, b types.Rect) bool {
	return a.Y < b.Y+b.Height && a.Y+a.Height > b.Y
}

// overlapsHorizontally checks if two rects have horizontal overlap.
func overlapsHorizontally(a, b types.Rect) bool {
	return a.X < b.X+b.Width && a.X+a.Width > b.X
}

// SortCellsByPosition returns cell IDs sorted by visual position.
// Sort order: top-to-bottom, then left-to-right within each row.
func SortCellsByPosition(cellBounds map[string]types.Rect) []string {
	ids := make([]string, 0, len(cellBounds))
	for id := range cellBounds {
		ids = append(ids, id)
	}

	sort.Slice(ids, func(i, j int) bool {
		boundsI := cellBounds[ids[i]]
		boundsJ := cellBounds[ids[j]]

		// Compare by Y first (top-to-bottom), then X (left-to-right)
		if boundsI.Y != boundsJ.Y {
			return boundsI.Y < boundsJ.Y
		}
		return boundsI.X < boundsJ.X
	})

	return ids
}
