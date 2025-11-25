package layout

import (
	"math"
	"testing"
)

func TestInitializeSplitRatios(t *testing.T) {
	tests := []struct {
		count    int
		expected []float64
	}{
		{0, nil},
		{1, []float64{1.0}},
		{2, []float64{0.5, 0.5}},
		{3, []float64{1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0}},
		{4, []float64{0.25, 0.25, 0.25, 0.25}},
	}

	for _, tt := range tests {
		result := InitializeSplitRatios(tt.count)

		if tt.expected == nil {
			if result != nil {
				t.Errorf("InitializeSplitRatios(%d) = %v, want nil", tt.count, result)
			}
			continue
		}

		if len(result) != len(tt.expected) {
			t.Errorf("InitializeSplitRatios(%d) length = %d, want %d", tt.count, len(result), len(tt.expected))
			continue
		}

		for i, v := range result {
			if math.Abs(v-tt.expected[i]) > 0.0001 {
				t.Errorf("InitializeSplitRatios(%d)[%d] = %f, want %f", tt.count, i, v, tt.expected[i])
			}
		}
	}
}

func TestNormalizeSplitRatios(t *testing.T) {
	tests := []struct {
		input    []float64
		expected []float64
	}{
		{nil, nil},
		{[]float64{}, nil},
		{[]float64{1, 2, 3}, []float64{1.0 / 6, 2.0 / 6, 3.0 / 6}}, // Sum = 6
		{[]float64{0.5, 0.5}, []float64{0.5, 0.5}},                  // Already normalized
		{[]float64{2, 2}, []float64{0.5, 0.5}},                      // Sum = 4
	}

	for _, tt := range tests {
		result := NormalizeSplitRatios(tt.input)

		if tt.expected == nil {
			if result != nil {
				t.Errorf("NormalizeSplitRatios(%v) = %v, want nil", tt.input, result)
			}
			continue
		}

		if len(result) != len(tt.expected) {
			t.Errorf("NormalizeSplitRatios(%v) length = %d, want %d", tt.input, len(result), len(tt.expected))
			continue
		}

		sum := 0.0
		for i, v := range result {
			sum += v
			if math.Abs(v-tt.expected[i]) > 0.0001 {
				t.Errorf("NormalizeSplitRatios(%v)[%d] = %f, want %f", tt.input, i, v, tt.expected[i])
			}
		}

		if math.Abs(sum-1.0) > 0.0001 {
			t.Errorf("NormalizeSplitRatios(%v) sum = %f, want 1.0", tt.input, sum)
		}
	}
}

func TestAdjustSplitRatio(t *testing.T) {
	// Basic grow test
	t.Run("BasicGrow", func(t *testing.T) {
		ratios := []float64{0.5, 0.5}
		newRatios, err := AdjustSplitRatio(ratios, 0, 0.1, 0.1)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}

		if math.Abs(newRatios[0]-0.6) > 0.0001 || math.Abs(newRatios[1]-0.4) > 0.0001 {
			t.Errorf("expected [0.6, 0.4], got %v", newRatios)
		}
	})

	// Basic shrink test
	t.Run("BasicShrink", func(t *testing.T) {
		ratios := []float64{0.5, 0.5}
		newRatios, err := AdjustSplitRatio(ratios, 0, -0.1, 0.1)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}

		if math.Abs(newRatios[0]-0.4) > 0.0001 || math.Abs(newRatios[1]-0.6) > 0.0001 {
			t.Errorf("expected [0.4, 0.6], got %v", newRatios)
		}
	})

	// Three windows
	t.Run("ThreeWindows", func(t *testing.T) {
		ratios := []float64{0.33, 0.34, 0.33}
		newRatios, err := AdjustSplitRatio(ratios, 1, 0.1, 0.1) // Grow middle
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}

		// Middle window should grow, third should shrink
		if newRatios[1] <= ratios[1] {
			t.Errorf("middle window should have grown: %f -> %f", ratios[1], newRatios[1])
		}
		if newRatios[2] >= ratios[2] {
			t.Errorf("third window should have shrunk: %f -> %f", ratios[2], newRatios[2])
		}
	})

	// Error cases
	t.Run("TooFewWindows", func(t *testing.T) {
		_, err := AdjustSplitRatio([]float64{1.0}, 0, 0.1, 0.1)
		if err == nil {
			t.Error("expected error for single window")
		}
	})

	t.Run("InvalidIndex", func(t *testing.T) {
		_, err := AdjustSplitRatio([]float64{0.5, 0.5}, 1, 0.1, 0.1) // index 1 is last window
		if err == nil {
			t.Error("expected error for invalid index")
		}
	})
}

