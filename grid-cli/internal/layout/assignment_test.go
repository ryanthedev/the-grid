package layout

import (
	"testing"

	"github.com/yourusername/grid-cli/internal/config"
	"github.com/yourusername/grid-cli/internal/types"
)

func TestAssignAutoFlow(t *testing.T) {
	windows := []Window{
		{ID: 1}, {ID: 2}, {ID: 3}, {ID: 4},
	}
	layout := &types.Layout{
		Cells: []types.Cell{
			{ID: "left"}, {ID: "right"},
		},
	}
	cellBounds := map[string]types.Rect{
		"left":  {X: 0, Y: 0, Width: 500, Height: 1000},
		"right": {X: 500, Y: 0, Width: 500, Height: 1000},
	}

	result := AssignWindows(windows, layout, cellBounds, nil, nil, types.AssignAutoFlow)

	// Expect 2 windows per cell (round-robin)
	if len(result.Assignments["left"]) != 2 {
		t.Errorf("expected 2 windows in left cell, got %d", len(result.Assignments["left"]))
	}
	if len(result.Assignments["right"]) != 2 {
		t.Errorf("expected 2 windows in right cell, got %d", len(result.Assignments["right"]))
	}
}

func TestAssignAutoFlow_UnevenDistribution(t *testing.T) {
	windows := []Window{
		{ID: 1}, {ID: 2}, {ID: 3},
	}
	layout := &types.Layout{
		Cells: []types.Cell{
			{ID: "a"}, {ID: "b"},
		},
	}
	cellBounds := map[string]types.Rect{
		"a": {X: 0, Y: 0, Width: 500, Height: 1000},
		"b": {X: 500, Y: 0, Width: 500, Height: 1000},
	}

	result := AssignWindows(windows, layout, cellBounds, nil, nil, types.AssignAutoFlow)

	// With 3 windows and 2 cells, one gets 2 and one gets 1
	total := len(result.Assignments["a"]) + len(result.Assignments["b"])
	if total != 3 {
		t.Errorf("expected 3 total windows, got %d", total)
	}
}

func TestAssignAutoFlow_Empty(t *testing.T) {
	layout := &types.Layout{
		Cells: []types.Cell{
			{ID: "main"},
		},
	}

	result := AssignWindows(nil, layout, nil, nil, nil, types.AssignAutoFlow)

	if len(result.Assignments["main"]) != 0 {
		t.Error("expected no assignments for empty windows")
	}
}

func TestAssignPinned(t *testing.T) {
	windows := []Window{
		{ID: 1, AppName: "Terminal"},
		{ID: 2, AppName: "Safari"},
		{ID: 3, AppName: "Finder"},
	}
	layout := &types.Layout{
		Cells: []types.Cell{
			{ID: "main"}, {ID: "side"},
		},
	}
	appRules := []config.AppRule{
		{App: "Terminal", PreferredCell: "side"},
	}

	result := AssignWindows(windows, layout, nil, appRules, nil, types.AssignPinned)

	// Terminal should be in side
	found := false
	for _, wid := range result.Assignments["side"] {
		if wid == 1 {
			found = true
			break
		}
	}
	if !found {
		t.Error("Terminal (window 1) should be in side cell")
	}

	// Others should be distributed
	total := len(result.Assignments["main"]) + len(result.Assignments["side"])
	if total != 3 {
		t.Errorf("expected 3 total windows, got %d", total)
	}
}

func TestAssignPinned_NonexistentCell(t *testing.T) {
	windows := []Window{
		{ID: 1, AppName: "Terminal"},
	}
	layout := &types.Layout{
		Cells: []types.Cell{
			{ID: "main"},
		},
	}
	appRules := []config.AppRule{
		{App: "Terminal", PreferredCell: "nonexistent"},
	}

	result := AssignWindows(windows, layout, nil, appRules, nil, types.AssignPinned)

	// Should be assigned to main since preferred cell doesn't exist
	if len(result.Assignments["main"]) != 1 {
		t.Error("window should be in main cell when preferred cell doesn't exist")
	}
}

