package focus

import (
	"testing"

	"github.com/yourusername/grid-cli/internal/types"
)

// Test grid layout:
// +--------+--------+
// |  left  | right  |
// +--------+--------+
// | bottom | bottom |
// +--------+--------+
func makeTestGrid() map[string]types.Rect {
	return map[string]types.Rect{
		"left": {
			X:      0,
			Y:      0,
			Width:  500,
			Height: 400,
		},
		"right": {
			X:      500,
			Y:      0,
			Width:  500,
			Height: 400,
		},
		"bottom": {
			X:      0,
			Y:      400,
			Width:  1000,
			Height: 400,
		},
	}
}

// Test 2x2 grid:
// +--------+--------+
// |   tl   |   tr   |
// +--------+--------+
// |   bl   |   br   |
// +--------+--------+
func make2x2Grid() map[string]types.Rect {
	return map[string]types.Rect{
		"tl": {X: 0, Y: 0, Width: 500, Height: 400},
		"tr": {X: 500, Y: 0, Width: 500, Height: 400},
		"bl": {X: 0, Y: 400, Width: 500, Height: 400},
		"br": {X: 500, Y: 400, Width: 500, Height: 400},
	}
}

func TestFindTargetCell_Right(t *testing.T) {
	grid := makeTestGrid()

	target, found := FindTargetCell("left", types.DirRight, grid, false)
	if !found {
		t.Fatal("expected to find cell to the right")
	}
	if target != "right" {
		t.Errorf("expected 'right', got '%s'", target)
	}
}

func TestFindTargetCell_Left(t *testing.T) {
	grid := makeTestGrid()

	target, found := FindTargetCell("right", types.DirLeft, grid, false)
	if !found {
		t.Fatal("expected to find cell to the left")
	}
	if target != "left" {
		t.Errorf("expected 'left', got '%s'", target)
	}
}

func TestFindTargetCell_Down(t *testing.T) {
	grid := makeTestGrid()

	target, found := FindTargetCell("left", types.DirDown, grid, false)
	if !found {
		t.Fatal("expected to find cell below")
	}
	if target != "bottom" {
		t.Errorf("expected 'bottom', got '%s'", target)
	}
}

func TestFindTargetCell_Up(t *testing.T) {
	grid := makeTestGrid()

	target, found := FindTargetCell("bottom", types.DirUp, grid, false)
	if !found {
		t.Fatal("expected to find cell above")
	}
	// Should prefer left since bottom center is at x=500 (middle) and left center is at x=250
	// Actually the center of bottom is at (500, 600), left center is (250, 200), right center is (750, 200)
	// Distance to left: dy = 400 (primary), dx = 250 (perpendicular) = 400 + 250*2 = 900
	// Distance to right: dy = 400 (primary), dx = 250 (perpendicular) = 400 + 250*2 = 900
	// They're equal! The algorithm might pick either one based on map iteration order
	if target != "left" && target != "right" {
		t.Errorf("expected 'left' or 'right', got '%s'", target)
	}
}

func TestFindTargetCell_NoCell(t *testing.T) {
	grid := makeTestGrid()

	// No cell to the left of 'left'
	_, found := FindTargetCell("left", types.DirLeft, grid, false)
	if found {
		t.Error("expected no cell to the left")
	}
}

func TestFindTargetCell_WrapAround_Right(t *testing.T) {
	grid := make2x2Grid()

	// Going right from tr should wrap to tl
	target, found := FindTargetCell("tr", types.DirRight, grid, true)
	if !found {
		t.Fatal("expected wrap-around to work")
	}
	if target != "tl" {
		t.Errorf("expected 'tl' (wrap around), got '%s'", target)
	}
}

func TestFindTargetCell_WrapAround_Left(t *testing.T) {
	grid := make2x2Grid()

	// Going left from tl should wrap to tr
	target, found := FindTargetCell("tl", types.DirLeft, grid, true)
	if !found {
		t.Fatal("expected wrap-around to work")
	}
	if target != "tr" {
		t.Errorf("expected 'tr' (wrap around), got '%s'", target)
	}
}

func TestFindTargetCell_WrapAround_Down(t *testing.T) {
	grid := make2x2Grid()

	// Going down from bl should wrap to tl
	target, found := FindTargetCell("bl", types.DirDown, grid, true)
	if !found {
		t.Fatal("expected wrap-around to work")
	}
	if target != "tl" {
		t.Errorf("expected 'tl' (wrap around), got '%s'", target)
	}
}