func TestAdjustSplitRatio_MinimumEnforced(t *testing.T) {
	// Try to shrink first window beyond minimum
	ratios := []float64{0.15, 0.85}
	newRatios, err := AdjustSplitRatio(ratios, 0, -0.1, 0.1)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// First window should be clamped at minimum
	if newRatios[0] < 0.1 {
		t.Errorf("first ratio below minimum: %f", newRatios[0])
	}

	// Sum should still be 1.0
	sum := newRatios[0] + newRatios[1]
	if math.Abs(sum-1.0) > 0.0001 {
		t.Errorf("sum should be 1.0, got %f", sum)
	}
}

func TestAdjustSplitRatio_MinimumEnforced_SecondWindow(t *testing.T) {
	// Try to shrink second window beyond minimum
	ratios := []float64{0.85, 0.15}
	newRatios, err := AdjustSplitRatio(ratios, 0, 0.1, 0.1) // Grow first, shrinks second
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Second window should be clamped at minimum
	if newRatios[1] < 0.1 {
		t.Errorf("second ratio below minimum: %f", newRatios[1])
	}

	// Sum should still be 1.0
	sum := newRatios[0] + newRatios[1]
	if math.Abs(sum-1.0) > 0.0001 {
		t.Errorf("sum should be 1.0, got %f", sum)
	}
}

func TestRecalculateSplitsAfterRemoval(t *testing.T) {
	t.Run("RemoveMiddle", func(t *testing.T) {
		ratios := []float64{0.4, 0.3, 0.3}
		newRatios := RecalculateSplitsAfterRemoval(ratios, 1)

		if len(newRatios) != 2 {
			t.Fatalf("expected 2 ratios, got %d", len(newRatios))
		}

		// Each remaining window should get half of removed window's ratio
		// 0.4 + 0.15 = 0.55, 0.3 + 0.15 = 0.45
		if math.Abs(newRatios[0]-0.55) > 0.0001 {
			t.Errorf("expected first ratio ~0.55, got %f", newRatios[0])
		}
		if math.Abs(newRatios[1]-0.45) > 0.0001 {
			t.Errorf("expected second ratio ~0.45, got %f", newRatios[1])
		}
	})

	t.Run("RemoveFirst", func(t *testing.T) {
		ratios := []float64{0.5, 0.5}
		newRatios := RecalculateSplitsAfterRemoval(ratios, 0)

		if len(newRatios) != 1 {
			t.Fatalf("expected 1 ratio, got %d", len(newRatios))
		}
		if newRatios[0] != 1.0 {
			t.Errorf("expected 1.0, got %f", newRatios[0])
		}
	})

	t.Run("RemoveFromSingle", func(t *testing.T) {
		ratios := []float64{1.0}
		newRatios := RecalculateSplitsAfterRemoval(ratios, 0)

		if len(newRatios) != 1 || newRatios[0] != 1.0 {
			t.Errorf("expected [1.0], got %v", newRatios)
		}
	})

	t.Run("InvalidIndex", func(t *testing.T) {
		ratios := []float64{0.5, 0.5}
		newRatios := RecalculateSplitsAfterRemoval(ratios, 5)

		// Should return original
		if len(newRatios) != 2 {
			t.Errorf("expected original ratios returned for invalid index")
		}
	})
}

func TestRecalculateSplitsAfterAddition(t *testing.T) {
	t.Run("AddToTwo", func(t *testing.T) {
		ratios := []float64{0.6, 0.4}
		newRatios := RecalculateSplitsAfterAddition(ratios, 1)

		if len(newRatios) != 3 {
			t.Fatalf("expected 3 ratios, got %d", len(newRatios))
		}

		// New window gets 1/3, existing scaled by 2/3
		sum := newRatios[0] + newRatios[1] + newRatios[2]
		if math.Abs(sum-1.0) > 0.0001 {
			t.Errorf("ratios should sum to 1.0, got %f", sum)
		}

		// New window (index 1) should get approximately 1/3
		if math.Abs(newRatios[1]-1.0/3.0) > 0.01 {
			t.Errorf("new window ratio should be ~0.33, got %f", newRatios[1])
		}
	})

	t.Run("AddToEmpty", func(t *testing.T) {
		ratios := []float64{}
		newRatios := RecalculateSplitsAfterAddition(ratios, 0)

		if len(newRatios) != 1 || newRatios[0] != 1.0 {
			t.Errorf("expected [1.0], got %v", newRatios)
		}
	})

	t.Run("AddAtEnd", func(t *testing.T) {
		ratios := []float64{0.5, 0.5}
		newRatios := RecalculateSplitsAfterAddition(ratios, 2)

		if len(newRatios) != 3 {
			t.Fatalf("expected 3 ratios, got %d", len(newRatios))
		}

		sum := newRatios[0] + newRatios[1] + newRatios[2]
		if math.Abs(sum-1.0) > 0.0001 {
			t.Errorf("ratios should sum to 1.0, got %f", sum)
		}
	})
}

