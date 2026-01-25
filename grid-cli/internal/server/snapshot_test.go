package server

import (
	"testing"

	"github.com/ryanthedev/grid-cli/internal/config"
	"github.com/ryanthedev/grid-cli/internal/types"
)

func TestParseWindowWithRoleSubrole(t *testing.T) {
	raw := map[string]interface{}{
		"metadata": map[string]interface{}{
			"activeSpaceID":     3,
			"focusedWindowID":   100,
			"activeDisplayUUID": "test-display",
		},
		"displays": []interface{}{
			map[string]interface{}{
				"uuid":           "test-display",
				"currentSpaceID": 3,
				"isMain":         true,
				"frame":          []interface{}{[]interface{}{0, 0}, []interface{}{1920, 1080}},
				"visibleFrame":   []interface{}{[]interface{}{0, 25}, []interface{}{1920, 1055}},
			},
		},
		"spaces": map[string]interface{}{
			"3": map[string]interface{}{
				"id":          3,
				"displayUUID": "test-display",
				"type":        "user",
			},
		},
		"windows": map[string]interface{}{
			"100": map[string]interface{}{
				"id":      100,
				"appName": "Chrome",
				"title":   "Test",
				"frame":   []interface{}{[]interface{}{0, 0}, []interface{}{100, 100}},
				"level":   0,
				"spaces":  []interface{}{3},
				"role":    "AXWindow",
				"subrole": "AXStandardWindow",
			},
			"101": map[string]interface{}{
				"id":      101,
				"appName": "Chrome",
				"title":   "Tooltip",
				"frame":   []interface{}{[]interface{}{50, 50}, []interface{}{80, 20}},
				"level":   0,
				"spaces":  []interface{}{3},
				"role":    "AXHelpTag",
				"subrole": "AXUnknown",
			},
		},
	}

	snap, err := parseSnapshot(raw)
	if err != nil {
		t.Fatalf("parseSnapshot failed: %v", err)
	}

	// Find the tooltip window
	var tooltipWindow *WindowInfo
	for i := range snap.Windows {
		if snap.Windows[i].ID == 101 {
			tooltipWindow = &snap.Windows[i]
			break
		}
	}

	if tooltipWindow == nil {
		t.Fatal("tooltip window not found")
	}

	if tooltipWindow.Role != "AXHelpTag" {
		t.Errorf("expected role AXHelpTag, got %s", tooltipWindow.Role)
	}
	if tooltipWindow.Subrole != "AXUnknown" {
		t.Errorf("expected subrole AXUnknown, got %s", tooltipWindow.Subrole)
	}
}

func TestWindowInfoIsExcluded(t *testing.T) {
	exclusions := config.WindowExclusion{
		Roles:    []string{"AXHelpTag"},
		Subroles: []string{"AXDialog"},
		Apps:     []string{"Dock"},
	}

	tests := []struct {
		name     string
		window   WindowInfo
		expected bool
	}{
		{
			name:     "normal window not excluded",
			window:   WindowInfo{Role: "AXWindow", Subrole: "AXStandardWindow", AppName: "Chrome"},
			expected: false,
		},
		{
			name:     "tooltip excluded by role",
			window:   WindowInfo{Role: "AXHelpTag", Subrole: "AXUnknown", AppName: "Chrome"},
			expected: true,
		},
		{
			name:     "dialog excluded by subrole",
			window:   WindowInfo{Role: "AXWindow", Subrole: "AXDialog", AppName: "Chrome"},
			expected: true,
		},
		{
			name:     "dock excluded by app",
			window:   WindowInfo{Role: "AXWindow", Subrole: "AXStandardWindow", AppName: "Dock"},
			expected: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.window.IsExcluded(exclusions); got != tt.expected {
				t.Errorf("IsExcluded() = %v, want %v", got, tt.expected)
			}
		})
	}
}

