package focus

import (
	"math"

	"github.com/yourusername/grid-cli/internal/types"
)

// FindTargetCell finds the best cell to navigate to in the given direction.
// Returns the target cell ID and true if found, or empty string and false if no cell in that direction.
// If wrapAround is true and no cell is found, it will wrap to the opposite edge.
func FindTargetCell(currentCellID string, direction types.Direction, cellBounds map[string]types.Rect, wrapAround bool) (string, bool) {
	current, ok := cellBounds[currentCellID]
	if !ok {
		return "", false
	}

	currentCenter := current.Center()

	var bestCell string
	bestDistance := math.MaxFloat64

	// Find all cells in the direction and pick the closest one
	for cellID, bounds := range cellBounds {
		if cellID == currentCellID {
			continue
		}

		targetCenter := bounds.Center()

		if !isInDirection(currentCenter, targetCenter, direction) {
			continue
		}

		distance := distanceInDirection(currentCenter, targetCenter, direction)
		if distance < bestDistance {
			bestDistance = distance
			bestCell = cellID
		}
	}

	if bestCell != "" {
		return bestCell, true
	}

	// No cell found in direction - try wrap around if enabled
	if wrapAround {
		return findWrapAroundCell(currentCellID, direction, cellBounds)
	}

	return "", false
}

// isInDirection checks if target is in the specified direction from source.
// Uses center points for comparison.
func isInDirection(source, target types.Point, direction types.Direction) bool {
	switch direction {
	case types.DirLeft:
		return target.X < source.X
	case types.DirRight:
		return target.X > source.X
	case types.DirUp:
		return target.Y < source.Y
	case types.DirDown:
		return target.Y > source.Y
	default:
		return false
	}
}

// distanceInDirection calculates weighted distance between two points.
// The algorithm prefers cells that are more directly aligned with the direction.
// Distance = primary axis movement + perpendicular axis movement * 2
// This weighting ensures we prefer cells that are more "in line" with the direction.
func distanceInDirection(source, target types.Point, direction types.Direction) float64 {
	dx := math.Abs(target.X - source.X)
	dy := math.Abs(target.Y - source.Y)

	switch direction {
	case types.DirLeft, types.DirRight:
		// Horizontal movement - primary is X, perpendicular is Y
		return dx + dy*2
	case types.DirUp, types.DirDown:
		// Vertical movement - primary is Y, perpendicular is X
		return dy + dx*2
	default:
		// Fallback to Euclidean distance
		return math.Sqrt(dx*dx + dy*dy)
	}
}

// findWrapAroundCell finds the cell on the opposite edge when wrapping.
// For example, if going right and no cell exists, wrap to the leftmost cell.
func findWrapAroundCell(currentCellID string, direction types.Direction, cellBounds map[string]types.Rect) (string, bool) {
	current, ok := cellBounds[currentCellID]
	if !ok {
		return "", false
	}

	currentCenter := current.Center()

	var bestCell string
	bestDistance := math.MaxFloat64

	// Find the cell on the opposite edge that's most aligned with current position
	for cellID, bounds := range cellBounds {
		if cellID == currentCellID {
			continue
		}

		targetCenter := bounds.Center()

		// Check if this cell is on the opposite edge
		if !isOnOppositeEdge(currentCenter, targetCenter, direction, cellBounds) {
			continue
		}

		// Calculate perpendicular distance (how aligned it is)
		distance := perpendicularDistance(currentCenter, targetCenter, direction)
		if distance < bestDistance {
			bestDistance = distance
			bestCell = cellID
		}
	}

	if bestCell != "" {
		return bestCell, true
	}

	return "", false
}

// isOnOppositeEdge checks if a cell is on the opposite edge for wrap-around.
func isOnOppositeEdge(current, target types.Point, direction types.Direction, cellBounds map[string]types.Rect) bool {
	// Find the extreme positions in the grid
	minX, maxX := math.MaxFloat64, -math.MaxFloat64
	minY, maxY := math.MaxFloat64, -math.MaxFloat64

	for _, bounds := range cellBounds {
		center := bounds.Center()
		minX = math.Min(minX, center.X)
		maxX = math.Max(maxX, center.X)
		minY = math.Min(minY, center.Y)
		maxY = math.Max(maxY, center.Y)
	}

	// Define "edge" as being within 10% of the extreme
	xRange := maxX - minX
	yRange := maxY - minY
	xThreshold := xRange * 0.1
	yThreshold := yRange * 0.1

	// Handle edge cases where range is 0 (single row/column)
	if xRange == 0 {
		xThreshold = 1
	}
	if yRange == 0 {
		yThreshold = 1
	}

	switch direction {
	case types.DirLeft:
		// Going left, wrap to rightmost
		return target.X >= maxX-xThreshold
	case types.DirRight:
		// Going right, wrap to leftmost
		return target.X <= minX+xThreshold
	case types.DirUp:
		// Going up, wrap to bottom
		return target.Y >= maxY-yThreshold
	case types.DirDown:
		// Going down, wrap to top
		return target.Y <= minY+yThreshold
	default:
		return false
	}
}

// perpendicularDistance returns the distance along the perpendicular axis.
// Used to find the most aligned cell when wrapping.
func perpendicularDistance(source, target types.Point, direction types.Direction) float64 {
	switch direction {
	case types.DirLeft, types.DirRight:
		// For horizontal movement, perpendicular is Y
		return math.Abs(target.Y - source.Y)
	case types.DirUp, types.DirDown:
		// For vertical movement, perpendicular is X
		return math.Abs(target.X - source.X)
	default:
		return math.Sqrt(math.Pow(target.X-source.X, 2) + math.Pow(target.Y-source.Y, 2))
	}
}

// GetCellInDirection is a simple helper that returns the cell in a direction without wrap-around.
// Returns empty string if no cell found.
func GetCellInDirection(currentCellID string, direction types.Direction, cellBounds map[string]types.Rect) string {
	cellID, _ := FindTargetCell(currentCellID, direction, cellBounds, false)
	return cellID
}
