# Phase 1: Configuration Parser Module

## Overview

Implement the configuration loading and parsing system for grid layouts. This module reads YAML/JSON configuration files and provides typed configuration structures to other modules.

**Location**: `grid-cli/internal/config/`

**Dependencies**: Phase 0 (Shared Types)

**Parallelizes With**: Phase 2, Phase 3

---

## Scope

1. Load configuration from `~/.config/thegrid/config.yaml` (or `.json`)
2. Parse both YAML and JSON formats
3. Parse track size strings ("1fr", "300px", "minmax(200px, 1fr)")
4. Convert `areas` syntax to cell definitions
5. Validate configuration structure
6. Provide typed configuration access

---

## Files to Create

```
grid-cli/internal/config/
├── config.go       # Main config loading and access
├── parser.go       # Track size and areas parsing
├── validate.go     # Configuration validation
└── types.go        # Config-specific types with YAML/JSON tags
```

---

## Dependencies to Add

Add to `go.mod`:
```
go get gopkg.in/yaml.v3
```

---

## Type Definitions

### types.go

```go
package config

import "github.com/yourusername/grid-cli/internal/types"

// Config is the root configuration structure
type Config struct {
    Settings Settings              `yaml:"settings" json:"settings"`
    Layouts  []LayoutConfig        `yaml:"layouts" json:"layouts"`
    Spaces   map[string]SpaceConfig `yaml:"spaces" json:"spaces"`
    AppRules []AppRule             `yaml:"appRules" json:"appRules"`
}

// Settings contains global application settings
type Settings struct {
    DefaultStackMode  types.StackMode `yaml:"defaultStackMode" json:"defaultStackMode"`
    AnimationDuration float64         `yaml:"animationDuration" json:"animationDuration"`
    CellPadding       int             `yaml:"cellPadding" json:"cellPadding"`
    FocusFollowsMouse bool            `yaml:"focusFollowsMouse" json:"focusFollowsMouse"`
}

// LayoutConfig is the configuration representation of a layout
// Supports both explicit cells and areas syntax
type LayoutConfig struct {
    ID          string              `yaml:"id" json:"id"`
    Name        string              `yaml:"name" json:"name"`
    Description string              `yaml:"description,omitempty" json:"description,omitempty"`
    Grid        GridConfig          `yaml:"grid" json:"grid"`
    Areas       [][]string          `yaml:"areas,omitempty" json:"areas,omitempty"`       // ASCII grid syntax
    Cells       []CellConfig        `yaml:"cells,omitempty" json:"cells,omitempty"`       // Explicit cell definitions
    CellModes   map[string]types.StackMode `yaml:"cellModes,omitempty" json:"cellModes,omitempty"`
}

// GridConfig defines the grid structure
type GridConfig struct {
    Columns []string `yaml:"columns" json:"columns"` // Track size strings
    Rows    []string `yaml:"rows" json:"rows"`       // Track size strings
}

// CellConfig is the configuration representation of a cell
type CellConfig struct {
    ID        string          `yaml:"id" json:"id"`
    Column    string          `yaml:"column" json:"column"`       // "start/end" format, e.g., "1/3"
    Row       string          `yaml:"row" json:"row"`             // "start/end" format, e.g., "1/2"
    StackMode types.StackMode `yaml:"stackMode,omitempty" json:"stackMode,omitempty"`
}

// SpaceConfig defines per-Space settings
type SpaceConfig struct {
    Name          string   `yaml:"name,omitempty" json:"name,omitempty"`
    Layouts       []string `yaml:"layouts" json:"layouts"`             // Layout IDs available for this space
    DefaultLayout string   `yaml:"defaultLayout" json:"defaultLayout"` // Initial layout
    AutoApply     bool     `yaml:"autoApply" json:"autoApply"`         // Auto-apply on space switch
}

// AppRule defines application-specific window behavior
type AppRule struct {
    App                string          `yaml:"app" json:"app"`                           // App name or bundle ID
    PreferredCell      string          `yaml:"preferredCell,omitempty" json:"preferredCell,omitempty"`
    Layouts            []string        `yaml:"layouts,omitempty" json:"layouts,omitempty"` // Only applies to these layouts
    Float              bool            `yaml:"float,omitempty" json:"float,omitempty"`     // Never tile this app
    PreferredStackMode types.StackMode `yaml:"preferredStackMode,omitempty" json:"preferredStackMode,omitempty"`
}
```

---

## Implementation

### config.go