func TestParseWindowZOrder(t *testing.T) {
	tests := []struct {
		name     string
		raw      map[string]interface{}
		wantZOrder int
	}{
		{
			name: "zOrder present",
			raw: map[string]interface{}{
				"metadata": map[string]interface{}{
					"activeSpaceID":     3,
					"focusedWindowID":   100,
					"activeDisplayUUID": "test-display",
				},
				"displays": []interface{}{
					map[string]interface{}{
						"uuid":           "test-display",
						"currentSpaceID": 3,
						"isMain":         true,
						"frame":          []interface{}{[]interface{}{0, 0}, []interface{}{1920, 1080}},
						"visibleFrame":   []interface{}{[]interface{}{0, 25}, []interface{}{1920, 1055}},
					},
				},
				"spaces": map[string]interface{}{
					"3": map[string]interface{}{
						"id":          3,
						"displayUUID": "test-display",
						"type":        "user",
					},
				},
				"windows": map[string]interface{}{
					"100": map[string]interface{}{
						"id":      100,
						"appName": "Chrome",
						"title":   "Test",
						"frame":   []interface{}{[]interface{}{0, 0}, []interface{}{100, 100}},
						"level":   0,
						"spaces":  []interface{}{3},
						"role":    "AXWindow",
						"subrole": "AXStandardWindow",
						"zOrder":  5,
					},
				},
			},
			wantZOrder: 5,
		},
		{
			name: "zOrder zero (frontmost)",
			raw: map[string]interface{}{
				"metadata": map[string]interface{}{
					"activeSpaceID":     3,
					"focusedWindowID":   100,
					"activeDisplayUUID": "test-display",
				},
				"displays": []interface{}{
					map[string]interface{}{
						"uuid":           "test-display",
						"currentSpaceID": 3,
						"isMain":         true,
						"frame":          []interface{}{[]interface{}{0, 0}, []interface{}{1920, 1080}},
						"visibleFrame":   []interface{}{[]interface{}{0, 25}, []interface{}{1920, 1055}},
					},
				},
				"spaces": map[string]interface{}{
					"3": map[string]interface{}{
						"id":          3,
						"displayUUID": "test-display",
						"type":        "user",
					},
				},
				"windows": map[string]interface{}{
					"100": map[string]interface{}{
						"id":      100,
						"appName": "Chrome",
						"title":   "Test",
						"frame":   []interface{}{[]interface{}{0, 0}, []interface{}{100, 100}},
						"level":   0,
						"spaces":  []interface{}{3},
						"role":    "AXWindow",
						"subrole": "AXStandardWindow",
						"zOrder":  0,
					},
				},
			},
			wantZOrder: 0,
		},
		{
			name: "zOrder missing defaults to 0",
			raw: map[string]interface{}{
				"metadata": map[string]interface{}{
					"activeSpaceID":     3,
					"focusedWindowID":   100,
					"activeDisplayUUID": "test-display",
				},
				"displays": []interface{}{
					map[string]interface{}{
						"uuid":           "test-display",
						"currentSpaceID": 3,
						"isMain":         true,
						"frame":          []interface{}{[]interface{}{0, 0}, []interface{}{1920, 1080}},
						"visibleFrame":   []interface{}{[]interface{}{0, 25}, []interface{}{1920, 1055}},
					},
				},
				"spaces": map[string]interface{}{
					"3": map[string]interface{}{
						"id":          3,
						"displayUUID": "test-display",
						"type":        "user",
					},
				},
				"windows": map[string]interface{}{
					"100": map[string]interface{}{
						"id":      100,
						"appName": "Chrome",
						"title":   "Test",
						"frame":   []interface{}{[]interface{}{0, 0}, []interface{}{100, 100}},
						"level":   0,
						"spaces":  []interface{}{3},
						"role":    "AXWindow",
						"subrole": "AXStandardWindow",
						// zOrder intentionally missing
					},
				},
			},
			wantZOrder: 0,
		},
		{
			name: "zOrder large value (off-screen)",
			raw: map[string]interface{}{
				"metadata": map[string]interface{}{
					"activeSpaceID":     3,
					"focusedWindowID":   100,
					"activeDisplayUUID": "test-display",
				},
				"displays": []interface{}{
					map[string]interface{}{
						"uuid":           "test-display",
						"currentSpaceID": 3,
						"isMain":         true,
						"frame":          []interface{}{[]interface{}{0, 0}, []interface{}{1920, 1080}},
						"visibleFrame":   []interface{}{[]interface{}{0, 25}, []interface{}{1920, 1055}},
					},
				},
				"spaces": map[string]interface{}{
					"3": map[string]interface{}{
						"id":          3,
						"displayUUID": "test-display",
						"type":        "user",
					},
				},
				"windows": map[string]interface{}{
					"100": map[string]interface{}{
						"id":      100,
						"appName": "Chrome",
						"title":   "Test",
						"frame":   []interface{}{[]interface{}{0, 0}, []interface{}{100, 100}},
						"level":   0,
						"spaces":  []interface{}{3},
						"role":    "AXWindow",
						"subrole": "AXStandardWindow",
						"zOrder":  2147483647,
					},
				},
			},
			wantZOrder: 2147483647,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			snap, err := parseSnapshot(tt.raw)
			if err != nil {
				t.Fatalf("parseSnapshot failed: %v", err)
			}

			if len(snap.Windows) == 0 {
				t.Fatal("no windows parsed")
			}

			var window *WindowInfo
			for i := range snap.Windows {
				if snap.Windows[i].ID == 100 {
					window = &snap.Windows[i]
					break
				}
			}

			if window == nil {
				t.Fatal("window 100 not found")
			}

			if window.ZOrder != tt.wantZOrder {
				t.Errorf("ZOrder = %d, want %d", window.ZOrder, tt.wantZOrder)
			}
		})
	}
}

