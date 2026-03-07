package config

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/ryanthedev/grid-cli/internal/types"
)

func TestParseTrackSize(t *testing.T) {
	tests := []struct {
		input    string
		expected types.TrackSize
		hasError bool
	}{
		{"1fr", types.TrackSize{Type: types.TrackFr, Value: 1}, false},
		{"2fr", types.TrackSize{Type: types.TrackFr, Value: 2}, false},
		{"2.5fr", types.TrackSize{Type: types.TrackFr, Value: 2.5}, false},
		{"300px", types.TrackSize{Type: types.TrackPx, Value: 300}, false},
		{"100.5px", types.TrackSize{Type: types.TrackPx, Value: 100.5}, false},
		{"auto", types.TrackSize{Type: types.TrackAuto}, false},
		{"minmax(200px, 1fr)", types.TrackSize{Type: types.TrackMinMax, Min: 200, Max: 1}, false},
		{"minmax(100px, 2fr)", types.TrackSize{Type: types.TrackMinMax, Min: 100, Max: 2}, false},
		{"  1fr  ", types.TrackSize{Type: types.TrackFr, Value: 1}, false}, // whitespace
		{"invalid", types.TrackSize{}, true},
		{"", types.TrackSize{}, true},
		{"10", types.TrackSize{}, true},
		{"px", types.TrackSize{}, true},
		{"fr", types.TrackSize{}, true},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			got, err := ParseTrackSize(tt.input)
			if tt.hasError {
				if err == nil {
					t.Errorf("ParseTrackSize(%q) expected error, got nil", tt.input)
				}
				return
			}
			if err != nil {
				t.Errorf("ParseTrackSize(%q) unexpected error: %v", tt.input, err)
				return
			}
			if got.Type != tt.expected.Type {
				t.Errorf("ParseTrackSize(%q).Type = %v, want %v", tt.input, got.Type, tt.expected.Type)
			}
			if got.Value != tt.expected.Value {
				t.Errorf("ParseTrackSize(%q).Value = %v, want %v", tt.input, got.Value, tt.expected.Value)
			}
			if got.Min != tt.expected.Min {
				t.Errorf("ParseTrackSize(%q).Min = %v, want %v", tt.input, got.Min, tt.expected.Min)
			}
			if got.Max != tt.expected.Max {
				t.Errorf("ParseTrackSize(%q).Max = %v, want %v", tt.input, got.Max, tt.expected.Max)
			}
		})
	}
}

func TestFormatTrackSize(t *testing.T) {
	tests := []struct {
		input    types.TrackSize
		expected string
	}{
		{types.TrackSize{Type: types.TrackFr, Value: 1}, "1fr"},
		{types.TrackSize{Type: types.TrackFr, Value: 2.5}, "2.50fr"},
		{types.TrackSize{Type: types.TrackPx, Value: 300}, "300px"},
		{types.TrackSize{Type: types.TrackPx, Value: 100.5}, "100.50px"},
		{types.TrackSize{Type: types.TrackAuto}, "auto"},
		{types.TrackSize{Type: types.TrackMinMax, Min: 200, Max: 1}, "minmax(200px, 1fr)"},
	}

	for _, tt := range tests {
		t.Run(tt.expected, func(t *testing.T) {
			got := FormatTrackSize(tt.input)
			if got != tt.expected {
				t.Errorf("FormatTrackSize(%+v) = %q, want %q", tt.input, got, tt.expected)
			}
		})
	}
}