```go
package config

import (
    "encoding/json"
    "fmt"
    "os"
    "path/filepath"
    "strings"

    "gopkg.in/yaml.v3"
    "github.com/yourusername/grid-cli/internal/types"
)

const (
    DefaultConfigDir  = ".config/thegrid"
    DefaultConfigFile = "config.yaml"
)

// LoadConfig loads configuration from the specified path or default location
// If path is empty, uses ~/.config/thegrid/config.yaml
// Supports both .yaml and .json extensions
func LoadConfig(path string) (*Config, error) {
    if path == "" {
        home, err := os.UserHomeDir()
        if err != nil {
            return nil, fmt.Errorf("cannot determine home directory: %w", err)
        }
        // Try YAML first, then JSON
        yamlPath := filepath.Join(home, DefaultConfigDir, "config.yaml")
        jsonPath := filepath.Join(home, DefaultConfigDir, "config.json")

        if _, err := os.Stat(yamlPath); err == nil {
            path = yamlPath
        } else if _, err := os.Stat(jsonPath); err == nil {
            path = jsonPath
        } else {
            return nil, fmt.Errorf("no config file found at %s or %s", yamlPath, jsonPath)
        }
    }

    data, err := os.ReadFile(path)
    if err != nil {
        return nil, fmt.Errorf("failed to read config file: %w", err)
    }

    var cfg Config
    ext := strings.ToLower(filepath.Ext(path))

    switch ext {
    case ".yaml", ".yml":
        if err := yaml.Unmarshal(data, &cfg); err != nil {
            return nil, fmt.Errorf("failed to parse YAML config: %w", err)
        }
    case ".json":
        if err := json.Unmarshal(data, &cfg); err != nil {
            return nil, fmt.Errorf("failed to parse JSON config: %w", err)
        }
    default:
        return nil, fmt.Errorf("unsupported config format: %s", ext)
    }

    if err := cfg.Validate(); err != nil {
        return nil, fmt.Errorf("invalid config: %w", err)
    }

    return &cfg, nil
}

// GetConfigPath returns the default config file path
func GetConfigPath() string {
    home, _ := os.UserHomeDir()
    return filepath.Join(home, DefaultConfigDir, DefaultConfigFile)
}

// GetLayout returns a layout by ID, converting from LayoutConfig to types.Layout
func (c *Config) GetLayout(id string) (*types.Layout, error) {
    for _, lc := range c.Layouts {
        if lc.ID == id {
            return lc.ToLayout()
        }
    }
    return nil, fmt.Errorf("layout not found: %s", id)
}

// GetLayoutIDs returns all available layout IDs
func (c *Config) GetLayoutIDs() []string {
    ids := make([]string, len(c.Layouts))
    for i, l := range c.Layouts {
        ids[i] = l.ID
    }
    return ids
}

// GetSpaceConfig returns configuration for a specific space
func (c *Config) GetSpaceConfig(spaceID string) *SpaceConfig {
    if sc, ok := c.Spaces[spaceID]; ok {
        return &sc
    }
    return nil
}

// GetAppRule finds the first matching app rule
func (c *Config) GetAppRule(appName, bundleID string) *AppRule {
    for _, rule := range c.AppRules {
        if rule.App == appName || rule.App == bundleID {
            return &rule
        }
    }
    return nil
}

// ToLayout converts LayoutConfig to types.Layout
func (lc *LayoutConfig) ToLayout() (*types.Layout, error) {
    // Parse columns
    columns := make([]types.TrackSize, len(lc.Grid.Columns))
    for i, col := range lc.Grid.Columns {
        ts, err := ParseTrackSize(col)
        if err != nil {
            return nil, fmt.Errorf("invalid column %d: %w", i, err)
        }
        columns[i] = ts
    }

    // Parse rows
    rows := make([]types.TrackSize, len(lc.Grid.Rows))
    for i, row := range lc.Grid.Rows {
        ts, err := ParseTrackSize(row)
        if err != nil {
            return nil, fmt.Errorf("invalid row %d: %w", i, err)
        }
        rows[i] = ts
    }

    // Parse cells (either from explicit cells or areas)
    var cells []types.Cell
    if len(lc.Areas) > 0 {
        cells = AreasToCell(lc.Areas)
    } else {
        cells = make([]types.Cell, len(lc.Cells))
        for i, cc := range lc.Cells {
            cell, err := cc.ToCell()
            if err != nil {
                return nil, fmt.Errorf("invalid cell %s: %w", cc.ID, err)
            }
            cells[i] = cell
        }
    }

    return &types.Layout{
        ID:          lc.ID,
        Name:        lc.Name,
        Description: lc.Description,
        Columns:     columns,
        Rows:        rows,
        Cells:       cells,
        CellModes:   lc.CellModes,
    }, nil
}

// ToCell converts CellConfig to types.Cell
func (cc *CellConfig) ToCell() (types.Cell, error) {
    colStart, colEnd, err := parseSpan(cc.Column)
    if err != nil {
        return types.Cell{}, fmt.Errorf("invalid column span: %w", err)
    }

    rowStart, rowEnd, err := parseSpan(cc.Row)
    if err != nil {
        return types.Cell{}, fmt.Errorf("invalid row span: %w", err)
    }

    return types.Cell{
        ID:          cc.ID,
        ColumnStart: colStart,
        ColumnEnd:   colEnd,
        RowStart:    rowStart,
        RowEnd:      rowEnd,
        StackMode:   cc.StackMode,
    }, nil
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
```

