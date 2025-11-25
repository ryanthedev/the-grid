package types

import "testing"

func TestRectCenter(t *testing.T) {
	tests := []struct {
		name string
		rect Rect
		want Point
	}{
		{
			name: "origin rect",
			rect: Rect{X: 0, Y: 0, Width: 100, Height: 100},
			want: Point{X: 50, Y: 50},
		},
		{
			name: "offset rect",
			rect: Rect{X: 100, Y: 200, Width: 50, Height: 80},
			want: Point{X: 125, Y: 240},
		},
		{
			name: "zero size",
			rect: Rect{X: 10, Y: 20, Width: 0, Height: 0},
			want: Point{X: 10, Y: 20},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.rect.Center()
			if got.X != tt.want.X || got.Y != tt.want.Y {
				t.Errorf("Center() = (%v, %v), want (%v, %v)", got.X, got.Y, tt.want.X, tt.want.Y)
			}
		})
	}
}

func TestRectContains(t *testing.T) {
	rect := Rect{X: 0, Y: 0, Width: 100, Height: 100}

	tests := []struct {
		name  string
		point Point
		want  bool
	}{
		{"center point", Point{X: 50, Y: 50}, true},
		{"top-left corner", Point{X: 0, Y: 0}, true},
		{"bottom-right corner", Point{X: 100, Y: 100}, true},
		{"outside right", Point{X: 150, Y: 50}, false},
		{"outside left", Point{X: -10, Y: 50}, false},
		{"outside top", Point{X: 50, Y: -10}, false},
		{"outside bottom", Point{X: 50, Y: 150}, false},
		{"on edge", Point{X: 100, Y: 50}, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := rect.Contains(tt.point); got != tt.want {
				t.Errorf("Contains(%v) = %v, want %v", tt.point, got, tt.want)
			}
		})
	}
}

func TestDirectionString(t *testing.T) {
	tests := []struct {
		dir  Direction
		want string
	}{
		{DirLeft, "left"},
		{DirRight, "right"},
		{DirUp, "up"},
		{DirDown, "down"},
		{Direction(99), "unknown"},
	}

	for _, tt := range tests {
		t.Run(tt.want, func(t *testing.T) {
			if got := tt.dir.String(); got != tt.want {
				t.Errorf("Direction.String() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestParseDirection(t *testing.T) {
	tests := []struct {
		input   string
		wantDir Direction
		wantOK  bool
	}{
		{"left", DirLeft, true},
		{"right", DirRight, true},
		{"up", DirUp, true},
		{"down", DirDown, true},
		{"invalid", 0, false},
		{"LEFT", 0, false}, // case sensitive
		{"", 0, false},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			gotDir, gotOK := ParseDirection(tt.input)
			if gotDir != tt.wantDir || gotOK != tt.wantOK {
				t.Errorf("ParseDirection(%q) = (%v, %v), want (%v, %v)",
					tt.input, gotDir, gotOK, tt.wantDir, tt.wantOK)
			}
		})
	}
}

func TestStackModeConstants(t *testing.T) {
	// Verify constant values match spec
	if StackVertical != "vertical" {
		t.Errorf("StackVertical = %q, want %q", StackVertical, "vertical")
	}
	if StackHorizontal != "horizontal" {
		t.Errorf("StackHorizontal = %q, want %q", StackHorizontal, "horizontal")
	}
	if StackTabs != "tabs" {
		t.Errorf("StackTabs = %q, want %q", StackTabs, "tabs")
	}
}

func TestTrackTypeConstants(t *testing.T) {
	// Verify constant values match spec
	if TrackFr != "fr" {
		t.Errorf("TrackFr = %q, want %q", TrackFr, "fr")
	}
	if TrackPx != "px" {
		t.Errorf("TrackPx = %q, want %q", TrackPx, "px")
	}
	if TrackAuto != "auto" {
		t.Errorf("TrackAuto = %q, want %q", TrackAuto, "auto")
	}
	if TrackMinMax != "minmax" {
		t.Errorf("TrackMinMax = %q, want %q", TrackMinMax, "minmax")
	}
}

func TestAssignmentStrategyIota(t *testing.T) {
	// Verify iota ordering
	if AssignAutoFlow != 0 {
		t.Errorf("AssignAutoFlow = %d, want 0", AssignAutoFlow)
	}
	if AssignPinned != 1 {
		t.Errorf("AssignPinned = %d, want 1", AssignPinned)
	}
	if AssignPreserve != 2 {
		t.Errorf("AssignPreserve = %d, want 2", AssignPreserve)
	}
}

func TestDirectionIota(t *testing.T) {
	// Verify iota ordering
	if DirLeft != 0 {
		t.Errorf("DirLeft = %d, want 0", DirLeft)
	}
	if DirRight != 1 {
		t.Errorf("DirRight = %d, want 1", DirRight)
	}
	if DirUp != 2 {
		t.Errorf("DirUp = %d, want 2", DirUp)
	}
	if DirDown != 3 {
		t.Errorf("DirDown = %d, want 3", DirDown)
	}
}