func TestAssignPreserve(t *testing.T) {
	windows := []Window{
		{ID: 1}, {ID: 2}, {ID: 3},
	}
	layout := &types.Layout{
		Cells: []types.Cell{
			{ID: "a"}, {ID: "b"},
		},
	}
	previous := map[string][]uint32{
		"a": {1, 3},
		"b": {2},
	}

	result := AssignWindows(windows, layout, nil, nil, previous, types.AssignPreserve)

	// Windows should maintain previous cells
	if len(result.Assignments["a"]) != 2 {
		t.Errorf("expected 2 windows in cell a, got %d", len(result.Assignments["a"]))
	}
	if len(result.Assignments["b"]) != 1 {
		t.Errorf("expected 1 window in cell b, got %d", len(result.Assignments["b"]))
	}

	// Check window 1 is in cell a
	found := false
	for _, wid := range result.Assignments["a"] {
		if wid == 1 {
			found = true
			break
		}
	}
	if !found {
		t.Error("window 1 should be preserved in cell a")
	}

	// Check window 2 is in cell b
	found = false
	for _, wid := range result.Assignments["b"] {
		if wid == 2 {
			found = true
			break
		}
	}
	if !found {
		t.Error("window 2 should be preserved in cell b")
	}
}

func TestAssignPreserve_NewWindows(t *testing.T) {
	windows := []Window{
		{ID: 1}, {ID: 2}, {ID: 3}, {ID: 4}, // Window 4 is new
	}
	layout := &types.Layout{
		Cells: []types.Cell{
			{ID: "a"}, {ID: "b"},
		},
	}
	previous := map[string][]uint32{
		"a": {1},
		"b": {2, 3},
	}

	result := AssignWindows(windows, layout, nil, nil, previous, types.AssignPreserve)

	// Total should be 4
	total := len(result.Assignments["a"]) + len(result.Assignments["b"])
	if total != 4 {
		t.Errorf("expected 4 total windows, got %d", total)
	}

	// New window should be assigned to least populated cell
	if len(result.Assignments["a"]) != 2 {
		t.Error("new window should be assigned to cell a (least populated)")
	}
}

func TestAssignPreserve_CellRemoved(t *testing.T) {
	windows := []Window{
		{ID: 1}, {ID: 2},
	}
	layout := &types.Layout{
		Cells: []types.Cell{
			{ID: "a"}, // Cell "b" removed
		},
	}
	previous := map[string][]uint32{
		"a": {1},
		"b": {2}, // This cell no longer exists
	}

	result := AssignWindows(windows, layout, nil, nil, previous, types.AssignPreserve)

	// Window 2 should be reassigned to remaining cell
	if len(result.Assignments["a"]) != 2 {
		t.Errorf("expected 2 windows in cell a, got %d", len(result.Assignments["a"]))
	}
}

func TestFloatingWindows(t *testing.T) {
	windows := []Window{
		{ID: 1, AppName: "Finder"},
		{ID: 2, AppName: "Safari"},
	}
	layout := &types.Layout{
		Cells: []types.Cell{
			{ID: "main"},
		},
	}
	appRules := []config.AppRule{
		{App: "Finder", Float: true},
	}

	result := AssignWindows(windows, layout, nil, appRules, nil, types.AssignAutoFlow)

	// Finder should be floating
	if len(result.Floating) != 1 || result.Floating[0] != 1 {
		t.Error("Finder (window 1) should be floating")
	}

	// Safari should be in main
	if len(result.Assignments["main"]) != 1 || result.Assignments["main"][0] != 2 {
		t.Error("Safari (window 2) should be in main cell")
	}
}

func TestExcludedWindows_Minimized(t *testing.T) {
	windows := []Window{
		{ID: 1, IsMinimized: true},
		{ID: 2, IsMinimized: false},
	}
	layout := &types.Layout{
		Cells: []types.Cell{
			{ID: "main"},
		},
	}

	result := AssignWindows(windows, layout, nil, nil, nil, types.AssignAutoFlow)

	// Minimized window should be excluded
	if len(result.Excluded) != 1 || result.Excluded[0] != 1 {
		t.Error("minimized window should be excluded")
	}

	// Normal window should be assigned
	if len(result.Assignments["main"]) != 1 {
		t.Error("non-minimized window should be assigned")
	}
}