func TestRecalculateSplitsAfterReorder(t *testing.T) {
	t.Run("MoveForward", func(t *testing.T) {
		ratios := []float64{0.5, 0.3, 0.2}
		newRatios := RecalculateSplitsAfterReorder(ratios, 0, 2)

		// Original 0.5 should now be at index 2
		if math.Abs(newRatios[2]-0.5) > 0.0001 {
			t.Errorf("expected ratio 0.5 at index 2, got %f", newRatios[2])
		}
		// 0.3 should be at index 0
		if math.Abs(newRatios[0]-0.3) > 0.0001 {
			t.Errorf("expected ratio 0.3 at index 0, got %f", newRatios[0])
		}
		// 0.2 should be at index 1
		if math.Abs(newRatios[1]-0.2) > 0.0001 {
			t.Errorf("expected ratio 0.2 at index 1, got %f", newRatios[1])
		}
	})

	t.Run("MoveBackward", func(t *testing.T) {
		ratios := []float64{0.5, 0.3, 0.2}
		newRatios := RecalculateSplitsAfterReorder(ratios, 2, 0)

		// Original 0.2 should now be at index 0
		if math.Abs(newRatios[0]-0.2) > 0.0001 {
			t.Errorf("expected ratio 0.2 at index 0, got %f", newRatios[0])
		}
	})

	t.Run("SameIndex", func(t *testing.T) {
		ratios := []float64{0.5, 0.5}
		newRatios := RecalculateSplitsAfterReorder(ratios, 0, 0)

		// Should be unchanged
		for i := range ratios {
			if newRatios[i] != ratios[i] {
				t.Errorf("ratios should be unchanged")
			}
		}
	})
}

func TestCalculateSplitBoundary(t *testing.T) {
	t.Run("TwoEqualWindows", func(t *testing.T) {
		ratios := []float64{0.5, 0.5}
		cellSize := 1000.0
		padding := 10.0

		// Boundary between first and second window
		boundary := CalculateSplitBoundary(cellSize, ratios, 0, padding)

		// Available space = 1000 - 10 (one padding) = 990
		// First window takes 0.5 * 990 = 495
		// Plus padding = 495 + 10 = 505
		expected := (990 * 0.5) + 10
		if math.Abs(boundary-expected) > 0.01 {
			t.Errorf("expected boundary at %f, got %f", expected, boundary)
		}
	})

	t.Run("ThreeWindows", func(t *testing.T) {
		ratios := []float64{0.5, 0.3, 0.2}
		cellSize := 1000.0
		padding := 10.0

		// Available space = 1000 - 20 (two paddings) = 980

		// Boundary after first window
		b0 := CalculateSplitBoundary(cellSize, ratios, 0, padding)
		// First window = 0.5 * 980 = 490, plus padding = 500
		expected0 := (980 * 0.5) + 10
		if math.Abs(b0-expected0) > 0.01 {
			t.Errorf("boundary 0: expected %f, got %f", expected0, b0)
		}

		// Boundary after second window
		b1 := CalculateSplitBoundary(cellSize, ratios, 1, padding)
		// First + second = 0.8 * 980 = 784, plus 2 paddings = 804
		expected1 := (980 * 0.8) + 20
		if math.Abs(b1-expected1) > 0.01 {
			t.Errorf("boundary 1: expected %f, got %f", expected1, b1)
		}
	})

	t.Run("InvalidBoundaryIndex", func(t *testing.T) {
		ratios := []float64{0.5, 0.5}
		boundary := CalculateSplitBoundary(1000, ratios, -1, 10)
		if boundary != 0 {
			t.Errorf("expected 0 for invalid index, got %f", boundary)
		}

		boundary = CalculateSplitBoundary(1000, ratios, 5, 10)
		if boundary != 0 {
			t.Errorf("expected 0 for out-of-bounds index, got %f", boundary)
		}
	})
}

func TestAdjustSplitRatioAtBoundary(t *testing.T) {
	ratios := []float64{0.5, 0.5}
	newRatios, err := AdjustSplitRatioAtBoundary(ratios, 0, 0.1)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Uses MinimumRatio constant
	if newRatios[0] < MinimumRatio || newRatios[1] < MinimumRatio {
		t.Errorf("ratio below minimum: %v", newRatios)
	}
}