func TestAreasToCell(t *testing.T) {
	tests := []struct {
		name     string
		areas    [][]string
		expected []types.Cell
	}{
		{
			name: "simple two column",
			areas: [][]string{
				{"left", "right"},
			},
			expected: []types.Cell{
				{ID: "left", ColumnStart: 1, ColumnEnd: 2, RowStart: 1, RowEnd: 2},
				{ID: "right", ColumnStart: 2, ColumnEnd: 3, RowStart: 1, RowEnd: 2},
			},
		},
		{
			name: "spanning cells",
			areas: [][]string{
				{"main", "main", "side"},
				{"main", "main", "side"},
			},
			expected: []types.Cell{
				{ID: "main", ColumnStart: 1, ColumnEnd: 3, RowStart: 1, RowEnd: 3},
				{ID: "side", ColumnStart: 3, ColumnEnd: 4, RowStart: 1, RowEnd: 3},
			},
		},
		{
			name: "complex layout",
			areas: [][]string{
				{"header", "header", "header"},
				{"main", "main", "sidebar"},
				{"footer", "footer", "footer"},
			},
			expected: []types.Cell{
				{ID: "header", ColumnStart: 1, ColumnEnd: 4, RowStart: 1, RowEnd: 2},
				{ID: "main", ColumnStart: 1, ColumnEnd: 3, RowStart: 2, RowEnd: 3},
				{ID: "sidebar", ColumnStart: 3, ColumnEnd: 4, RowStart: 2, RowEnd: 3},
				{ID: "footer", ColumnStart: 1, ColumnEnd: 4, RowStart: 3, RowEnd: 4},
			},
		},
		{
			name: "with empty cells",
			areas: [][]string{
				{"a", ".", "b"},
			},
			expected: []types.Cell{
				{ID: "a", ColumnStart: 1, ColumnEnd: 2, RowStart: 1, RowEnd: 2},
				{ID: "b", ColumnStart: 3, ColumnEnd: 4, RowStart: 1, RowEnd: 2},
			},
		},
		{
			name:     "empty areas",
			areas:    [][]string{},
			expected: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := AreasToCell(tt.areas)
			if len(got) != len(tt.expected) {
				t.Errorf("AreasToCell() returned %d cells, want %d", len(got), len(tt.expected))
				return
			}
			for i, cell := range got {
				exp := tt.expected[i]
				if cell.ID != exp.ID {
					t.Errorf("cell[%d].ID = %q, want %q", i, cell.ID, exp.ID)
				}
				if cell.ColumnStart != exp.ColumnStart || cell.ColumnEnd != exp.ColumnEnd {
					t.Errorf("cell[%d] columns = %d/%d, want %d/%d", i, cell.ColumnStart, cell.ColumnEnd, exp.ColumnStart, exp.ColumnEnd)
				}
				if cell.RowStart != exp.RowStart || cell.RowEnd != exp.RowEnd {
					t.Errorf("cell[%d] rows = %d/%d, want %d/%d", i, cell.RowStart, cell.RowEnd, exp.RowStart, exp.RowEnd)
				}
			}
		})
	}
}

func TestLoadConfigFromBytes_YAML(t *testing.T) {
	yamlConfig := `
settings:
  defaultStackMode: vertical
  baseSpacing: 8

layouts:
  - id: two-column
    name: Two Column
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
`
	cfg, err := LoadConfigFromBytes([]byte(yamlConfig), "yaml")
	if err != nil {
		t.Fatalf("LoadConfigFromBytes() error: %v", err)
	}

	if cfg.Settings.DefaultStackMode != types.StackVertical {
		t.Errorf("Settings.DefaultStackMode = %q, want %q", cfg.Settings.DefaultStackMode, types.StackVertical)
	}
	if cfg.Settings.BaseSpacing != 8 {
		t.Errorf("Settings.BaseSpacing = %f, want 8", cfg.Settings.BaseSpacing)
	}
	if len(cfg.Layouts) != 1 {
		t.Errorf("len(Layouts) = %d, want 1", len(cfg.Layouts))
	}
	if cfg.Layouts[0].ID != "two-column" {
		t.Errorf("Layouts[0].ID = %q, want %q", cfg.Layouts[0].ID, "two-column")
	}
}

func TestLoadConfigFromBytes_JSON(t *testing.T) {
	jsonConfig := `{
  "settings": {
    "defaultStackMode": "horizontal",
    "cellPadding": 10
  },
  "layouts": [
    {
      "id": "single",
      "name": "Single",
      "grid": {
        "columns": ["1fr"],
        "rows": ["1fr"]
      },
      "cells": [
        {"id": "main", "column": "1/2", "row": "1/2"}
      ]
    }
  ]
}`
	cfg, err := LoadConfigFromBytes([]byte(jsonConfig), "json")
	if err != nil {
		t.Fatalf("LoadConfigFromBytes() error: %v", err)
	}

	if cfg.Settings.DefaultStackMode != types.StackHorizontal {
		t.Errorf("Settings.DefaultStackMode = %q, want %q", cfg.Settings.DefaultStackMode, types.StackHorizontal)
	}
	if len(cfg.Layouts) != 1 {
		t.Errorf("len(Layouts) = %d, want 1", len(cfg.Layouts))
	}
}

