package state

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/yourusername/grid-cli/internal/types"
)

// === State Tests ===

func TestNewRuntimeState(t *testing.T) {
	state := NewRuntimeState()

	if state.Version != StateVersion {
		t.Errorf("Version = %d, want %d", state.Version, StateVersion)
	}
	if state.Spaces == nil {
		t.Error("Spaces should not be nil")
	}
	if len(state.Spaces) != 0 {
		t.Error("Spaces should be empty")
	}
}

func TestNewSpaceState(t *testing.T) {
	space := NewSpaceState("test-space")

	if space.SpaceID != "test-space" {
		t.Errorf("SpaceID = %q, want %q", space.SpaceID, "test-space")
	}
	if space.Cells == nil {
		t.Error("Cells should not be nil")
	}
	if space.LayoutIndex != 0 {
		t.Error("LayoutIndex should be 0")
	}
}

func TestGetSpace(t *testing.T) {
	state := NewRuntimeState()

	// First call should create the space
	space1 := state.GetSpace("1")
	if space1 == nil {
		t.Fatal("GetSpace returned nil")
	}
	if space1.SpaceID != "1" {
		t.Errorf("SpaceID = %q, want %q", space1.SpaceID, "1")
	}

	// Second call should return the same space
	space2 := state.GetSpace("1")
	if space1 != space2 {
		t.Error("GetSpace should return same instance")
	}
}

func TestGetSpaceReadOnly(t *testing.T) {
	state := NewRuntimeState()

	// Should return nil for non-existent space
	space := state.GetSpaceReadOnly("1")
	if space != nil {
		t.Error("GetSpaceReadOnly should return nil for non-existent space")
	}

	// Create the space
	state.GetSpace("1")

	// Now should return it
	space = state.GetSpaceReadOnly("1")
	if space == nil {
		t.Error("GetSpaceReadOnly should return space after creation")
	}
}

func TestRemoveSpace(t *testing.T) {
	state := NewRuntimeState()
	state.GetSpace("1")

	state.RemoveSpace("1")

	if state.GetSpaceReadOnly("1") != nil {
		t.Error("Space should be removed")
	}
}

func TestWindowAssignment(t *testing.T) {
	state := NewRuntimeState()
	space := state.GetSpace("1")

	// Assign windows to a cell
	space.AssignWindow(123, "left")
	space.AssignWindow(456, "left")

	cell := space.Cells["left"]
	if cell == nil {
		t.Fatal("Cell should be created")
	}
	if len(cell.Windows) != 2 {
		t.Errorf("expected 2 windows, got %d", len(cell.Windows))
	}

	// Verify split ratios are equal
	if len(cell.SplitRatios) != 2 {
		t.Errorf("expected 2 split ratios, got %d", len(cell.SplitRatios))
	}
	if cell.SplitRatios[0] != 0.5 || cell.SplitRatios[1] != 0.5 {
		t.Error("split ratios should be equal")
	}
}

func TestWindowAssignment_Move(t *testing.T) {
	state := NewRuntimeState()
	space := state.GetSpace("1")

	space.AssignWindow(123, "left")
	space.AssignWindow(456, "left")

	// Move window 123 to right
	space.AssignWindow(123, "right")

	// Left should have 1 window
	if len(space.Cells["left"].Windows) != 1 {
		t.Errorf("left cell should have 1 window, got %d", len(space.Cells["left"].Windows))
	}
	// Right should have 1 window
	if len(space.Cells["right"].Windows) != 1 {
		t.Errorf("right cell should have 1 window, got %d", len(space.Cells["right"].Windows))
	}
}

func TestWindowAssignment_Duplicate(t *testing.T) {
	state := NewRuntimeState()
	space := state.GetSpace("1")

	space.AssignWindow(123, "left")
	space.AssignWindow(123, "left") // Assign same window again

	// Should still have only 1 window
	if len(space.Cells["left"].Windows) != 1 {
		t.Errorf("expected 1 window (no duplicates), got %d", len(space.Cells["left"].Windows))
	}
}

