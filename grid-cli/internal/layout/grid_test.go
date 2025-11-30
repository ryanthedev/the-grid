package layout

import (
	"math"
	"testing"

	"github.com/yourusername/grid-cli/internal/types"
)

func TestCalculateTracks_Simple(t *testing.T) {
	tracks := []types.TrackSize{
		{Type: types.TrackFr, Value: 1},
		{Type: types.TrackFr, Value: 1},
	}
	sizes := CalculateTracks(tracks, 1000, 0)

	if len(sizes) != 2 {
		t.Fatalf("expected 2 sizes, got %d", len(sizes))
	}
	if sizes[0] != 500 || sizes[1] != 500 {
		t.Errorf("expected [500, 500], got [%v, %v]", sizes[0], sizes[1])
	}
}

func TestCalculateTracks_Mixed(t *testing.T) {
	tracks := []types.TrackSize{
		{Type: types.TrackPx, Value: 200},
		{Type: types.TrackFr, Value: 1},
		{Type: types.TrackFr, Value: 2},
	}
	sizes := CalculateTracks(tracks, 1000, 0)

	if len(sizes) != 3 {
		t.Fatalf("expected 3 sizes, got %d", len(sizes))
	}
	// 200px fixed, remaining 800 split 1:2 = 266.67, 533.33
	if sizes[0] != 200 {
		t.Errorf("sizes[0] = %v, want 200", sizes[0])
	}
	if !floatEquals(sizes[1], 266.67, 0.01) {
		t.Errorf("sizes[1] = %v, want ~266.67", sizes[1])
	}
	if !floatEquals(sizes[2], 533.33, 0.01) {
		t.Errorf("sizes[2] = %v, want ~533.33", sizes[2])
	}
}

func TestCalculateTracks_WithGaps(t *testing.T) {
	tracks := []types.TrackSize{
		{Type: types.TrackFr, Value: 1},
		{Type: types.TrackFr, Value: 1},
	}
	sizes := CalculateTracks(tracks, 1000, 10)

	// Available = 1000 - 10 = 990, split equally
	if len(sizes) != 2 {
		t.Fatalf("expected 2 sizes, got %d", len(sizes))
	}
	if sizes[0] != 495 || sizes[1] != 495 {
		t.Errorf("expected [495, 495], got [%v, %v]", sizes[0], sizes[1])
	}
}

func TestCalculateTracks_ThreeColumnsWithGaps(t *testing.T) {
	// Example from spec: 3000px, ["300px", "1fr", "2fr"], gap 10px
	tracks := []types.TrackSize{
		{Type: types.TrackPx, Value: 300},
		{Type: types.TrackFr, Value: 1},
		{Type: types.TrackFr, Value: 2},
	}
	sizes := CalculateTracks(tracks, 3000, 10)

	// Available = 3000 - 20 = 2980
	// After 300px: 2680 remaining
	// 1fr = 2680/3 = 893.33, 2fr = 1786.67
	if len(sizes) != 3 {
		t.Fatalf("expected 3 sizes, got %d", len(sizes))
	}
	if sizes[0] != 300 {
		t.Errorf("sizes[0] = %v, want 300", sizes[0])
	}
	if !floatEquals(sizes[1], 893.33, 0.01) {
		t.Errorf("sizes[1] = %v, want ~893.33", sizes[1])
	}
	if !floatEquals(sizes[2], 1786.67, 0.01) {
		t.Errorf("sizes[2] = %v, want ~1786.67", sizes[2])
	}
}

func TestCalculateTracks_MinMax(t *testing.T) {
	tracks := []types.TrackSize{
		{Type: types.TrackMinMax, Min: 200, Max: 1}, // minmax(200px, 1fr)
		{Type: types.TrackFr, Value: 1},
	}
	sizes := CalculateTracks(tracks, 1000, 0)

	// Available = 1000
	// Min 200px allocated first, remaining = 800
	// Total fr = 2 (1 from minmax max, 1 from second track)
	// fr unit = 800/2 = 400
	// First track: 200 + 400 = 600
	// Second track: 400
	if len(sizes) != 2 {
		t.Fatalf("expected 2 sizes, got %d", len(sizes))
	}
	if sizes[0] != 600 {
		t.Errorf("sizes[0] = %v, want 600", sizes[0])
	}
	if sizes[1] != 400 {
		t.Errorf("sizes[1] = %v, want 400", sizes[1])
	}
}

func TestCalculateTracks_SingleTrack(t *testing.T) {
	tracks := []types.TrackSize{
		{Type: types.TrackFr, Value: 1},
	}
	sizes := CalculateTracks(tracks, 1000, 0)

	if len(sizes) != 1 {
		t.Fatalf("expected 1 size, got %d", len(sizes))
	}
	if sizes[0] != 1000 {
		t.Errorf("expected 1000, got %v", sizes[0])
	}
}