func TestLayoutConfigToLayout(t *testing.T) {
	lc := LayoutConfig{
		ID:   "test",
		Name: "Test Layout",
		Grid: GridConfig{
			Columns: []string{"1fr", "2fr"},
			Rows:    []string{"300px", "1fr"},
		},
		Cells: []CellConfig{
			{ID: "a", Column: "1/2", Row: "1/3"},
			{ID: "b", Column: "2/3", Row: "1/2"},
			{ID: "c", Column: "2/3", Row: "2/3"},
		},
	}

	layout, err := lc.ToLayout()
	if err != nil {
		t.Fatalf("ToLayout() error: %v", err)
	}

	if layout.ID != "test" {
		t.Errorf("ID = %q, want %q", layout.ID, "test")
	}
	if len(layout.Columns) != 2 {
		t.Errorf("len(Columns) = %d, want 2", len(layout.Columns))
	}
	if layout.Columns[0].Type != types.TrackFr || layout.Columns[0].Value != 1 {
		t.Errorf("Columns[0] = %+v, want fr:1", layout.Columns[0])
	}
	if layout.Columns[1].Type != types.TrackFr || layout.Columns[1].Value != 2 {
		t.Errorf("Columns[1] = %+v, want fr:2", layout.Columns[1])
	}
	if len(layout.Rows) != 2 {
		t.Errorf("len(Rows) = %d, want 2", len(layout.Rows))
	}
	if layout.Rows[0].Type != types.TrackPx || layout.Rows[0].Value != 300 {
		t.Errorf("Rows[0] = %+v, want px:300", layout.Rows[0])
	}
	if len(layout.Cells) != 3 {
		t.Errorf("len(Cells) = %d, want 3", len(layout.Cells))
	}
}

func TestValidation_DuplicateLayoutID(t *testing.T) {
	cfg := Config{
		Layouts: []LayoutConfig{
			{ID: "dup", Name: "First", Grid: GridConfig{Columns: []string{"1fr"}, Rows: []string{"1fr"}}, Cells: []CellConfig{{ID: "a", Column: "1/2", Row: "1/2"}}},
			{ID: "dup", Name: "Second", Grid: GridConfig{Columns: []string{"1fr"}, Rows: []string{"1fr"}}, Cells: []CellConfig{{ID: "a", Column: "1/2", Row: "1/2"}}},
		},
	}
	err := cfg.Validate()
	if err == nil {
		t.Error("expected error for duplicate layout ID")
	}
}

func TestValidation_MissingCellsAndAreas(t *testing.T) {
	cfg := Config{
		Layouts: []LayoutConfig{
			{ID: "no-cells", Name: "No Cells", Grid: GridConfig{Columns: []string{"1fr"}, Rows: []string{"1fr"}}},
		},
	}
	err := cfg.Validate()
	if err == nil {
		t.Error("expected error for layout without cells or areas")
	}
}

func TestValidation_NonRectangularArea(t *testing.T) {
	cfg := Config{
		Layouts: []LayoutConfig{
			{
				ID:   "bad-area",
				Name: "Bad Area",
				Grid: GridConfig{Columns: []string{"1fr", "1fr", "1fr"}, Rows: []string{"1fr", "1fr"}},
				Areas: [][]string{
					{"a", "a", "b"},
					{"a", "b", "b"}, // "a" is L-shaped, not rectangular
				},
			},
		},
	}
	err := cfg.Validate()
	if err == nil {
		t.Error("expected error for non-rectangular area")
	}
}

func TestValidation_InvalidTrackSize(t *testing.T) {
	cfg := Config{
		Layouts: []LayoutConfig{
			{
				ID:   "bad-track",
				Name: "Bad Track",
				Grid: GridConfig{Columns: []string{"invalid"}, Rows: []string{"1fr"}},
				Cells: []CellConfig{{ID: "a", Column: "1/2", Row: "1/2"}},
			},
		},
	}
	err := cfg.Validate()
	if err == nil {
		t.Error("expected error for invalid track size")
	}
}

func TestValidation_CellOutOfBounds(t *testing.T) {
	cfg := Config{
		Layouts: []LayoutConfig{
			{
				ID:   "oob",
				Name: "Out of Bounds",
				Grid: GridConfig{Columns: []string{"1fr"}, Rows: []string{"1fr"}},
				Cells: []CellConfig{{ID: "a", Column: "1/5", Row: "1/2"}}, // column 5 exceeds grid
			},
		},
	}
	err := cfg.Validate()
	if err == nil {
		t.Error("expected error for cell out of bounds")
	}
}