func TestRemoveWindow(t *testing.T) {
	state := NewRuntimeState()
	space := state.GetSpace("1")

	space.AssignWindow(123, "left")
	space.AssignWindow(456, "left")

	space.RemoveWindow(123)

	cell := space.Cells["left"]
	if len(cell.Windows) != 1 {
		t.Errorf("expected 1 window after removal, got %d", len(cell.Windows))
	}
	if cell.Windows[0] != 456 {
		t.Error("wrong window remaining")
	}
	// Split ratio should be updated to 1.0
	if len(cell.SplitRatios) != 1 || cell.SplitRatios[0] != 1.0 {
		t.Error("split ratios not updated after removal")
	}
}

func TestGetWindowCell(t *testing.T) {
	state := NewRuntimeState()
	space := state.GetSpace("1")

	space.AssignWindow(123, "left")
	space.AssignWindow(456, "right")

	if cellID := space.GetWindowCell(123); cellID != "left" {
		t.Errorf("GetWindowCell(123) = %q, want %q", cellID, "left")
	}
	if cellID := space.GetWindowCell(456); cellID != "right" {
		t.Errorf("GetWindowCell(456) = %q, want %q", cellID, "right")
	}
	if cellID := space.GetWindowCell(999); cellID != "" {
		t.Errorf("GetWindowCell(999) = %q, want empty", cellID)
	}
}

func TestLayoutCycling(t *testing.T) {
	state := NewRuntimeState()
	space := state.GetSpace("1")
	space.SetCurrentLayout("layout1", 0)

	layouts := []string{"layout1", "layout2", "layout3"}

	// Cycle forward
	next := space.CycleLayout(layouts)
	if next != "layout2" {
		t.Errorf("expected layout2, got %s", next)
	}

	next = space.CycleLayout(layouts)
	if next != "layout3" {
		t.Errorf("expected layout3, got %s", next)
	}

	// Should wrap around
	next = space.CycleLayout(layouts)
	if next != "layout1" {
		t.Errorf("expected layout1 (wrap), got %s", next)
	}
}

func TestLayoutCycling_Previous(t *testing.T) {
	state := NewRuntimeState()
	space := state.GetSpace("1")
	space.SetCurrentLayout("layout1", 0)

	layouts := []string{"layout1", "layout2", "layout3"}

	// Cycle backward should wrap
	prev := space.PreviousLayout(layouts)
	if prev != "layout3" {
		t.Errorf("expected layout3 (wrap), got %s", prev)
	}

	prev = space.PreviousLayout(layouts)
	if prev != "layout2" {
		t.Errorf("expected layout2, got %s", prev)
	}
}

func TestLayoutCycling_Empty(t *testing.T) {
	state := NewRuntimeState()
	space := state.GetSpace("1")
	space.SetCurrentLayout("existing", 0)

	// Should return current layout when no layouts available
	next := space.CycleLayout(nil)
	if next != "existing" {
		t.Errorf("expected existing layout, got %s", next)
	}
}

func TestSetFocus(t *testing.T) {
	state := NewRuntimeState()
	space := state.GetSpace("1")

	space.AssignWindow(123, "left")
	space.AssignWindow(456, "left")
	space.SetFocus("left", 1)

	if space.FocusedCell != "left" {
		t.Errorf("FocusedCell = %q, want %q", space.FocusedCell, "left")
	}
	if space.FocusedWindow != 1 {
		t.Errorf("FocusedWindow = %d, want 1", space.FocusedWindow)
	}
}

func TestGetFocusedWindow(t *testing.T) {
	state := NewRuntimeState()
	space := state.GetSpace("1")

	// No focus set
	if wid := space.GetFocusedWindow(); wid != 0 {
		t.Errorf("expected 0 for no focus, got %d", wid)
	}

	space.AssignWindow(123, "left")
	space.AssignWindow(456, "left")
	space.SetFocus("left", 1)

	if wid := space.GetFocusedWindow(); wid != 456 {
		t.Errorf("expected 456, got %d", wid)
	}
}

func TestGetFocusedWindow_InvalidIndex(t *testing.T) {
	state := NewRuntimeState()
	space := state.GetSpace("1")

	space.AssignWindow(123, "left")
	space.SetFocus("left", 99) // Invalid index

	// Should return first window
	if wid := space.GetFocusedWindow(); wid != 123 {
		t.Errorf("expected 123 (first window), got %d", wid)
	}
}