func TestCalculateTracks_Empty(t *testing.T) {
	sizes := CalculateTracks(nil, 1000, 0)
	if sizes != nil {
		t.Errorf("expected nil for empty tracks, got %v", sizes)
	}

	sizes = CalculateTracks([]types.TrackSize{}, 1000, 0)
	if sizes != nil {
		t.Errorf("expected nil for empty tracks, got %v", sizes)
	}
}

func TestCalculateTracks_Auto(t *testing.T) {
	tracks := []types.TrackSize{
		{Type: types.TrackAuto},
		{Type: types.TrackFr, Value: 1},
	}
	sizes := CalculateTracks(tracks, 1000, 0)

	// Auto gets 0, fr gets all
	if len(sizes) != 2 {
		t.Fatalf("expected 2 sizes, got %d", len(sizes))
	}
	if sizes[0] != 0 {
		t.Errorf("sizes[0] = %v, want 0 (auto)", sizes[0])
	}
	if sizes[1] != 1000 {
		t.Errorf("sizes[1] = %v, want 1000", sizes[1])
	}
}

func TestCalculateTrackPositions(t *testing.T) {
	sizes := []float64{100, 200, 300}
	positions := CalculateTrackPositions(sizes, 10)

	// positions[0] = 0
	// positions[1] = 100 + 10 = 110
	// positions[2] = 110 + 200 + 10 = 320
	// positions[3] = 320 + 300 = 620 (no gap after last)
	expected := []float64{0, 110, 320, 620}
	if len(positions) != len(expected) {
		t.Fatalf("expected %d positions, got %d", len(expected), len(positions))
	}
	for i, exp := range expected {
		if positions[i] != exp {
			t.Errorf("positions[%d] = %v, want %v", i, positions[i], exp)
		}
	}
}

func TestCalculateTrackPositions_NoGap(t *testing.T) {
	sizes := []float64{100, 200, 300}
	positions := CalculateTrackPositions(sizes, 0)

	expected := []float64{0, 100, 300, 600}
	if len(positions) != len(expected) {
		t.Fatalf("expected %d positions, got %d", len(expected), len(positions))
	}
	for i, exp := range expected {
		if positions[i] != exp {
			t.Errorf("positions[%d] = %v, want %v", i, positions[i], exp)
		}
	}
}

func TestCalculateLayout(t *testing.T) {
	layout := &types.Layout{
		ID: "test",
		Columns: []types.TrackSize{
			{Type: types.TrackFr, Value: 1},
			{Type: types.TrackFr, Value: 1},
		},
		Rows: []types.TrackSize{
			{Type: types.TrackFr, Value: 1},
		},
		Cells: []types.Cell{
			{ID: "left", ColumnStart: 1, ColumnEnd: 2, RowStart: 1, RowEnd: 2},
			{ID: "right", ColumnStart: 2, ColumnEnd: 3, RowStart: 1, RowEnd: 2},
		},
	}

	screenRect := types.Rect{X: 100, Y: 50, Width: 1000, Height: 500}
	result := CalculateLayout(layout, screenRect, 10)

	if result == nil {
		t.Fatal("expected non-nil result")
	}
	if result.LayoutID != "test" {
		t.Errorf("LayoutID = %q, want %q", result.LayoutID, "test")
	}

	// Check cell bounds (accounting for screen offset)
	leftBounds, ok := result.CellBounds["left"]
	if !ok {
		t.Fatal("missing 'left' cell bounds")
	}
	// Column widths: (1000 - 10) / 2 = 495 each
	// Left cell: X = 100 (screen offset), Width = 495
	if leftBounds.X != 100 {
		t.Errorf("left.X = %v, want 100", leftBounds.X)
	}
	if leftBounds.Width != 495 {
		t.Errorf("left.Width = %v, want 495", leftBounds.Width)
	}

	rightBounds, ok := result.CellBounds["right"]
	if !ok {
		t.Fatal("missing 'right' cell bounds")
	}
	// Right cell: X = 100 + 495 + 10 = 605
	if rightBounds.X != 605 {
		t.Errorf("right.X = %v, want 605", rightBounds.X)
	}
}

func TestCalculateLayout_Nil(t *testing.T) {
	result := CalculateLayout(nil, types.Rect{}, 0)
	if result != nil {
		t.Error("expected nil for nil layout")
	}
}

// Helper function for float comparison
func floatEquals(a, b, epsilon float64) bool {
	return math.Abs(a-b) < epsilon
}