func TestValidation_AreasDimensionMismatch(t *testing.T) {
	cfg := Config{
		Layouts: []LayoutConfig{
			{
				ID:   "mismatch",
				Name: "Mismatch",
				Grid: GridConfig{Columns: []string{"1fr", "1fr"}, Rows: []string{"1fr"}},
				Areas: [][]string{
					{"a", "b", "c"}, // 3 columns but grid has 2
				},
			},
		},
	}
	err := cfg.Validate()
	if err == nil {
		t.Error("expected error for areas dimension mismatch")
	}
}

func TestGetLayout(t *testing.T) {
	cfg := Config{
		Layouts: []LayoutConfig{
			{ID: "first", Name: "First", Grid: GridConfig{Columns: []string{"1fr"}, Rows: []string{"1fr"}}, Cells: []CellConfig{{ID: "a", Column: "1/2", Row: "1/2"}}},
			{ID: "second", Name: "Second", Grid: GridConfig{Columns: []string{"1fr", "1fr"}, Rows: []string{"1fr"}}, Cells: []CellConfig{{ID: "a", Column: "1/2", Row: "1/2"}, {ID: "b", Column: "2/3", Row: "1/2"}}},
		},
	}

	layout, err := cfg.GetLayout("second")
	if err != nil {
		t.Fatalf("GetLayout() error: %v", err)
	}
	if layout.Name != "Second" {
		t.Errorf("layout.Name = %q, want %q", layout.Name, "Second")
	}

	_, err = cfg.GetLayout("nonexistent")
	if err == nil {
		t.Error("expected error for nonexistent layout")
	}
}

func TestGetLayoutWithOverrides(t *testing.T) {
	cfg := Config{
		Layouts: []LayoutConfig{
			{
				ID:   "3col",
				Name: "Three Column",
				Grid: GridConfig{
					Columns: []string{"1fr", "1fr", "1fr"},
					Rows:    []string{"1fr"},
				},
				Cells: []CellConfig{
					{ID: "left", Column: "1/2", Row: "1/2"},
					{ID: "center", Column: "2/3", Row: "1/2"},
					{ID: "right", Column: "3/4", Row: "1/2"},
				},
				CellModes: map[string]types.StackMode{
					"left": types.StackVertical,
				},
			},
		},
		LayoutOverrides: map[string]LayoutOverrideConfig{
			"3col": {
				Grid: &GridConfig{
					Columns: []string{"1fr", "3fr", "1fr"},
				},
				CellModes: map[string]types.StackMode{
					"center": types.StackTabs,
				},
			},
		},
	}

	layout, err := cfg.GetLayout("3col")
	if err != nil {
		t.Fatalf("GetLayout() error: %v", err)
	}

	// Columns should be overridden
	if len(layout.Columns) != 3 {
		t.Fatalf("expected 3 columns, got %d", len(layout.Columns))
	}
	if layout.Columns[1].Value != 3 {
		t.Errorf("expected column[1] fr=3, got %v", layout.Columns[1].Value)
	}

	// Rows should remain unchanged (not in override)
	if len(layout.Rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(layout.Rows))
	}

	// CellModes should merge: left from base, center from override
	if layout.CellModes["left"] != types.StackVertical {
		t.Errorf("expected left=vertical, got %s", layout.CellModes["left"])
	}
	if layout.CellModes["center"] != types.StackTabs {
		t.Errorf("expected center=tabs, got %s", layout.CellModes["center"])
	}
}

func TestGetLayoutWithOverrides_DoesNotMutateOriginal(t *testing.T) {
	cfg := Config{
		Layouts: []LayoutConfig{
			{
				ID:   "test",
				Name: "Test",
				Grid: GridConfig{
					Columns: []string{"1fr", "1fr"},
					Rows:    []string{"1fr"},
				},
				Cells: []CellConfig{
					{ID: "left", Column: "1/2", Row: "1/2"},
					{ID: "right", Column: "2/3", Row: "1/2"},
				},
			},
		},
		LayoutOverrides: map[string]LayoutOverrideConfig{
			"test": {
				Grid: &GridConfig{
					Columns: []string{"2fr", "1fr"},
				},
				CellModes: map[string]types.StackMode{
					"left": types.StackTabs,
				},
			},
		},
	}

	// Call GetLayout twice
	_, _ = cfg.GetLayout("test")
	_, _ = cfg.GetLayout("test")

	// Original LayoutConfig must be unchanged
	if cfg.Layouts[0].Grid.Columns[0] != "1fr" || cfg.Layouts[0].Grid.Columns[1] != "1fr" {
		t.Errorf("original columns mutated: %v", cfg.Layouts[0].Grid.Columns)
	}
	if cfg.Layouts[0].CellModes != nil {
		t.Errorf("original CellModes mutated: %v", cfg.Layouts[0].CellModes)
	}
}

