package layout

import (
	"testing"

	"github.com/yourusername/grid-cli/internal/types"
)

func TestCalculateCellBounds_SingleCell(t *testing.T) {
	cell := types.Cell{ID: "main", ColumnStart: 1, ColumnEnd: 2, RowStart: 1, RowEnd: 2}
	colPositions := []float64{0, 500, 1000}
	rowPositions := []float64{0, 500, 1000}
	colSizes := []float64{500, 500}
	rowSizes := []float64{500, 500}

	bounds := CalculateCellBounds(cell, colPositions, rowPositions, colSizes, rowSizes, 0)

	if bounds.X != 0 {
		t.Errorf("X = %v, want 0", bounds.X)
	}
	if bounds.Y != 0 {
		t.Errorf("Y = %v, want 0", bounds.Y)
	}
	if bounds.Width != 500 {
		t.Errorf("Width = %v, want 500", bounds.Width)
	}
	if bounds.Height != 500 {
		t.Errorf("Height = %v, want 500", bounds.Height)
	}
}

func TestCalculateCellBounds_SpanningColumns(t *testing.T) {
	// Cell spans columns 1-2 (indices 0-1)
	cell := types.Cell{ID: "main", ColumnStart: 1, ColumnEnd: 3, RowStart: 1, RowEnd: 2}
	colPositions := []float64{0, 100, 210, 320} // 100px, 110px (100+10 gap), 110px
	rowPositions := []float64{0, 500}
	colSizes := []float64{100, 100, 100}
	rowSizes := []float64{500}
	gap := float64(10)

	bounds := CalculateCellBounds(cell, colPositions, rowPositions, colSizes, rowSizes, gap)

	// Width = col[0] + gap + col[1] = 100 + 10 + 100 = 210
	if bounds.X != 0 {
		t.Errorf("X = %v, want 0", bounds.X)
	}
	if bounds.Width != 210 {
		t.Errorf("Width = %v, want 210", bounds.Width)
	}
}

func TestCalculateCellBounds_SpanningRows(t *testing.T) {
	// Cell spans rows 1-2 (indices 0-1)
	cell := types.Cell{ID: "main", ColumnStart: 1, ColumnEnd: 2, RowStart: 1, RowEnd: 3}
	colPositions := []float64{0, 500}
	rowPositions := []float64{0, 200, 410} // 200px, 210px (200+10 gap)
	colSizes := []float64{500}
	rowSizes := []float64{200, 200}
	gap := float64(10)

	bounds := CalculateCellBounds(cell, colPositions, rowPositions, colSizes, rowSizes, gap)

	// Height = row[0] + gap + row[1] = 200 + 10 + 200 = 410
	if bounds.Y != 0 {
		t.Errorf("Y = %v, want 0", bounds.Y)
	}
	if bounds.Height != 410 {
		t.Errorf("Height = %v, want 410", bounds.Height)
	}
}

func TestCalculateCellBounds_SecondCell(t *testing.T) {
	// Test cell in second column, second row
	cell := types.Cell{ID: "br", ColumnStart: 2, ColumnEnd: 3, RowStart: 2, RowEnd: 3}
	colPositions := []float64{0, 110, 220} // with 10px gap
	rowPositions := []float64{0, 110, 220}
	colSizes := []float64{100, 100}
	rowSizes := []float64{100, 100}
	gap := float64(10)

	bounds := CalculateCellBounds(cell, colPositions, rowPositions, colSizes, rowSizes, gap)

	if bounds.X != 110 {
		t.Errorf("X = %v, want 110", bounds.X)
	}
	if bounds.Y != 110 {
		t.Errorf("Y = %v, want 110", bounds.Y)
	}
	if bounds.Width != 100 {
		t.Errorf("Width = %v, want 100", bounds.Width)
	}
	if bounds.Height != 100 {
		t.Errorf("Height = %v, want 100", bounds.Height)
	}
}

func TestCalculateCellBounds_InvalidBounds(t *testing.T) {
	colPositions := []float64{0, 500}
	rowPositions := []float64{0, 500}
	colSizes := []float64{500}
	rowSizes := []float64{500}

	// Cell out of bounds (column)
	cell := types.Cell{ID: "bad", ColumnStart: 1, ColumnEnd: 3, RowStart: 1, RowEnd: 2}
	bounds := CalculateCellBounds(cell, colPositions, rowPositions, colSizes, rowSizes, 0)
	if bounds.Width != 0 && bounds.Height != 0 {
		t.Error("expected zero rect for out-of-bounds cell")
	}

	// Invalid span (start >= end)
	cell = types.Cell{ID: "bad", ColumnStart: 2, ColumnEnd: 1, RowStart: 1, RowEnd: 2}
	bounds = CalculateCellBounds(cell, colPositions, rowPositions, colSizes, rowSizes, 0)
	if bounds.Width != 0 && bounds.Height != 0 {
		t.Error("expected zero rect for invalid span")
	}
}