func TestExcludedWindows_Hidden(t *testing.T) {
	windows := []Window{
		{ID: 1, IsHidden: true},
		{ID: 2, IsHidden: false},
	}
	layout := &types.Layout{
		Cells: []types.Cell{
			{ID: "main"},
		},
	}

	result := AssignWindows(windows, layout, nil, nil, nil, types.AssignAutoFlow)

	if len(result.Excluded) != 1 || result.Excluded[0] != 1 {
		t.Error("hidden window should be excluded")
	}
}

func TestExcludedWindows_HighLevel(t *testing.T) {
	windows := []Window{
		{ID: 1, Level: 0}, // Normal
		{ID: 2, Level: 1}, // Overlay
	}
	layout := &types.Layout{
		Cells: []types.Cell{
			{ID: "main"},
		},
	}

	result := AssignWindows(windows, layout, nil, nil, nil, types.AssignAutoFlow)

	if len(result.Excluded) != 1 || result.Excluded[0] != 2 {
		t.Error("high-level window should be excluded")
	}
}

func TestShouldFloat(t *testing.T) {
	rules := []config.AppRule{
		{App: "Finder", Float: true},
		{App: "com.apple.Safari", Float: false},
	}

	tests := []struct {
		window Window
		want   bool
	}{
		{Window{AppName: "Finder"}, true},
		{Window{BundleID: "com.apple.finder"}, false}, // Case matters
		{Window{AppName: "Safari"}, false},
		{Window{AppName: "Terminal"}, false},
	}

	for _, tt := range tests {
		got := shouldFloat(tt.window, rules)
		if got != tt.want {
			t.Errorf("shouldFloat(%q) = %v, want %v", tt.window.AppName, got, tt.want)
		}
	}
}

func TestShouldExclude(t *testing.T) {
	tests := []struct {
		name   string
		window Window
		want   bool
	}{
		{"normal", Window{}, false},
		{"minimized", Window{IsMinimized: true}, true},
		{"hidden", Window{IsHidden: true}, true},
		{"level 1", Window{Level: 1}, true},
		{"level 0", Window{Level: 0}, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := shouldExclude(tt.window)
			if got != tt.want {
				t.Errorf("shouldExclude() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestFindLeastPopulatedCell(t *testing.T) {
	assignments := map[string][]uint32{
		"a": {1, 2, 3},
		"b": {4},
		"c": {5, 6},
	}

	result := findLeastPopulatedCell(assignments)
	if result != "b" {
		t.Errorf("expected 'b' (least populated), got %q", result)
	}
}

func TestFindLeastPopulatedCell_Tie(t *testing.T) {
	assignments := map[string][]uint32{
		"b": {1},
		"a": {2},
		"c": {3, 4},
	}

	// With alphabetical tiebreaker, "a" should win
	result := findLeastPopulatedCell(assignments)
	if result != "a" {
		t.Errorf("expected 'a' (alphabetically first in tie), got %q", result)
	}
}

func TestGetPreferredCell(t *testing.T) {
	rules := []config.AppRule{
		{App: "Terminal", PreferredCell: "side"},
		{App: "Safari", PreferredCell: "main"},
	}

	tests := []struct {
		window Window
		want   string
	}{
		{Window{AppName: "Terminal"}, "side"},
		{Window{AppName: "Safari"}, "main"},
		{Window{AppName: "Finder"}, ""},
	}

	for _, tt := range tests {
		got := GetPreferredCell(tt.window, rules)
		if got != tt.want {
			t.Errorf("GetPreferredCell(%q) = %q, want %q", tt.window.AppName, got, tt.want)
		}
	}
}

func TestAssignmentResult_InitializedMaps(t *testing.T) {
	layout := &types.Layout{
		Cells: []types.Cell{
			{ID: "a"}, {ID: "b"}, {ID: "c"},
		},
	}

	result := AssignWindows(nil, layout, nil, nil, nil, types.AssignAutoFlow)

	// All cells should have initialized (empty) slices
	for _, cellID := range []string{"a", "b", "c"} {
		if result.Assignments[cellID] == nil {
			t.Errorf("cell %q should have initialized slice, not nil", cellID)
		}
	}
}