func TestFindTargetCell_WrapAround_Up(t *testing.T) {
	grid := make2x2Grid()

	// Going up from tl should wrap to bl
	target, found := FindTargetCell("tl", types.DirUp, grid, true)
	if !found {
		t.Fatal("expected wrap-around to work")
	}
	if target != "bl" {
		t.Errorf("expected 'bl' (wrap around), got '%s'", target)
	}
}

func TestFindTargetCell_WrapDisabled(t *testing.T) {
	grid := make2x2Grid()

	// Going right from tr with wrap disabled
	_, found := FindTargetCell("tr", types.DirRight, grid, false)
	if found {
		t.Error("expected no cell when wrap-around disabled")
	}
}

func TestFindTargetCell_InvalidCurrentCell(t *testing.T) {
	grid := makeTestGrid()

	_, found := FindTargetCell("nonexistent", types.DirRight, grid, false)
	if found {
		t.Error("expected not found for invalid cell")
	}
}

func TestCycleWindowIndex_Forward(t *testing.T) {
	tests := []struct {
		current  int
		total    int
		expected int
	}{
		{0, 3, 1},
		{1, 3, 2},
		{2, 3, 0}, // Wrap around
		{0, 1, 0}, // Single window
	}

	for _, tt := range tests {
		result := CycleWindowIndex(tt.current, tt.total, true)
		if result != tt.expected {
			t.Errorf("CycleWindowIndex(%d, %d, true) = %d, want %d",
				tt.current, tt.total, result, tt.expected)
		}
	}
}

func TestCycleWindowIndex_Backward(t *testing.T) {
	tests := []struct {
		current  int
		total    int
		expected int
	}{
		{0, 3, 2}, // Wrap around
		{1, 3, 0},
		{2, 3, 1},
		{0, 1, 0}, // Single window
	}

	for _, tt := range tests {
		result := CycleWindowIndex(tt.current, tt.total, false)
		if result != tt.expected {
			t.Errorf("CycleWindowIndex(%d, %d, false) = %d, want %d",
				tt.current, tt.total, result, tt.expected)
		}
	}
}

func TestCycleWindowIndex_ZeroTotal(t *testing.T) {
	result := CycleWindowIndex(0, 0, true)
	if result != 0 {
		t.Errorf("expected 0 for zero total, got %d", result)
	}
}

func TestGetWindowAtIndex(t *testing.T) {
	windows := []uint32{100, 200, 300}

	tests := []struct {
		index    int
		expected uint32
	}{
		{0, 100},
		{1, 200},
		{2, 300},
		{3, 0},  // Out of bounds
		{-1, 0}, // Negative
	}

	for _, tt := range tests {
		result := GetWindowAtIndex(windows, tt.index)
		if result != tt.expected {
			t.Errorf("GetWindowAtIndex(windows, %d) = %d, want %d",
				tt.index, result, tt.expected)
		}
	}
}

func TestGetWindowAtIndex_Empty(t *testing.T) {
	result := GetWindowAtIndex([]uint32{}, 0)
	if result != 0 {
		t.Errorf("expected 0 for empty slice, got %d", result)
	}
}

func TestFindWindowIndex(t *testing.T) {
	windows := []uint32{100, 200, 300}

	tests := []struct {
		windowID uint32
		expected int
	}{
		{100, 0},
		{200, 1},
		{300, 2},
		{999, -1}, // Not found
	}

	for _, tt := range tests {
		result := FindWindowIndex(windows, tt.windowID)
		if result != tt.expected {
			t.Errorf("FindWindowIndex(windows, %d) = %d, want %d",
				tt.windowID, result, tt.expected)
		}
	}
}

func TestNextWindowInCell(t *testing.T) {
	windows := []uint32{100, 200, 300}

	windowID, index := NextWindowInCell(windows, 0)
	if windowID != 200 || index != 1 {
		t.Errorf("expected (200, 1), got (%d, %d)", windowID, index)
	}

	// Wrap around
	windowID, index = NextWindowInCell(windows, 2)
	if windowID != 100 || index != 0 {
		t.Errorf("expected (100, 0), got (%d, %d)", windowID, index)
	}
}

func TestNextWindowInCell_Empty(t *testing.T) {
	windowID, index := NextWindowInCell([]uint32{}, 0)
	if windowID != 0 || index != -1 {
		t.Errorf("expected (0, -1), got (%d, %d)", windowID, index)
	}
}

