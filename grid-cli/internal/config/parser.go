package config

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/yourusername/grid-cli/internal/types"
)

var (
	// Track size patterns
	frPattern     = regexp.MustCompile(`^(\d+(?:\.\d+)?)\s*fr$`)
	pxPattern     = regexp.MustCompile(`^(\d+(?:\.\d+)?)\s*px$`)
	minmaxPattern = regexp.MustCompile(`^minmax\s*\(\s*(\d+(?:\.\d+)?)\s*px\s*,\s*(\d+(?:\.\d+)?)\s*fr\s*\)$`)
)

// ParseTrackSize parses a track size string into a TrackSize struct
// Supported formats:
//   - "1fr", "2fr", "1.5fr" - Fractional units
//   - "300px", "100.5px" - Fixed pixels
//   - "auto" - Content-based
//   - "minmax(200px, 1fr)" - Constrained flexible
func ParseTrackSize(s string) (types.TrackSize, error) {
	s = strings.TrimSpace(s)

	// Check for "auto"
	if s == "auto" {
		return types.TrackSize{Type: types.TrackAuto}, nil
	}

	// Check for fractional units (e.g., "1fr", "2.5fr")
	if matches := frPattern.FindStringSubmatch(s); matches != nil {
		value, _ := strconv.ParseFloat(matches[1], 64)
		return types.TrackSize{Type: types.TrackFr, Value: value}, nil
	}

	// Check for pixels (e.g., "300px", "100.5px")
	if matches := pxPattern.FindStringSubmatch(s); matches != nil {
		value, _ := strconv.ParseFloat(matches[1], 64)
		return types.TrackSize{Type: types.TrackPx, Value: value}, nil
	}

	// Check for minmax (e.g., "minmax(200px, 1fr)")
	if matches := minmaxPattern.FindStringSubmatch(s); matches != nil {
		min, _ := strconv.ParseFloat(matches[1], 64)
		max, _ := strconv.ParseFloat(matches[2], 64)
		return types.TrackSize{Type: types.TrackMinMax, Min: min, Max: max}, nil
	}

	return types.TrackSize{}, fmt.Errorf("invalid track size format: %s", s)
}

// AreasToCell converts an areas grid to cell definitions
// Areas format:
//
//	areas:
//	  - [main, main, side]
//	  - [main, main, side]
//	  - [footer, footer, footer]
//
// This creates cells: main (spans columns 1-2, rows 1-2), side (column 3, rows 1-2), footer (columns 1-3, row 3)
func AreasToCell(areas [][]string) []types.Cell {
	if len(areas) == 0 {
		return nil
	}

	// Find unique cell IDs and their bounds
	cellMap := make(map[string]*types.Cell)

	for rowIdx, row := range areas {
		for colIdx, cellID := range row {
			if cellID == "." || cellID == "" {
				continue // Skip empty cells
			}

			// 1-indexed positions
			col := colIdx + 1
			rowNum := rowIdx + 1

			if existing, ok := cellMap[cellID]; ok {
				// Expand bounds
				if col < existing.ColumnStart {
					existing.ColumnStart = col
				}
				if col+1 > existing.ColumnEnd {
					existing.ColumnEnd = col + 1
				}
				if rowNum < existing.RowStart {
					existing.RowStart = rowNum
				}
				if rowNum+1 > existing.RowEnd {
					existing.RowEnd = rowNum + 1
				}
			} else {
				// Create new cell
				cellMap[cellID] = &types.Cell{
					ID:          cellID,
					ColumnStart: col,
					ColumnEnd:   col + 1,
					RowStart:    rowNum,
					RowEnd:      rowNum + 1,
				}
			}
		}
	}

	// Convert map to slice, preserving order of first appearance
	seen := make(map[string]bool)
	var cells []types.Cell
	for _, row := range areas {
		for _, cellID := range row {
			if cellID == "." || cellID == "" {
				continue
			}
			if !seen[cellID] {
				seen[cellID] = true
				cells = append(cells, *cellMap[cellID])
			}
		}
	}

	return cells
}

// FormatTrackSize converts a TrackSize back to string representation
func FormatTrackSize(ts types.TrackSize) string {
	switch ts.Type {
	case types.TrackFr:
		if ts.Value == float64(int(ts.Value)) {
			return fmt.Sprintf("%dfr", int(ts.Value))
		}
		return fmt.Sprintf("%.2ffr", ts.Value)
	case types.TrackPx:
		if ts.Value == float64(int(ts.Value)) {
			return fmt.Sprintf("%dpx", int(ts.Value))
		}
		return fmt.Sprintf("%.2fpx", ts.Value)
	case types.TrackAuto:
		return "auto"
	case types.TrackMinMax:
		return fmt.Sprintf("minmax(%.0fpx, %.0ffr)", ts.Min, ts.Max)
	default:
		return ""
	}
}
