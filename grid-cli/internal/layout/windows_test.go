package layout

import (
	"testing"

	"github.com/yourusername/grid-cli/internal/types"
)

func TestCalculateWindowBounds_Vertical(t *testing.T) {
	cellBounds := types.Rect{X: 0, Y: 0, Width: 500, Height: 1000}
	bounds := CalculateWindowBounds(cellBounds, 2, types.StackVertical, nil, 0)

	if len(bounds) != 2 {
		t.Fatalf("expected 2 bounds, got %d", len(bounds))
	}

	// First window: top half
	if bounds[0].X != 0 || bounds[0].Y != 0 {
		t.Errorf("bounds[0] position = (%v, %v), want (0, 0)", bounds[0].X, bounds[0].Y)
	}
	if bounds[0].Width != 500 || bounds[0].Height != 500 {
		t.Errorf("bounds[0] size = (%v, %v), want (500, 500)", bounds[0].Width, bounds[0].Height)
	}

	// Second window: bottom half
	if bounds[1].X != 0 || bounds[1].Y != 500 {
		t.Errorf("bounds[1] position = (%v, %v), want (0, 500)", bounds[1].X, bounds[1].Y)
	}
	if bounds[1].Width != 500 || bounds[1].Height != 500 {
		t.Errorf("bounds[1] size = (%v, %v), want (500, 500)", bounds[1].Width, bounds[1].Height)
	}
}

func TestCalculateWindowBounds_Horizontal(t *testing.T) {
	cellBounds := types.Rect{X: 0, Y: 0, Width: 1000, Height: 500}
	bounds := CalculateWindowBounds(cellBounds, 2, types.StackHorizontal, nil, 0)

	if len(bounds) != 2 {
		t.Fatalf("expected 2 bounds, got %d", len(bounds))
	}

	// First window: left half
	if bounds[0].X != 0 || bounds[0].Y != 0 {
		t.Errorf("bounds[0] position = (%v, %v), want (0, 0)", bounds[0].X, bounds[0].Y)
	}
	if bounds[0].Width != 500 || bounds[0].Height != 500 {
		t.Errorf("bounds[0] size = (%v, %v), want (500, 500)", bounds[0].Width, bounds[0].Height)
	}

	// Second window: right half
	if bounds[1].X != 500 || bounds[1].Y != 0 {
		t.Errorf("bounds[1] position = (%v, %v), want (500, 0)", bounds[1].X, bounds[1].Y)
	}
	if bounds[1].Width != 500 || bounds[1].Height != 500 {
		t.Errorf("bounds[1] size = (%v, %v), want (500, 500)", bounds[1].Width, bounds[1].Height)
	}
}

func TestCalculateWindowBounds_WithRatios(t *testing.T) {
	cellBounds := types.Rect{X: 0, Y: 0, Width: 500, Height: 1000}
	ratios := []float64{0.3, 0.7}
	bounds := CalculateWindowBounds(cellBounds, 2, types.StackVertical, ratios, 0)

	if len(bounds) != 2 {
		t.Fatalf("expected 2 bounds, got %d", len(bounds))
	}

	// First window: 30% height
	if bounds[0].Height != 300 {
		t.Errorf("bounds[0].Height = %v, want 300", bounds[0].Height)
	}

	// Second window: 70% height, starts at Y=300
	if bounds[1].Y != 300 {
		t.Errorf("bounds[1].Y = %v, want 300", bounds[1].Y)
	}
	if bounds[1].Height != 700 {
		t.Errorf("bounds[1].Height = %v, want 700", bounds[1].Height)
	}
}

func TestCalculateWindowBounds_Tabs(t *testing.T) {
	cellBounds := types.Rect{X: 0, Y: 0, Width: 500, Height: 500}
	bounds := CalculateWindowBounds(cellBounds, 3, types.StackTabs, nil, 0)

	if len(bounds) != 3 {
		t.Fatalf("expected 3 bounds, got %d", len(bounds))
	}

	// All windows should get full cell bounds
	for i, b := range bounds {
		if b != cellBounds {
			t.Errorf("bounds[%d] = %v, want %v (full cell)", i, b, cellBounds)
		}
	}
}

