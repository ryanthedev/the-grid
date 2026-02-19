package layout

import (
	"fmt"
	"math"

	"github.com/ryanthedev/grid-cli/internal/config"
	"github.com/ryanthedev/grid-cli/internal/types"
)

// RatiosToTrackStrings converts runtime ratios back to track size strings.
// Ratios apply only to flexible tracks (fr/minmax). Fixed tracks (px/auto)
// are returned unchanged. The ratios slice has one entry per flexible track.
func RatiosToTrackStrings(tracks []types.TrackSize, ratios []float64) []string {
	// Calculate total original fr to scale ratios back
	var totalFr float64
	for _, t := range tracks {
		switch t.Type {
		case types.TrackFr:
			totalFr += t.Value
		case types.TrackMinMax:
			totalFr += t.Max
		}
	}
	if totalFr == 0 {
		totalFr = float64(countFlexibleTracks(tracks))
	}

	result := make([]string, len(tracks))
	flexIdx := 0

	for i, t := range tracks {
		switch t.Type {
		case types.TrackFr:
			if flexIdx < len(ratios) {
				newFr := roundTo2(ratios[flexIdx] * totalFr)
				result[i] = formatFr(newFr)
				flexIdx++
			} else {
				result[i] = config.FormatTrackSize(t)
			}
		case types.TrackMinMax:
			if flexIdx < len(ratios) {
				newMax := roundTo2(ratios[flexIdx] * totalFr)
				result[i] = fmt.Sprintf("minmax(%.0fpx, %sfr)", t.Min, formatFloat(newMax))
				flexIdx++
			} else {
				result[i] = config.FormatTrackSize(t)
			}
		default:
			// px, auto — pass through unchanged
			result[i] = config.FormatTrackSize(t)
		}
	}

	return result
}

// roundTo2 rounds a float to 2 decimal places.
func roundTo2(v float64) float64 {
	return math.Round(v*100) / 100
}

// formatFr formats a fr value, using integer format when possible.
func formatFr(v float64) string {
	if v == float64(int(v)) {
		return fmt.Sprintf("%dfr", int(v))
	}
	return fmt.Sprintf("%sfr", formatFloat(v))
}

// formatFloat formats a float with up to 2 decimal places, trimming trailing zeros.
func formatFloat(v float64) string {
	s := fmt.Sprintf("%.2f", v)
	// Trim trailing zeros after decimal point
	if idx := len(s) - 1; s[idx] == '0' {
		s = s[:idx]
	}
	if idx := len(s) - 1; s[idx] == '0' {
		s = s[:idx]
	}
	// Trim trailing dot if all decimals were zero
	if idx := len(s) - 1; s[idx] == '.' {
		s = s[:idx]
	}
	return s
}