func TestGetCellAtPoint(t *testing.T) {
	cellBounds := map[string]types.Rect{
		"left":  {X: 0, Y: 0, Width: 500, Height: 1000},
		"right": {X: 510, Y: 0, Width: 490, Height: 1000},
	}

	tests := []struct {
		point types.Point
		want  string
	}{
		{types.Point{X: 250, Y: 500}, "left"},
		{types.Point{X: 750, Y: 500}, "right"},
		{types.Point{X: 505, Y: 500}, ""}, // In the gap
		{types.Point{X: -10, Y: 500}, ""}, // Outside
	}

	for _, tt := range tests {
		got := GetCellAtPoint(cellBounds, tt.point)
		if got != tt.want {
			t.Errorf("GetCellAtPoint(%v) = %q, want %q", tt.point, got, tt.want)
		}
	}
}

func TestGetAdjacentCells(t *testing.T) {
	// Simple 2x2 grid
	cellBounds := map[string]types.Rect{
		"tl": {X: 0, Y: 0, Width: 100, Height: 100},
		"tr": {X: 110, Y: 0, Width: 100, Height: 100},
		"bl": {X: 0, Y: 110, Width: 100, Height: 100},
		"br": {X: 110, Y: 110, Width: 100, Height: 100},
	}

	// Test from top-left
	adj := GetAdjacentCells("tl", cellBounds)

	// Should have "tr" to the right
	if len(adj[types.DirRight]) != 1 || adj[types.DirRight][0] != "tr" {
		t.Errorf("DirRight = %v, want [tr]", adj[types.DirRight])
	}
	// Should have "bl" below
	if len(adj[types.DirDown]) != 1 || adj[types.DirDown][0] != "bl" {
		t.Errorf("DirDown = %v, want [bl]", adj[types.DirDown])
	}
	// Nothing to left or up
	if len(adj[types.DirLeft]) != 0 {
		t.Errorf("DirLeft = %v, want []", adj[types.DirLeft])
	}
	if len(adj[types.DirUp]) != 0 {
		t.Errorf("DirUp = %v, want []", adj[types.DirUp])
	}
}

func TestGetAdjacentCells_UnknownCell(t *testing.T) {
	cellBounds := map[string]types.Rect{
		"main": {X: 0, Y: 0, Width: 100, Height: 100},
	}

	adj := GetAdjacentCells("unknown", cellBounds)

	// Should return empty maps for all directions
	for _, dir := range []types.Direction{types.DirLeft, types.DirRight, types.DirUp, types.DirDown} {
		if len(adj[dir]) != 0 {
			t.Errorf("expected empty adjacency for unknown cell, got %v for %v", adj[dir], dir)
		}
	}
}

func TestSortCellsByPosition(t *testing.T) {
	cellBounds := map[string]types.Rect{
		"br": {X: 100, Y: 100, Width: 100, Height: 100}, // bottom-right
		"tl": {X: 0, Y: 0, Width: 100, Height: 100},     // top-left
		"tr": {X: 100, Y: 0, Width: 100, Height: 100},   // top-right
		"bl": {X: 0, Y: 100, Width: 100, Height: 100},   // bottom-left
	}

	sorted := SortCellsByPosition(cellBounds)

	// Expected order: top-left, top-right, bottom-left, bottom-right
	expected := []string{"tl", "tr", "bl", "br"}
	if len(sorted) != len(expected) {
		t.Fatalf("expected %d cells, got %d", len(expected), len(sorted))
	}
	for i, exp := range expected {
		if sorted[i] != exp {
			t.Errorf("sorted[%d] = %q, want %q", i, sorted[i], exp)
		}
	}
}

func TestSortCellsByPosition_Empty(t *testing.T) {
	sorted := SortCellsByPosition(map[string]types.Rect{})
	if len(sorted) != 0 {
		t.Errorf("expected empty slice, got %v", sorted)
	}
}

func TestOverlapsVertically(t *testing.T) {
	a := types.Rect{X: 0, Y: 0, Width: 100, Height: 100}

	tests := []struct {
		name string
		b    types.Rect
		want bool
	}{
		{"same", types.Rect{X: 100, Y: 0, Width: 100, Height: 100}, true},
		{"partial overlap", types.Rect{X: 100, Y: 50, Width: 100, Height: 100}, true},
		{"touching", types.Rect{X: 100, Y: 100, Width: 100, Height: 100}, false},
		{"no overlap", types.Rect{X: 100, Y: 200, Width: 100, Height: 100}, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := overlapsVertically(a, tt.b)
			if got != tt.want {
				t.Errorf("overlapsVertically(%v, %v) = %v, want %v", a, tt.b, got, tt.want)
			}
		})
	}
}

func TestOverlapsHorizontally(t *testing.T) {
	a := types.Rect{X: 0, Y: 0, Width: 100, Height: 100}

	tests := []struct {
		name string
		b    types.Rect
		want bool
	}{
		{"same", types.Rect{X: 0, Y: 100, Width: 100, Height: 100}, true},
		{"partial overlap", types.Rect{X: 50, Y: 100, Width: 100, Height: 100}, true},
		{"touching", types.Rect{X: 100, Y: 100, Width: 100, Height: 100}, false},
		{"no overlap", types.Rect{X: 200, Y: 100, Width: 100, Height: 100}, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := overlapsHorizontally(a, tt.b)
			if got != tt.want {
				t.Errorf("overlapsHorizontally(%v, %v) = %v, want %v", a, tt.b, got, tt.want)
			}
		})
	}
}
