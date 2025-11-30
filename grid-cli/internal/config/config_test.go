package config

import (
	"testing"

	"github.com/yourusername/grid-cli/internal/types"
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
  cellPadding: 8

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
	if cfg.Settings.CellPadding != 8 {
		t.Errorf("Settings.CellPadding = %d, want 8", cfg.Settings.CellPadding)
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