func TestCalculateWindowBounds_WithPadding(t *testing.T) {
	cellBounds := types.Rect{X: 0, Y: 0, Width: 500, Height: 1000}
	padding := float64(10)
	bounds := CalculateWindowBounds(cellBounds, 2, types.StackVertical, nil, padding)

	if len(bounds) != 2 {
		t.Fatalf("expected 2 bounds, got %d", len(bounds))
	}

	// Available height = 1000 - 10 (1 gap) = 990
	// Each window = 495
	if bounds[0].Height != 495 {
		t.Errorf("bounds[0].Height = %v, want 495", bounds[0].Height)
	}
	// Second window starts at 495 + 10 = 505
	if bounds[1].Y != 505 {
		t.Errorf("bounds[1].Y = %v, want 505", bounds[1].Y)
	}
	if bounds[1].Height != 495 {
		t.Errorf("bounds[1].Height = %v, want 495", bounds[1].Height)
	}
}

func TestCalculateWindowBounds_SingleWindow(t *testing.T) {
	cellBounds := types.Rect{X: 100, Y: 200, Width: 500, Height: 500}
	bounds := CalculateWindowBounds(cellBounds, 1, types.StackVertical, nil, 10)

	if len(bounds) != 1 {
		t.Fatalf("expected 1 bound, got %d", len(bounds))
	}

	// Single window gets full cell (no padding needed)
	if bounds[0] != cellBounds {
		t.Errorf("bounds[0] = %v, want %v (full cell)", bounds[0], cellBounds)
	}
}

func TestCalculateWindowBounds_Empty(t *testing.T) {
	cellBounds := types.Rect{X: 0, Y: 0, Width: 500, Height: 500}
	bounds := CalculateWindowBounds(cellBounds, 0, types.StackVertical, nil, 0)

	if bounds != nil {
		t.Errorf("expected nil for 0 windows, got %v", bounds)
	}
}

func TestCalculateWindowBounds_DefaultMode(t *testing.T) {
	cellBounds := types.Rect{X: 0, Y: 0, Width: 500, Height: 1000}
	// Empty string should default to vertical
	bounds := CalculateWindowBounds(cellBounds, 2, "", nil, 0)

	if len(bounds) != 2 {
		t.Fatalf("expected 2 bounds, got %d", len(bounds))
	}

	// Should behave like vertical stack
	if bounds[0].Height != 500 || bounds[1].Height != 500 {
		t.Error("default mode should stack vertically")
	}
}

func TestNormalizeRatios(t *testing.T) {
	tests := []struct {
		name   string
		input  []float64
		expect []float64
	}{
		{
			name:   "already normalized",
			input:  []float64{0.5, 0.5},
			expect: []float64{0.5, 0.5},
		},
		{
			name:   "need normalization",
			input:  []float64{1, 2, 2},
			expect: []float64{0.2, 0.4, 0.4},
		},
		{
			name:   "all zeros",
			input:  []float64{0, 0, 0},
			expect: []float64{1.0 / 3, 1.0 / 3, 1.0 / 3},
		},
		{
			name:   "empty",
			input:  []float64{},
			expect: nil,
		},
		{
			name:   "nil",
			input:  nil,
			expect: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := NormalizeRatios(tt.input)
			if tt.expect == nil {
				if got != nil {
					t.Errorf("expected nil, got %v", got)
				}
				return
			}
			if len(got) != len(tt.expect) {
				t.Fatalf("length mismatch: got %d, want %d", len(got), len(tt.expect))
			}
			for i := range tt.expect {
				if !floatEquals(got[i], tt.expect[i], 0.0001) {
					t.Errorf("ratio[%d] = %v, want %v", i, got[i], tt.expect[i])
				}
			}
		})
	}
}

func TestEqualRatios(t *testing.T) {
	tests := []struct {
		n      int
		expect []float64
	}{
		{1, []float64{1.0}},
		{2, []float64{0.5, 0.5}},
		{4, []float64{0.25, 0.25, 0.25, 0.25}},
		{0, nil},
		{-1, nil},
	}

	for _, tt := range tests {
		got := equalRatios(tt.n)
		if tt.expect == nil {
			if got != nil {
				t.Errorf("equalRatios(%d) = %v, want nil", tt.n, got)
			}
			continue
		}
		if len(got) != len(tt.expect) {
			t.Errorf("equalRatios(%d) length = %d, want %d", tt.n, len(got), len(tt.expect))
			continue
		}
		for i := range tt.expect {
			if got[i] != tt.expect[i] {
				t.Errorf("equalRatios(%d)[%d] = %v, want %v", tt.n, i, got[i], tt.expect[i])
			}
		}
	}
}

