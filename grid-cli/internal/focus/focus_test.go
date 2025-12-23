package focus

import (
	"testing"

	"github.com/ryanthedev/grid-cli/internal/state"
	"github.com/ryanthedev/grid-cli/internal/types"
)

func TestSelectCrossDisplayTargetCell_UsesLastFocusedCell(t *testing.T) {
	// Setup: target space has a previously focused cell with windows
	targetSpaceState := &state.SpaceState{
		SpaceID:     "space-2",
		FocusedCell: "cell-b", // Last focused cell on target space
		Cells: map[string]*state.CellState{
			"cell-a": {CellID: "cell-a", Windows: []uint32{100}},
			"cell-b": {CellID: "cell-b", Windows: []uint32{200}}, // Has windows
		},
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

	// When targetSpaceState is nil, we can't check for windows, so return empty
	if result != "" {
		t.Errorf("got %q, want %q (should return empty when targetSpaceState is nil)", result, "")
	}
}

func TestSelectCrossDisplayTargetCell_FallsBackWhenLastFocusedCellNoLongerExists(t *testing.T) {
	// Setup: target space has focus history but that cell no longer exists in layout
	targetSpaceState := &state.SpaceState{
		SpaceID:     "space-2",
		FocusedCell: "cell-deleted", // This cell no longer exists
		Cells: map[string]*state.CellState{
			"cell-a": {CellID: "cell-a", Windows: []uint32{100}},
			"cell-b": {CellID: "cell-b", Windows: []uint32{200}},
		},
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
		Cells: map[string]*state.CellState{
			"cell-a": {CellID: "cell-a", Windows: []uint32{100}},
			"cell-b": {CellID: "cell-b", Windows: []uint32{200}},
		},
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

func TestSelectCrossDisplayTargetCell_FallsBackWhenFocusedCellHasNoWindows(t *testing.T) {
	// Setup: target space has focus on a cell that exists but has NO windows
	// This is the bug case - user moved all windows out of the focused cell
	targetSpaceState := &state.SpaceState{
		SpaceID:     "space-2",
		FocusedCell: "cell-b", // This cell exists but has no windows
		Cells: map[string]*state.CellState{
			"cell-a": {CellID: "cell-a", Windows: []uint32{100, 200}}, // Has windows
			"cell-b": {CellID: "cell-b", Windows: []uint32{}},         // Empty!
		},
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

	// Should NOT return cell-b (empty), should fall back to cell-a (has windows)
	if result != "cell-a" {
		t.Errorf("got %q, want %q (should fall back to cell with windows when focused cell is empty)", result, "cell-a")
	}
}

func TestSelectCrossDisplayTargetCell_ReturnsEmptyWhenNoWindowsOnTarget(t *testing.T) {
	// Setup: all cells on target space are empty
	targetSpaceState := &state.SpaceState{
		SpaceID:     "space-2",
		FocusedCell: "cell-a",
		Cells: map[string]*state.CellState{
			"cell-a": {CellID: "cell-a", Windows: []uint32{}}, // Empty
			"cell-b": {CellID: "cell-b", Windows: []uint32{}}, // Empty
		},
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

	// No cells have windows, should return empty string
	if result != "" {
		t.Errorf("got %q, want %q (should return empty when no cells have windows)", result, "")
	}
}
