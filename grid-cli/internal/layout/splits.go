package layout

import (
	"fmt"
)

const (
	// MinimumRatio is the smallest ratio a window can have
	MinimumRatio = 0.1 // 10% minimum

	// DefaultResizeAmount is the default resize step
	DefaultResizeAmount = 0.1 // 10%
)

// InitializeSplitRatios creates equal ratios for N windows.
// This is exported for external use; internally windows.go uses equalRatios.
func InitializeSplitRatios(windowCount int) []float64 {
	return equalRatios(windowCount)
}

// NormalizeSplitRatios ensures ratios sum to 1.0.
// This delegates to NormalizeRatios in windows.go for consistency.
func NormalizeSplitRatios(ratios []float64) []float64 {
	return NormalizeRatios(ratios)
}

// AdjustSplitRatio modifies the ratio between two adjacent windows.
//
// Parameters:
//   - ratios: Current split ratios
//   - index: Index of window to grow (will shrink window at index+1)
//   - delta: Change in ratio (positive = grow, negative = shrink)
//   - minRatio: Minimum allowed ratio per window
//
// Returns: New ratios array and any error
func AdjustSplitRatio(ratios []float64, index int, delta float64, minRatio float64) ([]float64, error) {
	if len(ratios) < 2 {
		return ratios, fmt.Errorf("need at least 2 windows to adjust splits")
	}

	if index < 0 || index >= len(ratios)-1 {
		return ratios, fmt.Errorf("invalid index for split adjustment: %d", index)
	}

	newRatios := make([]float64, len(ratios))
	copy(newRatios, ratios)

	// Calculate proposed new values
	newFirst := newRatios[index] + delta
	newSecond := newRatios[index+1] - delta

	// Enforce minimum ratios
	if newFirst < minRatio {
		delta = newRatios[index] - minRatio
		newFirst = minRatio
		newSecond = newRatios[index+1] + (newRatios[index] - minRatio)
	}
	if newSecond < minRatio {
		delta = newRatios[index+1] - minRatio
		newSecond = minRatio
		newFirst = newRatios[index] + (newRatios[index+1] - minRatio)
	}

	newRatios[index] = newFirst
	newRatios[index+1] = newSecond

	// Normalize to ensure sum is exactly 1.0
	return NormalizeRatios(newRatios), nil
}

// AdjustSplitRatioAtBoundary adjusts the split at a specific boundary.
// boundaryIndex is the index between windows (0 = between window 0 and 1)
func AdjustSplitRatioAtBoundary(ratios []float64, boundaryIndex int, delta float64) ([]float64, error) {
	return AdjustSplitRatio(ratios, boundaryIndex, delta, MinimumRatio)
}

// RecalculateSplitsAfterRemoval adjusts ratios when a window is removed.
// The removed window's ratio is distributed to remaining windows.
func RecalculateSplitsAfterRemoval(ratios []float64, removedIndex int) []float64 {
	if len(ratios) <= 1 {
		return []float64{1.0}
	}

	if removedIndex < 0 || removedIndex >= len(ratios) {
		return ratios
	}

	removed := ratios[removedIndex]
	newRatios := make([]float64, 0, len(ratios)-1)

	// Copy all except removed
	for i, r := range ratios {
		if i != removedIndex {
			newRatios = append(newRatios, r)
		}
	}

	// Distribute removed window's ratio equally
	bonus := removed / float64(len(newRatios))
	for i := range newRatios {
		newRatios[i] += bonus
	}

	return NormalizeRatios(newRatios)
}

// RecalculateSplitsAfterAddition adjusts ratios when a window is added.
// The new window gets an equal share, existing windows are scaled proportionally.
func RecalculateSplitsAfterAddition(ratios []float64, newIndex int) []float64 {
	oldCount := len(ratios)
	newCount := oldCount + 1

	if oldCount == 0 {
		return []float64{1.0}
	}

	// New window gets equal share
	newRatio := 1.0 / float64(newCount)

	// Scale existing ratios
	scale := 1.0 - newRatio
	newRatios := make([]float64, newCount)

	for i, r := range ratios {
		destIndex := i
		if i >= newIndex {
			destIndex = i + 1
		}
		newRatios[destIndex] = r * scale
	}
	newRatios[newIndex] = newRatio

	return NormalizeRatios(newRatios)
}

// RecalculateSplitsAfterReorder adjusts ratios when windows are reordered.
// Maintains the ratio at each position, just with different windows.
func RecalculateSplitsAfterReorder(ratios []float64, oldIndex, newIndex int) []float64 {
	if oldIndex == newIndex || oldIndex < 0 || newIndex < 0 ||
		oldIndex >= len(ratios) || newIndex >= len(ratios) {
		return ratios
	}

	newRatios := make([]float64, len(ratios))
	copy(newRatios, ratios)

	// Move the ratio along with the window
	ratio := newRatios[oldIndex]
	if oldIndex < newIndex {
		// Shift left
		for i := oldIndex; i < newIndex; i++ {
			newRatios[i] = newRatios[i+1]
		}
	} else {
		// Shift right
		for i := oldIndex; i > newIndex; i-- {
			newRatios[i] = newRatios[i-1]
		}
	}
	newRatios[newIndex] = ratio

	return newRatios
}

// CalculateSplitBoundary returns the position of a split boundary.
// For vertical stacking, this is the Y position between windows.
// For horizontal stacking, this is the X position.
func CalculateSplitBoundary(cellSize float64, ratios []float64, boundaryIndex int, padding float64) float64 {
	if boundaryIndex < 0 || boundaryIndex >= len(ratios) {
		return 0
	}

	// Sum ratios up to and including boundaryIndex
	totalRatio := 0.0
	for i := 0; i <= boundaryIndex; i++ {
		totalRatio += ratios[i]
	}

	// Calculate available space (excluding padding between windows)
	paddingTotal := padding * float64(len(ratios)-1)
	availableSpace := cellSize - paddingTotal

	// Position includes window sizes plus padding between them
	position := availableSpace*totalRatio + padding*float64(boundaryIndex+1)

	return position
}