func TestCalculateAllWindowPlacements(t *testing.T) {
	calculatedLayout := &types.CalculatedLayout{
		LayoutID: "test",
		CellBounds: map[string]types.Rect{
			"left":  {X: 0, Y: 0, Width: 500, Height: 1000},
			"right": {X: 510, Y: 0, Width: 490, Height: 1000},
		},
	}

	assignments := map[string][]uint32{
		"left":  {1, 2},
		"right": {3},
	}

	placements := CalculateAllWindowPlacements(
		calculatedLayout,
		nil, // no layout (padding comes from settings)
		assignments,
		nil, // use default mode
		nil, // use equal ratios
		types.StackVertical,
		8,   // baseSpacing
		nil, // settingsPadding
		nil, // settingsWindowSpacing
	)

	if len(placements) != 3 {
		t.Fatalf("expected 3 placements, got %d", len(placements))
	}

	// Find placements by window ID
	placementMap := make(map[uint32]types.WindowPlacement)
	for _, p := range placements {
		placementMap[p.WindowID] = p
	}

	// Window 1 should be in top half of left cell
	p1 := placementMap[1]
	if p1.Bounds.X != 0 || p1.Bounds.Y != 0 {
		t.Errorf("window 1 position = (%v, %v), want (0, 0)", p1.Bounds.X, p1.Bounds.Y)
	}

	// Window 3 should be full right cell
	p3 := placementMap[3]
	if p3.Bounds.X != 510 {
		t.Errorf("window 3.X = %v, want 510", p3.Bounds.X)
	}
	if p3.Bounds.Height != 1000 {
		t.Errorf("window 3.Height = %v, want 1000 (full cell)", p3.Bounds.Height)
	}
}

func TestCalculateAllWindowPlacements_WithCellModes(t *testing.T) {
	calculatedLayout := &types.CalculatedLayout{
		LayoutID: "test",
		CellBounds: map[string]types.Rect{
			"main": {X: 0, Y: 0, Width: 1000, Height: 500},
		},
	}

	assignments := map[string][]uint32{
		"main": {1, 2},
	}

	cellModes := map[string]types.StackMode{
		"main": types.StackHorizontal, // Override to horizontal
	}

	placements := CalculateAllWindowPlacements(
		calculatedLayout,
		nil, // no layout
		assignments,
		cellModes,
		nil,
		types.StackVertical, // default is vertical, but we override
		8,   // baseSpacing
		nil, // settingsPadding
		nil, // settingsWindowSpacing
	)

	if len(placements) != 2 {
		t.Fatalf("expected 2 placements, got %d", len(placements))
	}

	// With horizontal stacking, windows should be side by side
	// Find by window ID
	var p1, p2 types.WindowPlacement
	for _, p := range placements {
		if p.WindowID == 1 {
			p1 = p
		} else if p.WindowID == 2 {
			p2 = p
		}
	}

	// Window 1 should be on the left
	if p1.Bounds.Width != 500 {
		t.Errorf("window 1 width = %v, want 500 (half of horizontal)", p1.Bounds.Width)
	}
	// Window 2 should be on the right
	if p2.Bounds.X != 500 {
		t.Errorf("window 2 X = %v, want 500 (right side)", p2.Bounds.X)
	}
}

func TestCalculateAllWindowPlacements_Nil(t *testing.T) {
	placements := CalculateAllWindowPlacements(nil, nil, nil, nil, nil, types.StackVertical, 8, nil, nil)
	if placements != nil {
		t.Errorf("expected nil for nil layout, got %v", placements)
	}
}