func TestGetLayoutWithoutOverrides(t *testing.T) {
	cfg := Config{
		Layouts: []LayoutConfig{
			{
				ID:   "simple",
				Name: "Simple",
				Grid: GridConfig{
					Columns: []string{"1fr", "1fr"},
					Rows:    []string{"1fr"},
				},
				Cells: []CellConfig{
					{ID: "left", Column: "1/2", Row: "1/2"},
					{ID: "right", Column: "2/3", Row: "1/2"},
				},
			},
		},
	}

	layout, err := cfg.GetLayout("simple")
	if err != nil {
		t.Fatalf("GetLayout() error: %v", err)
	}

	// Should return base layout unchanged
	if len(layout.Columns) != 2 {
		t.Fatalf("expected 2 columns, got %d", len(layout.Columns))
	}
	if layout.Columns[0].Value != 1 || layout.Columns[1].Value != 1 {
		t.Errorf("expected equal columns, got %v and %v", layout.Columns[0].Value, layout.Columns[1].Value)
	}
}

func TestGetLayoutIDs(t *testing.T) {
	cfg := Config{
		Layouts: []LayoutConfig{
			{ID: "a"},
			{ID: "b"},
			{ID: "c"},
		},
	}

	ids := cfg.GetLayoutIDs()
	if len(ids) != 3 {
		t.Errorf("len(ids) = %d, want 3", len(ids))
	}
	expected := []string{"a", "b", "c"}
	for i, id := range ids {
		if id != expected[i] {
			t.Errorf("ids[%d] = %q, want %q", i, id, expected[i])
		}
	}
}