func TestPrevWindowInCell(t *testing.T) {
	windows := []uint32{100, 200, 300}

	windowID, index := PrevWindowInCell(windows, 1)
	if windowID != 100 || index != 0 {
		t.Errorf("expected (100, 0), got (%d, %d)", windowID, index)
	}

	// Wrap around
	windowID, index = PrevWindowInCell(windows, 0)
	if windowID != 300 || index != 2 {
		t.Errorf("expected (300, 2), got (%d, %d)", windowID, index)
	}
}

func TestFirstWindowInCell(t *testing.T) {
	windows := []uint32{100, 200, 300}

	windowID := FirstWindowInCell(windows)
	if windowID != 100 {
		t.Errorf("expected 100, got %d", windowID)
	}

	windowID = FirstWindowInCell([]uint32{})
	if windowID != 0 {
		t.Errorf("expected 0 for empty slice, got %d", windowID)
	}
}

func TestHasMultipleWindows(t *testing.T) {
	if HasMultipleWindows([]uint32{100}) {
		t.Error("single window should not have multiple")
	}
	if !HasMultipleWindows([]uint32{100, 200}) {
		t.Error("two windows should have multiple")
	}
	if HasMultipleWindows([]uint32{}) {
		t.Error("empty should not have multiple")
	}
}

func TestDistanceInDirection(t *testing.T) {
	source := types.Point{X: 100, Y: 100}

	// Directly to the right (x +100, y same)
	direct := types.Point{X: 200, Y: 100}
	// Diagonally right and down (x +100, y +100)
	diagonal := types.Point{X: 200, Y: 200}

	directDist := distanceInDirection(source, direct, types.DirRight)
	diagonalDist := distanceInDirection(source, diagonal, types.DirRight)

	// Direct should be closer than diagonal when going right
	if directDist >= diagonalDist {
		t.Errorf("direct distance (%f) should be less than diagonal (%f)",
			directDist, diagonalDist)
	}
}

func TestIsInDirection(t *testing.T) {
	center := types.Point{X: 100, Y: 100}

	tests := []struct {
		target    types.Point
		direction types.Direction
		expected  bool
	}{
		{types.Point{X: 50, Y: 100}, types.DirLeft, true},
		{types.Point{X: 150, Y: 100}, types.DirLeft, false},
		{types.Point{X: 150, Y: 100}, types.DirRight, true},
		{types.Point{X: 50, Y: 100}, types.DirRight, false},
		{types.Point{X: 100, Y: 50}, types.DirUp, true},
		{types.Point{X: 100, Y: 150}, types.DirUp, false},
		{types.Point{X: 100, Y: 150}, types.DirDown, true},
		{types.Point{X: 100, Y: 50}, types.DirDown, false},
	}

	for _, tt := range tests {
		result := isInDirection(center, tt.target, tt.direction)
		if result != tt.expected {
			t.Errorf("isInDirection(%v, %v, %s) = %v, want %v",
				center, tt.target, tt.direction.String(), result, tt.expected)
		}
	}
}

func TestGetCellInDirection(t *testing.T) {
	grid := makeTestGrid()

	cell := GetCellInDirection("left", types.DirRight, grid)
	if cell != "right" {
		t.Errorf("expected 'right', got '%s'", cell)
	}

	cell = GetCellInDirection("left", types.DirLeft, grid)
	if cell != "" {
		t.Errorf("expected empty string, got '%s'", cell)
	}
}

// Test 3x1 grid for edge detection
func make3x1Grid() map[string]types.Rect {
	return map[string]types.Rect{
		"a": {X: 0, Y: 0, Width: 333, Height: 400},
		"b": {X: 333, Y: 0, Width: 334, Height: 400},
		"c": {X: 667, Y: 0, Width: 333, Height: 400},
	}
}

func TestFindTargetCell_PrefersDirect(t *testing.T) {
	// In a 2x2 grid, going right from top-left should prefer top-right
	// over bottom-right because it's more directly aligned
	grid := make2x2Grid()

	target, found := FindTargetCell("tl", types.DirRight, grid, false)
	if !found {
		t.Fatal("expected to find cell to the right")
	}
	if target != "tr" {
		t.Errorf("expected 'tr' (directly right), got '%s'", target)
	}
}

func TestFindTargetCell_3x1_WrapFromEnd(t *testing.T) {
	grid := make3x1Grid()

	// Going right from c should wrap to a
	target, found := FindTargetCell("c", types.DirRight, grid, true)
	if !found {
		t.Fatal("expected wrap-around to work")
	}
	if target != "a" {
		t.Errorf("expected 'a' (wrap around), got '%s'", target)
	}
}