func TestCalculateAllWindowPlacements_UnknownCell(t *testing.T) {
	calculatedLayout := &types.CalculatedLayout{
		LayoutID: "test",
		CellBounds: map[string]types.Rect{
			"main": {X: 0, Y: 0, Width: 500, Height: 500},
		},
	}

	assignments := map[string][]uint32{
		"unknown": {1, 2}, // This cell doesn't exist
	}

	placements := CalculateAllWindowPlacements(
		calculatedLayout,
		nil, // no layout
		assignments,
		nil,
		nil,
		types.StackVertical,
		8,   // baseSpacing
		nil, // settingsPadding
		nil, // settingsWindowSpacing
	)

	// Should skip unknown cells
	if len(placements) != 0 {
		t.Errorf("expected 0 placements for unknown cell, got %d", len(placements))
	}
}

func TestAdjustRatiosForWindowCount(t *testing.T) {
	tests := []struct {
		name          string
		ratios        []float64
		newCount      int
		expectedLen   int
		expectedSum   float64
	}{
		{
			name:        "shrink from 3 to 2 - drop last ratio and renormalize",
			ratios:      []float64{0.33, 0.33, 0.34},
			newCount:    2,
			expectedLen: 2,
			expectedSum: 1.0,
		},
		{
			name:        "grow from 2 to 3 - add equal portion",
			ratios:      []float64{0.5, 0.5},
			newCount:    3,
			expectedLen: 3,
			expectedSum: 1.0,
		},
		{
			name:        "same count - no change",
			ratios:      []float64{0.4, 0.6},
			newCount:    2,
			expectedLen: 2,
			expectedSum: 1.0,
		},
		{
			name:        "nil ratios - returns equal ratios",
			ratios:      nil,
			newCount:    3,
			expectedLen: 3,
			expectedSum: 1.0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := AdjustRatiosForWindowCount(tt.ratios, tt.newCount)

			if len(result) != tt.expectedLen {
				t.Errorf("expected len %d, got %d", tt.expectedLen, len(result))
			}

			sum := 0.0
			for _, r := range result {
				sum += r
			}
			if abs(sum-tt.expectedSum) > 0.001 {
				t.Errorf("expected sum %.3f, got %.3f", tt.expectedSum, sum)
			}
		})
	}
}

func abs(x float64) float64 {
	if x < 0 {
		return -x
	}
	return x
}

// TestAdjustRatiosForWindowCount_RatioPreservation tests the specific scenario
// where state has 3 windows with custom ratios [0.5, 0.3, 0.2], but the third
// window disappears (e.g., a transient tooltip). The ratios should be adjusted
// to preserve relative proportions [0.625, 0.375], not reset to equal [0.5, 0.5].
func TestAdjustRatiosForWindowCount_RatioPreservation(t *testing.T) {
	// Scenario: State has 3 windows with custom ratios
	stateRatios := []float64{0.5, 0.3, 0.2}

	// Third window disappeared (e.g., transient tooltip closed)
	actualWindowCount := 2

	// Adjust ratios for the new count
	adjustedRatios := AdjustRatiosForWindowCount(stateRatios, actualWindowCount)

	// Verify we get 2 ratios
	if len(adjustedRatios) != 2 {
		t.Fatalf("expected 2 ratios, got %d", len(adjustedRatios))
	}

	// Expected: [0.5, 0.3] normalized
	// Sum of first two = 0.8
	// Normalized: [0.5/0.8, 0.3/0.8] = [0.625, 0.375]
	expected := []float64{0.625, 0.375}

	for i, expectedRatio := range expected {
		if !floatEquals(adjustedRatios[i], expectedRatio, 0.001) {
			t.Errorf("ratio[%d] = %v, want %v (relative proportions preserved)",
				i, adjustedRatios[i], expectedRatio)
		}
	}

	// Verify sum is 1.0
	sum := 0.0
	for _, r := range adjustedRatios {
		sum += r
	}
	if !floatEquals(sum, 1.0, 0.001) {
		t.Errorf("sum of ratios = %v, want 1.0", sum)
	}

	// Verify that we did NOT get equal splits
	equalSplit := []float64{0.5, 0.5}
	isEqual := true
	for i := range equalSplit {
		if !floatEquals(adjustedRatios[i], equalSplit[i], 0.001) {
			isEqual = false
			break
		}
	}
	if isEqual {
		t.Error("ratios were reset to equal splits [0.5, 0.5] instead of preserving proportions [0.625, 0.375]")
	}
}

// floatEquals is defined in grid_test.go