### parser.go

```go
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
```

### validate.go

```go
package config

import (
    "fmt"

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
    if s.CellPadding < 0 {
        return fmt.Errorf("cell padding cannot be negative")
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
```

---

## Example Configuration

### YAML Format (config.yaml)

```yaml
settings:
  defaultStackMode: vertical
  cellPadding: 8
  animationDuration: 0.2
  focusFollowsMouse: false

layouts:
  - id: two-column
    name: Two Column
    description: Equal two-column split
    grid:
      columns: ["1fr", "1fr"]
      rows: ["1fr"]
    cells:
      - id: left
        column: "1/2"
        row: "1/2"
      - id: right
        column: "2/3"
        row: "1/2"

  - id: main-side
    name: Main + Sidebar
    grid:
      columns: ["2fr", "1fr"]
      rows: ["1fr"]
    cells:
      - id: main
        column: "1/2"
        row: "1/2"
      - id: side
        column: "2/3"
        row: "1/2"

  - id: grid-with-areas
    name: Complex Grid
    grid:
      columns: ["1fr", "1fr", "1fr"]
      rows: ["1fr", "2fr"]
    areas:
      - [header, header, header]
      - [main, main, sidebar]

spaces:
  "1":
    name: Main Workspace
    layouts: [two-column, main-side, grid-with-areas]
    defaultLayout: two-column
    autoApply: true

appRules:
  - app: Finder
    float: true
  - app: com.apple.Terminal
    preferredCell: right
  - app: Safari
    preferredCell: main
```

---

## Acceptance Criteria

1. Successfully loads YAML configuration files
2. Successfully loads JSON configuration files
3. Parses all track size formats correctly:
   - `"1fr"`, `"2.5fr"` (fractional)
   - `"300px"`, `"100.5px"` (pixels)
   - `"auto"`
   - `"minmax(200px, 1fr)"`
4. Converts `areas` syntax to cell definitions correctly
5. Validates configuration and returns clear error messages
6. Returns typed `Layout` structs for use by other modules

---

## Test Scenarios

```go
func TestParseTrackSize(t *testing.T) {
    tests := []struct {
        input    string
        expected types.TrackSize
        hasError bool
    }{
        {"1fr", types.TrackSize{Type: types.TrackFr, Value: 1}, false},
        {"2.5fr", types.TrackSize{Type: types.TrackFr, Value: 2.5}, false},
        {"300px", types.TrackSize{Type: types.TrackPx, Value: 300}, false},
        {"auto", types.TrackSize{Type: types.TrackAuto}, false},
        {"minmax(200px, 1fr)", types.TrackSize{Type: types.TrackMinMax, Min: 200, Max: 1}, false},
        {"invalid", types.TrackSize{}, true},
    }
    // ... test implementation
}

func TestAreasToCell(t *testing.T) {
    areas := [][]string{
        {"main", "main", "side"},
        {"main", "main", "side"},
    }
    cells := AreasToCell(areas)
    // Expect: main (col 1-2, row 1-2), side (col 3, row 1-2)
}

func TestLoadConfig(t *testing.T) {
    // Test with valid YAML
    // Test with valid JSON
    // Test with missing file
    // Test with invalid format
}

func TestValidation(t *testing.T) {
    // Test duplicate layout IDs
    // Test missing required fields
    // Test invalid track sizes
    // Test non-rectangular areas
}
```

---

## Notes for Implementing Agent

1. Use `gopkg.in/yaml.v3` for YAML parsing
2. The configuration types in `types.go` have both `yaml` and `json` struct tags
3. Error messages should be descriptive and include context (layout ID, cell ID, etc.)
4. The `ToLayout()` method bridges config types to internal types
5. Run `go build ./...` after implementation to verify compilation
6. Consider creating a `config init` command that generates a default config file
