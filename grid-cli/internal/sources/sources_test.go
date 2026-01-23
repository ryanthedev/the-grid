package sources

import (
	"strings"
	"testing"

	gridConfig "github.com/ryanthedev/grid-cli/internal/config"
)

func TestDiscoverApps(t *testing.T) {
	items := DiscoverApps()
	if len(items) == 0 {
		t.Fatal("expected to find at least one app")
	}

	// Verify structure of first item
	first := items[0]
	if first.ID == "" {
		t.Error("ID should not be empty")
	}
	if first.Title == "" {
		t.Error("Title should not be empty")
	}
	if first.Action.Type != "open-app" {
		t.Errorf("expected action type 'open-app', got %q", first.Action.Type)
	}
	if first.Action.AppPath == "" {
		t.Error("AppPath should not be empty")
	}

	t.Logf("found %d apps", len(items))
}

func TestDiscoverChromeProfiles(t *testing.T) {
	items := DiscoverChromeProfiles()
	// Chrome may or may not be installed, so just verify no panic
	t.Logf("found %d chrome profiles", len(items))

	for _, item := range items {
		if item.Action.Type != "open-chrome-profile" {
			t.Errorf("expected action type 'open-chrome-profile', got %q", item.Action.Type)
		}
		if item.Action.ProfileDir == "" {
			t.Error("ProfileDir should not be empty")
		}
	}
}

func TestDiscoverActions(t *testing.T) {
	configs := []gridConfig.ActionConfig{
		{Name: "Open Terminal", Command: "open -a Terminal", Category: "Utils", Icon: "terminal"},
		{Name: "Lock Screen", Command: "pmset displaysleepnow", Category: "System"},
	}

	items := DiscoverActions(configs)
	if len(items) != 2 {
		t.Fatalf("expected 2 items, got %d", len(items))
	}

	if items[0].ID != "action:open-terminal" {
		t.Errorf("unexpected ID: %s", items[0].ID)
	}
	if items[0].Action.Command != "open -a Terminal" {
		t.Errorf("unexpected command: %s", items[0].Action.Command)
	}
	if items[0].Icon != "terminal" {
		t.Errorf("unexpected icon: %s", items[0].Icon)
	}

	// Second item should have default icon
	if items[1].Icon != "terminal" {
		t.Errorf("expected default icon 'terminal', got %s", items[1].Icon)
	}
}

func TestDiscoverZoxide(t *testing.T) {
	items := DiscoverZoxide()
	// Zoxide may or may not have entries, just verify no panic and correct structure
	t.Logf("found %d zoxide paths", len(items))

	for _, item := range items {
		if item.Action.Type != "open-dir" {
			t.Errorf("expected action type 'open-dir', got %q", item.Action.Type)
		}
		if item.Action.DirPath == "" {
			t.Error("DirPath should not be empty")
		}
		if item.ID == "" || !strings.HasPrefix(item.ID, "zoxide:") {
			t.Errorf("ID should start with 'zoxide:', got %q", item.ID)
		}
	}
}

func TestDiscoverAll(t *testing.T) {
	enabled := EnabledSources{
		Apps:    true,
		Chrome:  true,
		Actions: true,
		Zoxide:  true,
	}
	cfg := Config{
		Actions: []gridConfig.ActionConfig{
			{Name: "Test Action", Command: "echo test"},
		},
	}

	items := DiscoverAll(enabled, cfg)
	if len(items) == 0 {
		t.Fatal("expected to find at least one item")
	}

	// Should have at least one app and one action
	// (zoxide/chrome may not be available in CI)
	hasApp := false
	hasAction := false
	for _, item := range items {
		switch item.Action.Type {
		case "open-app":
			hasApp = true
		case "exec":
			hasAction = true
		}
	}

	if !hasApp {
		t.Error("expected at least one app")
	}
	if !hasAction {
		t.Error("expected at least one action")
	}

	t.Logf("found %d total items", len(items))
}
