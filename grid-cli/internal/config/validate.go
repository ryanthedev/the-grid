package config

import (
	"fmt"
	"strings"

	"github.com/yourusername/grid-cli/internal/types"
)

// Validate checks the configuration for errors
func (c *Config) Validate() error {
	// Validate layouts
	layoutIDs := make(map[string]bool)
	for i, layout := range c.Layouts {
		if layout.ID == "" {
			return fmt.Errorf("layout %d: missing ID", i)
		}
		if layoutIDs[layout.ID] {
			return fmt.Errorf("duplicate layout ID: %s", layout.ID)
		}
		layoutIDs[layout.ID] = true

		if err := validateLayout(&layout); err != nil {
			return fmt.Errorf("layout %s: %w", layout.ID, err)
		}
	}

	// Validate space configs reference existing layouts
	for spaceID, spaceConfig := range c.Spaces {
		for _, layoutID := range spaceConfig.Layouts {
			if !layoutIDs[layoutID] {
				return fmt.Errorf("space %s references unknown layout: %s", spaceID, layoutID)
			}
		}
		if spaceConfig.DefaultLayout != "" && !layoutIDs[spaceConfig.DefaultLayout] {
			return fmt.Errorf("space %s has unknown default layout: %s", spaceID, spaceConfig.DefaultLayout)
		}
	}

	// Validate app rules
	for i, rule := range c.AppRules {
		if rule.App == "" {
			return fmt.Errorf("appRule %d: missing app identifier", i)
		}
	}

	// Validate settings
	if err := validateSettings(&c.Settings); err != nil {
		return fmt.Errorf("settings: %w", err)
	}

	return nil
}

func validateLayout(layout *LayoutConfig) error {
	// Must have grid definition
	if len(layout.Grid.Columns) == 0 {
		return fmt.Errorf("missing columns definition")
	}
	if len(layout.Grid.Rows) == 0 {
		return fmt.Errorf("missing rows definition")
	}

	// Validate track sizes
	for i, col := range layout.Grid.Columns {
		if _, err := ParseTrackSize(col); err != nil {
			return fmt.Errorf("column %d: %w", i, err)
		}
	}
	for i, row := range layout.Grid.Rows {
		if _, err := ParseTrackSize(row); err != nil {
			return fmt.Errorf("row %d: %w", i, err)
		}
	}

	// Must have either cells or areas (not both, not neither)
	hasCells := len(layout.Cells) > 0
	hasAreas := len(layout.Areas) > 0

	if !hasCells && !hasAreas {
		return fmt.Errorf("must define either 'cells' or 'areas'")
	}

	// Validate cells
	if hasCells {
		cellIDs := make(map[string]bool)
		for _, cell := range layout.Cells {
			if cell.ID == "" {
				return fmt.Errorf("cell missing ID")
			}
			if cellIDs[cell.ID] {
				return fmt.Errorf("duplicate cell ID: %s", cell.ID)
			}
			cellIDs[cell.ID] = true

			if err := validateCellConfig(&cell, len(layout.Grid.Columns), len(layout.Grid.Rows)); err != nil {
				return fmt.Errorf("cell %s: %w", cell.ID, err)
			}
		}
	}

	// Validate areas
	if hasAreas {
		if err := validateAreas(layout.Areas, len(layout.Grid.Columns), len(layout.Grid.Rows)); err != nil {
			return fmt.Errorf("areas: %w", err)
		}
	}

	return nil
}

func validateCellConfig(cell *CellConfig, numCols, numRows int) error {
	colStart, colEnd, err := parseSpan(cell.Column)
	if err != nil {
		return fmt.Errorf("invalid column: %w", err)
	}
	rowStart, rowEnd, err := parseSpan(cell.Row)
	if err != nil {
		return fmt.Errorf("invalid row: %w", err)
	}

	// Check bounds (1-indexed, end is exclusive)
	if colStart < 1 || colEnd > numCols+1 || colStart >= colEnd {
		return fmt.Errorf("column span %d/%d out of bounds (grid has %d columns)", colStart, colEnd, numCols)
	}
	if rowStart < 1 || rowEnd > numRows+1 || rowStart >= rowEnd {
		return fmt.Errorf("row span %d/%d out of bounds (grid has %d rows)", rowStart, rowEnd, numRows)
	}

	// Validate stack mode if specified
	if cell.StackMode != "" {
		if !isValidStackMode(cell.StackMode) {
			return fmt.Errorf("invalid stack mode: %s", cell.StackMode)
		}
	}

	return nil
}

func validateAreas(areas [][]string, numCols, numRows int) error {
	if len(areas) != numRows {
		return fmt.Errorf("areas has %d rows but grid defines %d rows", len(areas), numRows)
	}
	for i, row := range areas {
		if len(row) != numCols {
			return fmt.Errorf("row %d has %d columns but grid defines %d columns", i, len(row), numCols)
		}
	}

	// Validate that each cell forms a rectangle
	cellMap := make(map[string][][2]int) // cellID -> list of [row, col] positions
	for rowIdx, row := range areas {
		for colIdx, cellID := range row {
			if cellID == "." || cellID == "" {
				continue
			}
			cellMap[cellID] = append(cellMap[cellID], [2]int{rowIdx, colIdx})
		}
	}

	for cellID, positions := range cellMap {
		if !isRectangular(positions) {
			return fmt.Errorf("cell '%s' does not form a rectangle", cellID)
		}
	}

	return nil
}

func isRectangular(positions [][2]int) bool {
	if len(positions) == 0 {
		return false
	}

	// Find bounds
	minRow, maxRow := positions[0][0], positions[0][0]
	minCol, maxCol := positions[0][1], positions[0][1]
	for _, pos := range positions {
		if pos[0] < minRow {
			minRow = pos[0]
		}
		if pos[0] > maxRow {
			maxRow = pos[0]
		}
		if pos[1] < minCol {
			minCol = pos[1]
		}
		if pos[1] > maxCol {
			maxCol = pos[1]
		}
	}

	// Expected count for a rectangle
	expected := (maxRow - minRow + 1) * (maxCol - minCol + 1)
	return len(positions) == expected
}

func validateSettings(s *Settings) error {
	if s.DefaultStackMode != "" && !isValidStackMode(s.DefaultStackMode) {
		return fmt.Errorf("invalid default stack mode: %s", s.DefaultStackMode)
	}
	if s.AnimationDuration < 0 {
		return fmt.Errorf("animation duration cannot be negative")
	}
	if s.BaseSpacing < 0 {
		return fmt.Errorf("base spacing cannot be negative")
	}
	return nil
}

func isValidStackMode(mode types.StackMode) bool {
	switch mode {
	case types.StackVertical, types.StackHorizontal, types.StackTabs, "":
		return true
	default:
		return false
	}
}

// parseSpan parses "start/end" format into integers
func parseSpan(s string) (start, end int, err error) {
	parts := strings.Split(s, "/")
	if len(parts) != 2 {
		return 0, 0, fmt.Errorf("expected 'start/end' format, got: %s", s)
	}
	_, err = fmt.Sscanf(parts[0], "%d", &start)
	if err != nil {
		return 0, 0, fmt.Errorf("invalid start value: %s", parts[0])
	}
	_, err = fmt.Sscanf(parts[1], "%d", &end)
	if err != nil {
		return 0, 0, fmt.Errorf("invalid end value: %s", parts[1])
	}
	return start, end, nil
}
