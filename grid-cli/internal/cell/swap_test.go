package cell

import (
	"testing"

	"github.com/yourusername/grid-cli/internal/types"
)

func TestCalculateSwapTarget(t *testing.T) {
	tests := []struct {
		name        string
		currentIdx  int
		windowCount int
		direction   types.Direction
		stackMode   types.StackMode
		wantIdx     int
	}{
		// Vertical stack: up/down navigation
		{"vertical-down-0", 0, 3, types.DirDown, types.StackVertical, 1},
		{"vertical-down-1", 1, 3, types.DirDown, types.StackVertical, 2},
		{"vertical-down-wrap", 2, 3, types.DirDown, types.StackVertical, 0},
		{"vertical-up-2", 2, 3, types.DirUp, types.StackVertical, 1},
		{"vertical-up-1", 1, 3, types.DirUp, types.StackVertical, 0},
		{"vertical-up-wrap", 0, 3, types.DirUp, types.StackVertical, 2},

		// Horizontal stack: left/right navigation
		{"horizontal-right-0", 0, 3, types.DirRight, types.StackHorizontal, 1},
		{"horizontal-right-1", 1, 3, types.DirRight, types.StackHorizontal, 2},
		{"horizontal-right-wrap", 2, 3, types.DirRight, types.StackHorizontal, 0},
		{"horizontal-left-2", 2, 3, types.DirLeft, types.StackHorizontal, 1},
		{"horizontal-left-1", 1, 3, types.DirLeft, types.StackHorizontal, 0},
		{"horizontal-left-wrap", 0, 3, types.DirLeft, types.StackHorizontal, 2},

		// Tabs: left/right cycling
		{"tabs-right-0", 0, 3, types.DirRight, types.StackTabs, 1},
		{"tabs-right-wrap", 2, 3, types.DirRight, types.StackTabs, 0},
		{"tabs-left-wrap", 0, 3, types.DirLeft, types.StackTabs, 2},

		// Perpendicular directions as synonyms
		{"vertical-left-as-up", 1, 3, types.DirLeft, types.StackVertical, 0},
		{"vertical-right-as-down", 1, 3, types.DirRight, types.StackVertical, 2},
		{"horizontal-up-as-left", 1, 3, types.DirUp, types.StackHorizontal, 0},
		{"horizontal-down-as-right", 1, 3, types.DirDown, types.StackHorizontal, 2},

		// Two window cases
		{"two-windows-down", 0, 2, types.DirDown, types.StackVertical, 1},
		{"two-windows-down-wrap", 1, 2, types.DirDown, types.StackVertical, 0},
		{"two-windows-up", 1, 2, types.DirUp, types.StackVertical, 0},
		{"two-windows-up-wrap", 0, 2, types.DirUp, types.StackVertical, 1},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := calculateSwapTarget(tt.currentIdx, tt.windowCount, tt.direction, tt.stackMode)
			if got != tt.wantIdx {
				t.Errorf("calculateSwapTarget(%d, %d, %s, %s) = %d, want %d",
					tt.currentIdx, tt.windowCount, tt.direction, tt.stackMode, got, tt.wantIdx)
			}
		})
	}
}
