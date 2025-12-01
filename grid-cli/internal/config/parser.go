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

// ParsePadding parses a padding value from various shorthand formats
// Supported formats:
//   - 10 or 10.5 (number) -> all sides in pixels
//   - "10px" (string) -> all sides in pixels
//   - "2x" (string) -> all sides as 2 * baseSpacing
//   - [10, 5] (array) -> vertical=10, horizontal=5
//   - [10, 5, 8, 5] (array) -> top=10, right=5, bottom=8, left=5 (CSS order)
//   - {top: 10, right: 5, bottom: 8, left: 5} (object) -> explicit per-direction
func ParsePadding(raw interface{}) (*types.Padding, error) {
	if raw == nil {
		return nil, nil
	}

	switch v := raw.(type) {
	case int:
		pv := types.PaddingValue{Pixels: float64(v)}
		return &types.Padding{Top: pv, Right: pv, Bottom: pv, Left: pv}, nil

	case float64:
		pv := types.PaddingValue{Pixels: v}
		return &types.Padding{Top: pv, Right: pv, Bottom: pv, Left: pv}, nil

	case string:
		pv, err := parsePaddingValue(v)
		if err != nil {
			return nil, err
		}
		return &types.Padding{Top: pv, Right: pv, Bottom: pv, Left: pv}, nil

	case []interface{}:
		return parsePaddingArray(v)

	case map[string]interface{}:
		return parsePaddingObject(v)
	}

	return nil, fmt.Errorf("invalid padding format: %T", raw)
}

// parsePaddingValue parses a single padding value string
// Formats: "10", "10px", "2x", "1.5x"
func parsePaddingValue(s string) (types.PaddingValue, error) {
	s = strings.TrimSpace(s)

	// Check for "Nx" pattern (base-relative)
	if strings.HasSuffix(s, "x") {
		numStr := strings.TrimSuffix(s, "x")
		mult, err := strconv.ParseFloat(numStr, 64)
		if err != nil {
			return types.PaddingValue{}, fmt.Errorf("invalid base multiplier: %s", s)
		}
		return types.PaddingValue{BaseMultiple: mult, IsRelative: true}, nil
	}

	// Check for "Npx" pattern (explicit pixels)
	if strings.HasSuffix(s, "px") {
		numStr := strings.TrimSuffix(s, "px")
		px, err := strconv.ParseFloat(numStr, 64)
		if err != nil {
			return types.PaddingValue{}, fmt.Errorf("invalid pixel value: %s", s)
		}
		return types.PaddingValue{Pixels: px}, nil
	}

	// Plain number string
	px, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return types.PaddingValue{}, fmt.Errorf("invalid padding value: %s", s)
	}
	return types.PaddingValue{Pixels: px}, nil
}

// parseSinglePaddingValue handles int, float64, or string
func parseSinglePaddingValue(v interface{}) (types.PaddingValue, error) {
	switch val := v.(type) {
	case int:
		return types.PaddingValue{Pixels: float64(val)}, nil
	case float64:
		return types.PaddingValue{Pixels: val}, nil
	case string:
		return parsePaddingValue(val)
	default:
		return types.PaddingValue{}, fmt.Errorf("invalid padding value type: %T", v)
	}
}

// parsePaddingArray handles [vert, horiz] or [top, right, bottom, left]
func parsePaddingArray(arr []interface{}) (*types.Padding, error) {
	values := make([]types.PaddingValue, len(arr))
	for i, v := range arr {
		pv, err := parseSinglePaddingValue(v)
		if err != nil {
			return nil, fmt.Errorf("padding array index %d: %w", i, err)
		}
		values[i] = pv
	}

	switch len(values) {
	case 2: // [vertical, horizontal]
		return &types.Padding{
			Top:    values[0],
			Bottom: values[0],
			Left:   values[1],
			Right:  values[1],
		}, nil
	case 4: // [top, right, bottom, left] (CSS order)
		return &types.Padding{
			Top:    values[0],
			Right:  values[1],
			Bottom: values[2],
			Left:   values[3],
		}, nil
	default:
		return nil, fmt.Errorf("padding array must have 2 or 4 values, got %d", len(values))
	}
}

// parsePaddingObject handles {top: N, right: N, bottom: N, left: N}
func parsePaddingObject(obj map[string]interface{}) (*types.Padding, error) {
	padding := &types.Padding{}

	for key, val := range obj {
		pv, err := parseSinglePaddingValue(val)
		if err != nil {
			return nil, fmt.Errorf("padding.%s: %w", key, err)
		}

		switch key {
		case "top":
			padding.Top = pv
		case "right":
			padding.Right = pv
		case "bottom":
			padding.Bottom = pv
		case "left":
			padding.Left = pv
		default:
			return nil, fmt.Errorf("unknown padding key: %s", key)
		}
	}

	return padding, nil
}
