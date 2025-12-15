package focus

import (
	"testing"

	"github.com/yourusername/grid-cli/internal/state"
	"github.com/yourusername/grid-cli/internal/types"
)

func TestSelectCrossDisplayTargetCell_UsesLastFocusedCell(t *testing.T) {
	// Setup: target space has a previously focused cell
	targetSpaceState := &state.SpaceState{
		SpaceID:     "space-2",
		FocusedCell: "cell-b", // Last focused cell on target space
	}
	// Target cells are in the target display's coordinate space (X starts at 1000)
	targetCellBounds := map[string]types.Rect{
		"cell-a": {X: 1000, Y: 0, Width: 500, Height: 500},
		"cell-b": {X: 1500, Y: 0, Width: 500, Height: 500}, // This is the last focused one
	}

	// Current cell is at left position - would map to cell-a if using closest-cell logic
	currentCellBounds := types.Rect{X: 0, Y: 0, Width: 500, Height: 500}
	currentDisplayBounds := types.Rect{X: 0, Y: 0, Width: 1000, Height: 1000}
	targetDisplayBounds := types.Rect{X: 1000, Y: 0, Width: 1000, Height: 1000}

	// Should return cell-b (last focused) instead of cell-a (closest)
	result := SelectCrossDisplayTargetCell(
		targetSpaceState,
		targetCellBounds,
		currentCellBounds,
		currentDisplayBounds,
		targetDisplayBounds,
	)

	if result != "cell-b" {
		t.Errorf("got %q, want %q (should use last focused cell, not closest)", result, "cell-b")
	}
}

func TestSelectCrossDisplayTargetCell_FallsBackToClosestOnFirstVisit(t *testing.T) {
	// Setup: target space has no focus history (nil)
	var targetSpaceState *state.SpaceState = nil

	// Target cells in target display's coordinate space
	targetCellBounds := map[string]types.Rect{
		"cell-a": {X: 1000, Y: 0, Width: 500, Height: 500},
		"cell-b": {X: 1500, Y: 0, Width: 500, Height: 500},
	}

	// Current cell at left side - should map to cell-a (closest on left)
	currentCellBounds := types.Rect{X: 0, Y: 0, Width: 500, Height: 500}
	currentDisplayBounds := types.Rect{X: 0, Y: 0, Width: 1000, Height: 1000}
	targetDisplayBounds := types.Rect{X: 1000, Y: 0, Width: 1000, Height: 1000}

	result := SelectCrossDisplayTargetCell(
		targetSpaceState,
		targetCellBounds,
		currentCellBounds,
		currentDisplayBounds,
		targetDisplayBounds,
	)

	if result != "cell-a" {
		t.Errorf("got %q, want %q (should fall back to closest cell on first visit)", result, "cell-a")
	}
}

func TestSelectCrossDisplayTargetCell_FallsBackWhenLastFocusedCellNoLongerExists(t *testing.T) {
	// Setup: target space has focus history but that cell no longer exists in layout
	targetSpaceState := &state.SpaceState{
		SpaceID:     "space-2",
		FocusedCell: "cell-deleted", // This cell no longer exists
	}
	// Target cells in target display's coordinate space
	targetCellBounds := map[string]types.Rect{
		"cell-a": {X: 1000, Y: 0, Width: 500, Height: 500},
		"cell-b": {X: 1500, Y: 0, Width: 500, Height: 500},
	}

	currentCellBounds := types.Rect{X: 0, Y: 0, Width: 500, Height: 500}
	currentDisplayBounds := types.Rect{X: 0, Y: 0, Width: 1000, Height: 1000}
	targetDisplayBounds := types.Rect{X: 1000, Y: 0, Width: 1000, Height: 1000}

	result := SelectCrossDisplayTargetCell(
		targetSpaceState,
		targetCellBounds,
		currentCellBounds,
		currentDisplayBounds,
		targetDisplayBounds,
	)

	if result != "cell-a" {
		t.Errorf("got %q, want %q (should fall back to closest when last focused cell no longer exists)", result, "cell-a")
	}
}

func TestSelectCrossDisplayTargetCell_FallsBackWhenFocusedCellIsEmpty(t *testing.T) {
	// Setup: target space exists but FocusedCell is empty string
	targetSpaceState := &state.SpaceState{
		SpaceID:     "space-2",
		FocusedCell: "", // Empty - never focused a cell on this space
	}
	// Target cells in target display's coordinate space
	targetCellBounds := map[string]types.Rect{
		"cell-a": {X: 1000, Y: 0, Width: 500, Height: 500},
		"cell-b": {X: 1500, Y: 0, Width: 500, Height: 500},
	}

	currentCellBounds := types.Rect{X: 0, Y: 0, Width: 500, Height: 500}
	currentDisplayBounds := types.Rect{X: 0, Y: 0, Width: 1000, Height: 1000}
	targetDisplayBounds := types.Rect{X: 1000, Y: 0, Width: 1000, Height: 1000}

	result := SelectCrossDisplayTargetCell(
		targetSpaceState,
		targetCellBounds,
		currentCellBounds,
		currentDisplayBounds,
		targetDisplayBounds,
	)

	if result != "cell-a" {
		t.Errorf("got %q, want %q (should fall back to closest when FocusedCell is empty)", result, "cell-a")
	}
}