func TestParseWindowZOrderMultiple(t *testing.T) {
	raw := map[string]interface{}{
		"metadata": map[string]interface{}{
			"activeSpaceID":     3,
			"focusedWindowID":   100,
			"activeDisplayUUID": "test-display",
		},
		"displays": []interface{}{
			map[string]interface{}{
				"uuid":           "test-display",
				"currentSpaceID": 3,
				"isMain":         true,
				"frame":          []interface{}{[]interface{}{0, 0}, []interface{}{1920, 1080}},
				"visibleFrame":   []interface{}{[]interface{}{0, 25}, []interface{}{1920, 1055}},
			},
		},
		"spaces": map[string]interface{}{
			"3": map[string]interface{}{
				"id":          3,
				"displayUUID": "test-display",
				"type":        "user",
			},
		},
		"windows": map[string]interface{}{
			"100": map[string]interface{}{
				"id":      100,
				"appName": "Chrome",
				"title":   "Frontmost",
				"frame":   []interface{}{[]interface{}{0, 0}, []interface{}{100, 100}},
				"level":   0,
				"spaces":  []interface{}{3},
				"role":    "AXWindow",
				"subrole": "AXStandardWindow",
				"zOrder":  0,
			},
			"101": map[string]interface{}{
				"id":      101,
				"appName": "Safari",
				"title":   "Middle",
				"frame":   []interface{}{[]interface{}{50, 50}, []interface{}{100, 100}},
				"level":   0,
				"spaces":  []interface{}{3},
				"role":    "AXWindow",
				"subrole": "AXStandardWindow",
				"zOrder":  1,
			},
			"102": map[string]interface{}{
				"id":      102,
				"appName": "Code",
				"title":   "Back",
				"frame":   []interface{}{[]interface{}{100, 100}, []interface{}{100, 100}},
				"level":   0,
				"spaces":  []interface{}{3},
				"role":    "AXWindow",
				"subrole": "AXStandardWindow",
				"zOrder":  2,
			},
		},
	}

	snap, err := parseSnapshot(raw)
	if err != nil {
		t.Fatalf("parseSnapshot failed: %v", err)
	}

	if len(snap.Windows) != 3 {
		t.Fatalf("expected 3 windows, got %d", len(snap.Windows))
	}

	zOrders := make(map[uint32]int)
	for _, w := range snap.Windows {
		zOrders[w.ID] = w.ZOrder
	}

	if zOrders[100] != 0 {
		t.Errorf("window 100 zOrder = %d, want 0", zOrders[100])
	}
	if zOrders[101] != 1 {
		t.Errorf("window 101 zOrder = %d, want 1", zOrders[101])
	}
	if zOrders[102] != 2 {
		t.Errorf("window 102 zOrder = %d, want 2", zOrders[102])
	}
}

func TestSnapshotFilterTileable(t *testing.T) {
	// Windows need valid frames (>= MinTileableDimension) to be tileable
	validFrame := types.Rect{X: 0, Y: 0, Width: 800, Height: 600}
	snap := &Snapshot{
		Windows: []WindowInfo{
			{ID: 1, Role: "AXWindow", Subrole: "AXStandardWindow", AppName: "Chrome", Frame: validFrame},
			{ID: 2, Role: "AXHelpTag", Subrole: "AXUnknown", AppName: "Chrome", Frame: validFrame},                       // Tooltip
			{ID: 3, Role: "AXWindow", Subrole: "AXStandardWindow", AppName: "Dock", Frame: validFrame},                   // Excluded app
			{ID: 4, Role: "AXWindow", Subrole: "AXStandardWindow", AppName: "Code", Frame: validFrame, IsMinimized: true}, // Minimized
		},
	}

	exclusions := config.WindowExclusion{
		Roles: []string{"AXHelpTag"},
		Apps:  []string{"Dock"},
	}

	tileable := snap.FilterTileable(exclusions)

	if len(tileable) != 1 {
		t.Errorf("expected 1 tileable window, got %d", len(tileable))
	}
	if tileable[0].ID != 1 {
		t.Errorf("expected window ID 1, got %d", tileable[0].ID)
	}
}
