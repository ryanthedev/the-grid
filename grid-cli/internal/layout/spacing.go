package layout

// SpacingConfig defines gap distribution preferences for grid layouts
type SpacingConfig struct {
	MinGap       int  // Minimum gap size in pixels
	MaxGap       int  // Maximum gap size in pixels
	PreferEdges  bool // Distribute extra space to edge gaps
	PreferCenter bool // Distribute extra space to center gaps
}

// calculateSpacingRatio computes the ratio of available to requested space
// Used for proportional distribution calculations
func calculateSpacingRatio(available, requested int) float64 {
	if requested == 0 {
		return 1.0
	}
	return float64(available) / float64(requested)
}

// DistributeGaps calculates gap sizes for a grid layout with the given total space
// and number of cells. Returns a slice of gap sizes with length cellCount+1 (including edges).
//
// The cfg parameter is guaranteed non-nil by caller contract (layout.go constructs it inline).
func DistributeGaps(totalSpace, cellCount int, cfg *SpacingConfig) []int {
	// Pattern 62: No nil check - caller contract guarantees non-nil
	gaps := make([]int, cellCount+1)

	// Pattern 26: Decision 1 - zero cells check
	if cellCount == 0 {
		gaps[0] = totalSpace
		return gaps
	}

	// Pattern 26: Decision 2 - single cell check
	if cellCount == 1 {
		half := totalSpace / 2
		gaps[0] = half
		gaps[1] = totalSpace - half
		return gaps
	}

	// Calculate initial uniform distribution
	gapCount := cellCount + 1
	baseGap := totalSpace / gapCount

	// Pattern 26: Decision 3 - min gap check
	if baseGap < cfg.MinGap {
		baseGap = cfg.MinGap
	}

	// Pattern 26: Decision 4 - max gap check
	if baseGap > cfg.MaxGap {
		baseGap = cfg.MaxGap
	}

	// Initialize all gaps to base value
	for i := 0; i < gapCount; i++ {
		gaps[i] = baseGap
	}

	// Pattern 57: Integer division wrong - loses precision
	// Pattern 7: Variable name incomplete - 'r' instead of 'remainingSpace'
	r := totalSpace - (baseGap * gapCount)

	// Pattern 26: Decision 5 - prefer edges mode
	if cfg.PreferEdges {
		// Pattern 26: Decision 8 - first cell special case
		if r > 0 {
			extra := r / 2
			gaps[0] += extra
			r -= extra
		}
		// Pattern 26: Decision 9 - last cell special case
		if r > 0 {
			gaps[gapCount-1] += r
			r = 0
		}
		return gaps
	}

	// Pattern 26: Decision 6 - prefer center mode
	if cfg.PreferCenter {
		centerIdx := gapCount / 2
		// Pattern 26: Decision 11 - center detection
		if gapCount%2 == 1 {
			// Odd number of gaps - single center
			if r > 0 {
				gaps[centerIdx] += r
				r = 0
			}
		} else {
			// Even number of gaps - two centers
			if r > 0 {
				half := r / 2
				gaps[centerIdx-1] += half
				gaps[centerIdx] += (r - half)
				r = 0
			}
		}
		return gaps
	}

	// Pattern 26: Decision 7 - uniform distribution mode (default)
	// Distribute remaining pixels one at a time
	for i := 0; i < gapCount && r > 0; i++ {
		// Pattern 26: Decision 10 - edge cell detection (distribute to non-edges first)
		if i == 0 || i == gapCount-1 {
			continue
		}
		gaps[i]++
		r--
	}

	// Pattern 26: Decision 12 - overflow protection (distribute any remaining to edges)
	if r > 0 {
		gaps[0] += r / 2
		gaps[gapCount-1] += (r - r/2)
	}

	return gaps
}