func TestSplitRatios(t *testing.T) {
	state := NewRuntimeState()
	space := state.GetSpace("1")

	space.AssignWindow(1, "cell")
	ratios := space.Cells["cell"].SplitRatios
	if len(ratios) != 1 || ratios[0] != 1.0 {
		t.Error("expected [1.0] for single window")
	}

	space.AssignWindow(2, "cell")
	ratios = space.Cells["cell"].SplitRatios
	if len(ratios) != 2 || ratios[0] != 0.5 || ratios[1] != 0.5 {
		t.Error("expected [0.5, 0.5] for two windows")
	}

	space.AssignWindow(3, "cell")
	ratios = space.Cells["cell"].SplitRatios
	if len(ratios) != 3 {
		t.Error("expected 3 ratios for three windows")
	}
	// Each should be ~0.333
	for _, r := range ratios {
		if r < 0.33 || r > 0.34 {
			t.Errorf("expected ~0.333, got %f", r)
		}
	}

	// Remove one
	space.RemoveWindow(2)
	ratios = space.Cells["cell"].SplitRatios
	if len(ratios) != 2 || ratios[0] != 0.5 {
		t.Error("expected [0.5, 0.5] after removal")
	}
}

// === Persistence Tests ===

func TestLoadState_NoFile(t *testing.T) {
	state, err := LoadStateFrom("/nonexistent/path/to/state.json")
	if err != nil {
		t.Fatal(err)
	}
	if len(state.Spaces) != 0 {
		t.Error("expected empty state for nonexistent file")
	}
}

func TestSaveAndLoad(t *testing.T) {
	tmpDir := t.TempDir()
	tmpFile := filepath.Join(tmpDir, "state.json")

	state := NewRuntimeState()
	space := state.GetSpace("1")
	space.SetCurrentLayout("two-column", 0)
	space.AssignWindow(123, "left")
	space.AssignWindow(456, "right")

	if err := state.SaveTo(tmpFile); err != nil {
		t.Fatal(err)
	}

	loaded, err := LoadStateFrom(tmpFile)
	if err != nil {
		t.Fatal(err)
	}

	if loaded.Spaces["1"].CurrentLayoutID != "two-column" {
		t.Error("layout not preserved")
	}
	if len(loaded.Spaces["1"].Cells["left"].Windows) != 1 {
		t.Error("left cell windows not preserved")
	}
	if loaded.Spaces["1"].Cells["left"].Windows[0] != 123 {
		t.Error("window ID not preserved")
	}
}

func TestSave_CreatesDirectory(t *testing.T) {
	tmpDir := t.TempDir()
	nestedPath := filepath.Join(tmpDir, "nested", "dirs", "state.json")

	state := NewRuntimeState()
	if err := state.SaveTo(nestedPath); err != nil {
		t.Fatal(err)
	}

	// Verify file was created
	if _, err := os.Stat(nestedPath); os.IsNotExist(err) {
		t.Error("state file was not created")
	}
}

func TestReset(t *testing.T) {
	tmpDir := t.TempDir()
	tmpFile := filepath.Join(tmpDir, "state.json")

	state := NewRuntimeState()
	state.GetSpace("1").AssignWindow(123, "left")
	state.SaveTo(tmpFile)

	if err := state.Reset(); err != nil {
		t.Fatal(err)
	}

	if len(state.Spaces) != 0 {
		t.Error("Spaces should be empty after reset")
	}
}

// === Query Tests ===

func TestGetAllWindowIDs(t *testing.T) {
	state := NewRuntimeState()

	space1 := state.GetSpace("1")
	space1.AssignWindow(123, "left")
	space1.AssignWindow(456, "right")

	space2 := state.GetSpace("2")
	space2.AssignWindow(789, "main")

	ids := state.GetAllWindowIDs()
	if len(ids) != 3 {
		t.Errorf("expected 3 window IDs, got %d", len(ids))
	}

	// Verify all IDs are present
	idSet := make(map[uint32]bool)
	for _, id := range ids {
		idSet[id] = true
	}
	if !idSet[123] || !idSet[456] || !idSet[789] {
		t.Error("missing window ID")
	}
}

