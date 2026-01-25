package layout

import (
	"testing"

	"github.com/ryanthedev/grid-cli/internal/server"
	"github.com/ryanthedev/grid-cli/internal/types"
)

func TestConvertWindows_ZOrderCopied(t *testing.T) {
	windows := []server.WindowInfo{
		{ID: 1, ZOrder: 0, AppName: "Chrome", Title: "Frontmost"},
		{ID: 2, ZOrder: 5, AppName: "Safari", Title: "Middle"},
		{ID: 3, ZOrder: 2147483647, AppName: "Code", Title: "Off-screen"},
	}

	result := convertWindows(windows)

	if len(result) != 3 {
		t.Fatalf("expected 3 windows, got %d", len(result))
	}

	tests := []struct {
		id       uint32
		wantZOrder int
	}{
		{1, 0},
		{2, 5},
		{3, 2147483647},
	}

	for _, tt := range tests {
		var found *Window
		for i := range result {
			if result[i].ID == tt.id {
				found = &result[i]
				break
			}
		}
		if found == nil {
			t.Errorf("window %d not found", tt.id)
			continue
		}
		if found.ZOrder != tt.wantZOrder {
			t.Errorf("window %d ZOrder = %d, want %d", tt.id, found.ZOrder, tt.wantZOrder)
		}
	}
}

func TestConvertWindows_ZOrderZero(t *testing.T) {
	windows := []server.WindowInfo{
		{ID: 1, ZOrder: 0},
	}

	result := convertWindows(windows)

	if len(result) != 1 {
		t.Fatalf("expected 1 window, got %d", len(result))
	}
	if result[0].ZOrder != 0 {
		t.Errorf("ZOrder = %d, want 0", result[0].ZOrder)
	}
}

func TestConvertWindows_Empty(t *testing.T) {
	result := convertWindows(nil)

	if result == nil {
		t.Error("result should not be nil")
	}
	if len(result) != 0 {
		t.Errorf("expected empty slice, got %d windows", len(result))
	}
}

func TestConvertWindows_AllFieldsCopied(t *testing.T) {
	windows := []server.WindowInfo{
		{
			ID:                  42,
			AppName:             "TestApp",
			BundleID:            "com.test.app",
			Title:               "Test Title",
			Frame:               types.Rect{X: 10, Y: 20, Width: 800, Height: 600},
			Level:               0,
			ZOrder:              7,
			IsMinimized:         false,
			IsHidden:            false,
			Role:                "AXWindow",
			Subrole:             "AXStandardWindow",
			HasCloseButton:      true,
			HasFullscreenButton: true,
			HasMinimizeButton:   true,
			HasZoomButton:       true,
			IsModal:             false,
		},
	}

	result := convertWindows(windows)

	if len(result) != 1 {
		t.Fatalf("expected 1 window, got %d", len(result))
	}

	w := result[0]
	if w.ID != 42 {
		t.Errorf("ID = %d, want 42", w.ID)
	}
	if w.AppName != "TestApp" {
		t.Errorf("AppName = %q, want %q", w.AppName, "TestApp")
	}
	if w.BundleID != "com.test.app" {
		t.Errorf("BundleID = %q, want %q", w.BundleID, "com.test.app")
	}
	if w.Title != "Test Title" {
		t.Errorf("Title = %q, want %q", w.Title, "Test Title")
	}
	if w.Frame.X != 10 || w.Frame.Y != 20 || w.Frame.Width != 800 || w.Frame.Height != 600 {
		t.Errorf("Frame = %+v, want {X:10 Y:20 Width:800 Height:600}", w.Frame)
	}
	if w.Level != 0 {
		t.Errorf("Level = %d, want 0", w.Level)
	}
	if w.ZOrder != 7 {
		t.Errorf("ZOrder = %d, want 7", w.ZOrder)
	}
	if w.Role != "AXWindow" {
		t.Errorf("Role = %q, want %q", w.Role, "AXWindow")
	}
	if w.Subrole != "AXStandardWindow" {
		t.Errorf("Subrole = %q, want %q", w.Subrole, "AXStandardWindow")
	}
	if !w.HasCloseButton {
		t.Error("HasCloseButton should be true")
	}
	if !w.HasFullscreenButton {
		t.Error("HasFullscreenButton should be true")
	}
	if !w.HasMinimizeButton {
		t.Error("HasMinimizeButton should be true")
	}
	if !w.HasZoomButton {
		t.Error("HasZoomButton should be true")
	}
}