func TestIsRectangular(t *testing.T) {
	tests := []struct {
		name      string
		positions [][2]int
		want      bool
	}{
		{
			name:      "single cell",
			positions: [][2]int{{0, 0}},
			want:      true,
		},
		{
			name:      "2x2 square",
			positions: [][2]int{{0, 0}, {0, 1}, {1, 0}, {1, 1}},
			want:      true,
		},
		{
			name:      "1x3 row",
			positions: [][2]int{{0, 0}, {0, 1}, {0, 2}},
			want:      true,
		},
		{
			name:      "L-shape",
			positions: [][2]int{{0, 0}, {0, 1}, {1, 0}},
			want:      false,
		},
		{
			name:      "empty",
			positions: [][2]int{},
			want:      false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isRectangular(tt.positions); got != tt.want {
				t.Errorf("isRectangular() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestWindowExclusionConfig(t *testing.T) {
	yaml := `
settings:
  defaultStackMode: vertical
  windowExclusion:
    roles:
      - AXHelpTag
    subroles:
      - AXUnknown
    apps:
      - Dock
layouts:
  - id: test
    grid:
      columns: ["1fr"]
      rows: ["1fr"]
    cells:
      - id: main
        column: "1/2"
        row: "1/2"
`
	cfg, err := LoadConfigFromBytes([]byte(yaml), "yaml")
	if err != nil {
		t.Fatalf("failed to load config: %v", err)
	}

	if len(cfg.Settings.WindowExclusion.Roles) != 1 || cfg.Settings.WindowExclusion.Roles[0] != "AXHelpTag" {
		t.Errorf("expected roles [AXHelpTag], got %v", cfg.Settings.WindowExclusion.Roles)
	}
	if len(cfg.Settings.WindowExclusion.Subroles) != 1 || cfg.Settings.WindowExclusion.Subroles[0] != "AXUnknown" {
		t.Errorf("expected subroles [AXUnknown], got %v", cfg.Settings.WindowExclusion.Subroles)
	}
	if len(cfg.Settings.WindowExclusion.Apps) != 1 || cfg.Settings.WindowExclusion.Apps[0] != "Dock" {
		t.Errorf("expected apps [Dock], got %v", cfg.Settings.WindowExclusion.Apps)
	}
}

func TestDefaultWindowExclusions(t *testing.T) {
	// Config with NO windowExclusion specified
	yaml := `
settings:
  defaultStackMode: vertical
layouts:
  - id: test
    grid:
      columns: ["1fr"]
      rows: ["1fr"]
    cells:
      - id: main
        column: "1/2"
        row: "1/2"
`
	cfg, err := LoadConfigFromBytes([]byte(yaml), "yaml")
	if err != nil {
		t.Fatalf("failed to load config: %v", err)
	}

	exclusions := cfg.GetWindowExclusions()

	// Should have sensible defaults
	if !containsString(exclusions.Roles, "AXHelpTag") {
		t.Error("expected default roles to include AXHelpTag")
	}
}

func TestLoadLayeredConfig(t *testing.T) {
	// Create temp directory
	tmpDir := t.TempDir()

	// Create base config
	baseConfig := `
settings:
  baseSpacing: 8
  defaultStackMode: vertical
layouts:
  - id: main
    name: Main Layout
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
`
	basePath := filepath.Join(tmpDir, "config.yaml")
	if err := os.WriteFile(basePath, []byte(baseConfig), 0644); err != nil {
		t.Fatal(err)
	}

	// Create local override
	localConfig := `
settings:
  baseSpacing: 16
`
	localPath := filepath.Join(tmpDir, "config.local.yaml")
	if err := os.WriteFile(localPath, []byte(localConfig), 0644); err != nil {
		t.Fatal(err)
	}

	// Load config with explicit path - should NOT apply local layering
	cfg, err := LoadConfig(basePath)
	if err != nil {
		t.Fatalf("LoadConfig failed: %v", err)
	}

	// With explicit path, local override is NOT applied
	if cfg.Settings.BaseSpacing != 8 {
		t.Errorf("Expected BaseSpacing=8 (no layering with explicit path), got %v", cfg.Settings.BaseSpacing)
	}

	// Verify base values preserved
	if len(cfg.Layouts) != 1 {
		t.Errorf("Expected 1 layout, got %d", len(cfg.Layouts))
	}
}

func TestLoadConfigWithoutLocal(t *testing.T) {
	// Create temp directory
	tmpDir := t.TempDir()

	// Create base config only (no local)
	baseConfig := `
settings:
  baseSpacing: 8
layouts:
  - id: main
    name: Main Layout
    grid:
      columns: ["1fr"]
      rows: ["1fr"]
    cells:
      - id: full
        column: "1/2"
        row: "1/2"
`
	basePath := filepath.Join(tmpDir, "config.yaml")
	if err := os.WriteFile(basePath, []byte(baseConfig), 0644); err != nil {
		t.Fatal(err)
	}

	// Load config - should work without local file
	cfg, err := LoadConfig(basePath)
	if err != nil {
		t.Fatalf("LoadConfig failed: %v", err)
	}

	if cfg.Settings.BaseSpacing != 8 {
		t.Errorf("Expected BaseSpacing=8, got %v", cfg.Settings.BaseSpacing)
	}
}

func TestExpandTilde(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatalf("Failed to get home dir: %v", err)
	}

	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "bare tilde",
			input:    "~",
			expected: home,
		},
		{
			name:     "tilde with path",
			input:    "~/foo/bar",
			expected: filepath.Join(home, "foo/bar"),
		},
		{
			name:     "absolute path",
			input:    "/absolute/path",
			expected: "/absolute/path",
		},
		{
			name:     "relative path",
			input:    "relative/path",
			expected: "relative/path",
		},
		{
			name:     "empty string",
			input:    "",
			expected: "",
		},
		{
			name:     "tilde in middle",
			input:    "/path/~/foo",
			expected: "/path/~/foo",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ExpandTilde(tt.input)
			if got != tt.expected {
				t.Errorf("ExpandTilde(%q) = %q, want %q", tt.input, got, tt.expected)
			}
		})
	}
}

func TestExpandPaths(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatalf("Failed to get home dir: %v", err)
	}

	cfg := &Config{
		Settings: Settings{
			Recording: RecordingSettings{
				OutputDir: "~/recordings",
			},
		},
		Picker: &PickerConfig{
			Sources: SourcesConfig{
				ZoxidePath: "~/bin/zoxide",
				Chrome: ChromeConfig{
					StateFile: "~/chrome-state.json",
				},
			},
		},
	}

	cfg.ExpandPaths()

	if cfg.Settings.Recording.OutputDir != filepath.Join(home, "recordings") {
		t.Errorf("OutputDir not expanded: %q", cfg.Settings.Recording.OutputDir)
	}
	if cfg.Picker.Sources.ZoxidePath != filepath.Join(home, "bin/zoxide") {
		t.Errorf("ZoxidePath not expanded: %q", cfg.Picker.Sources.ZoxidePath)
	}
	if cfg.Picker.Sources.Chrome.StateFile != filepath.Join(home, "chrome-state.json") {
		t.Errorf("StateFile not expanded: %q", cfg.Picker.Sources.Chrome.StateFile)
	}
}