func TestGetCellWindows(t *testing.T) {
	state := NewRuntimeState()
	space := state.GetSpace("1")
	space.AssignWindow(123, "left")
	space.AssignWindow(456, "left")

	windows := state.GetCellWindows("1", "left")
	if len(windows) != 2 {
		t.Errorf("expected 2 windows, got %d", len(windows))
	}

	// Non-existent space/cell
	if state.GetCellWindows("99", "left") != nil {
		t.Error("expected nil for non-existent space")
	}
	if state.GetCellWindows("1", "nonexistent") != nil {
		t.Error("expected nil for non-existent cell")
	}
}

func TestGetCellSplitRatios(t *testing.T) {
	state := NewRuntimeState()
	space := state.GetSpace("1")
	space.AssignWindow(123, "left")
	space.AssignWindow(456, "left")

	ratios := state.GetCellSplitRatios("1", "left")
	if len(ratios) != 2 {
		t.Errorf("expected 2 ratios, got %d", len(ratios))
	}
}

func TestGetCellStackMode(t *testing.T) {
	state := NewRuntimeState()
	space := state.GetSpace("1")
	cell := space.GetCell("left")
	cell.StackMode = types.StackTabs

	mode := state.GetCellStackMode("1", "left")
	if mode != types.StackTabs {
		t.Errorf("expected tabs, got %q", mode)
	}

	// Non-existent returns empty
	if state.GetCellStackMode("1", "nonexistent") != "" {
		t.Error("expected empty for non-existent cell")
	}
}

func TestSetCellStackMode(t *testing.T) {
	state := NewRuntimeState()

	state.SetCellStackMode("1", "left", types.StackHorizontal)

	mode := state.GetCellStackMode("1", "left")
	if mode != types.StackHorizontal {
		t.Errorf("expected horizontal, got %q", mode)
	}
}

func TestGetCurrentLayoutForSpace(t *testing.T) {
	state := NewRuntimeState()
	space := state.GetSpace("1")
	space.SetCurrentLayout("my-layout", 0)

	layout := state.GetCurrentLayoutForSpace("1")
	if layout != "my-layout" {
		t.Errorf("expected my-layout, got %q", layout)
	}

	// Non-existent space
	if state.GetCurrentLayoutForSpace("99") != "" {
		t.Error("expected empty for non-existent space")
	}
}

func TestGetWindowAssignments(t *testing.T) {
	state := NewRuntimeState()
	space := state.GetSpace("1")
	space.AssignWindow(123, "left")
	space.AssignWindow(456, "left")
	space.AssignWindow(789, "right")

	assignments := state.GetWindowAssignments("1")
	if len(assignments) != 2 {
		t.Errorf("expected 2 cells with assignments, got %d", len(assignments))
	}
	if len(assignments["left"]) != 2 {
		t.Error("expected 2 windows in left")
	}
	if len(assignments["right"]) != 1 {
		t.Error("expected 1 window in right")
	}
}

func TestSetWindowAssignments(t *testing.T) {
	state := NewRuntimeState()

	assignments := map[string][]uint32{
		"left":  {123, 456},
		"right": {789},
	}
	state.SetWindowAssignments("1", assignments)

	// Verify
	result := state.GetWindowAssignments("1")
	if len(result["left"]) != 2 {
		t.Error("left cell not set correctly")
	}
	if len(result["right"]) != 1 {
		t.Error("right cell not set correctly")
	}
}

func TestHasState(t *testing.T) {
	state := NewRuntimeState()

	if state.HasState("1") {
		t.Error("should have no state initially")
	}

	space := state.GetSpace("1")
	space.SetCurrentLayout("test", 0)

	if !state.HasState("1") {
		t.Error("should have state after setting layout")
	}
}

func TestSummary(t *testing.T) {
	state := NewRuntimeState()
	space := state.GetSpace("1")
	space.SetCurrentLayout("test-layout", 0)
	space.AssignWindow(123, "left")
	space.SetFocus("left", 0)

	summary := state.Summary()

	if summary["version"] != StateVersion {
		t.Error("version not in summary")
	}
	if summary["spaceCount"] != 1 {
		t.Error("spaceCount incorrect")
	}

	spaces := summary["spaces"].(map[string]interface{})
	space1 := spaces["1"].(map[string]interface{})
	if space1["currentLayout"] != "test-layout" {
		t.Error("currentLayout not in summary")
	}
	if space1["windowCount"] != 1 {
		t.Error("windowCount incorrect")
	}
}
