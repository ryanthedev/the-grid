package state

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadPickerHistoryMissingFile(t *testing.T) {
	// Test 6: Missing file should return empty history, no error
	tmpDir := t.TempDir()
	path := filepath.Join(tmpDir, "nonexistent.json")

	history, err := LoadPickerHistoryFrom(path)
	if err != nil {
		t.Fatalf("expected no error for missing file, got: %v", err)
	}
	if history == nil {
		t.Fatal("expected non-nil history")
	}
	if history.Previous != "" {
		t.Errorf("expected empty Previous, got: %q", history.Previous)
	}
	if len(history.Frequency) != 0 {
		t.Errorf("expected empty Frequency, got: %v", history.Frequency)
	}
}

func TestLoadPickerHistoryMalformedJSON(t *testing.T) {
	// Test 5: Malformed JSON should return error, not panic
	tmpDir := t.TempDir()
	path := filepath.Join(tmpDir, "malformed.json")

	if err := os.WriteFile(path, []byte("{invalid"), 0644); err != nil {
		t.Fatalf("failed to write test file: %v", err)
	}

	_, err := LoadPickerHistoryFrom(path)
	if err == nil {
		t.Fatal("expected error for malformed JSON")
	}
}

func TestPickerHistoryLRUEviction(t *testing.T) {
	// Test 8: LRU eviction at 100 entries
	history := NewPickerHistory()

	// Add 101 entries with incrementing timestamps
	for i := 0; i < 101; i++ {
		id := "entry-" + string(rune('a'+i%26)) + string(rune('0'+i/26))
		history.Frequency[id] = 1
		history.LastPicked[id] = int64(i)
	}

	if len(history.Frequency) != 101 {
		t.Fatalf("expected 101 entries before prune, got: %d", len(history.Frequency))
	}

	history.Prune()

	if len(history.Frequency) != MaxHistoryEntries {
		t.Errorf("expected %d entries after prune, got: %d", MaxHistoryEntries, len(history.Frequency))
	}

	// The oldest entry (timestamp 0) should be removed
	if _, exists := history.Frequency["entry-a0"]; exists {
		t.Error("expected oldest entry to be pruned")
	}
}

func TestPickerHistoryRecordSelection(t *testing.T) {
	history := NewPickerHistory()

	history.RecordSelection("test-id")

	if history.Previous != "test-id" {
		t.Errorf("expected Previous to be 'test-id', got: %q", history.Previous)
	}
	if history.Frequency["test-id"] != 1 {
		t.Errorf("expected Frequency to be 1, got: %d", history.Frequency["test-id"])
	}
	if history.LastPicked["test-id"] == 0 {
		t.Error("expected LastPicked to be set")
	}

	// Record again
	history.RecordSelection("test-id")
	if history.Frequency["test-id"] != 2 {
		t.Errorf("expected Frequency to be 2, got: %d", history.Frequency["test-id"])
	}
}

func TestPickerHistorySaveAndLoad(t *testing.T) {
	tmpDir := t.TempDir()
	path := filepath.Join(tmpDir, "history.json")

	history := NewPickerHistory()
	history.RecordSelection("test-window")
	history.RecordSelection("another-window")
	history.RecordSelection("test-window")

	if err := history.SaveTo(path); err != nil {
		t.Fatalf("failed to save: %v", err)
	}

	loaded, err := LoadPickerHistoryFrom(path)
	if err != nil {
		t.Fatalf("failed to load: %v", err)
	}

	if loaded.Previous != history.Previous {
		t.Errorf("Previous mismatch: %q vs %q", loaded.Previous, history.Previous)
	}
	if loaded.Frequency["test-window"] != 2 {
		t.Errorf("expected frequency 2 for test-window, got: %d", loaded.Frequency["test-window"])
	}
	if loaded.Frequency["another-window"] != 1 {
		t.Errorf("expected frequency 1 for another-window, got: %d", loaded.Frequency["another-window"])
	}
}

func TestFrecencyScore(t *testing.T) {
	h := NewPickerHistory()

	// No history = score 0
	if score := h.FrecencyScore("unknown"); score != 0 {
		t.Errorf("expected 0 for unknown, got %f", score)
	}

	// Record some selections
	h.RecordSelection("item1")
	h.RecordSelection("item1")
	h.RecordSelection("item2")

	score1 := h.FrecencyScore("item1")
	score2 := h.FrecencyScore("item2")

	// item1 was selected twice, item2 once
	// Since both were just selected (same recency), item1 should have higher score
	if score1 <= score2 {
		t.Errorf("expected item1 score (%f) > item2 score (%f)", score1, score2)
	}
}

func TestSortByFrecency(t *testing.T) {
	h := NewPickerHistory()

	// Record history: item1 most used, item3 second, item2 least
	h.RecordSelection("item1")
	h.RecordSelection("item1")
	h.RecordSelection("item1")
	h.RecordSelection("item3")
	h.RecordSelection("item3")
	h.RecordSelection("item2")

	// Create items in arbitrary order
	items := []string{"item2", "item3", "item1"}

	SortByFrecency(items, func(s string) string { return s }, h)

	// Should be sorted by frecency: item1, item3, item2
	expected := []string{"item1", "item3", "item2"}
	for i, want := range expected {
		if items[i] != want {
			t.Errorf("position %d: expected %s, got %s", i, want, items[i])
		}
	}
}

func TestGetSourceBoost(t *testing.T) {
	boosts := DefaultSourceBoosts()

	tests := []struct {
		id       string
		expected float64
	}{
		// Explicit source prefixes
		{"app:com.apple.Safari", 1.0},
		{"chrome:Default", 1.0},
		{"action:lock-screen", 1.5},
		{"zoxide:~/repos/foo", 0.5},

		// Windows - tmux prefix
		{"tmux:session:window", 10.0},
		{"tmux:theGrid:zsh", 10.0},

		// Windows - bundle ID prefix (non-tmux)
		{"com.mitchellh.ghostty:title:abcd", 10.0},
		{"com.apple.Terminal:bash:1234", 10.0},

		// Chrome windows (bundle ID prefix) should get Windows boost
		{"com.google.Chrome:github-issues:a1b2", 10.0},
	}

	for _, tt := range tests {
		got := boosts.GetSourceBoost(tt.id)
		if got != tt.expected {
			t.Errorf("GetSourceBoost(%q) = %v, want %v", tt.id, got, tt.expected)
		}
	}
}

func TestSortByFrecency_ChromeWindowsOverProfiles(t *testing.T) {
	// Chrome windows should rank above Chrome profiles
	// Chrome windows: com.google.Chrome:... → Windows boost (10.0)
	// Chrome profiles: chrome:... → Chrome boost (1.0)
	h := NewPickerHistory()

	items := []string{
		"chrome:Default",
		"chrome:Work",
		"com.google.Chrome:github-issues:a1b2",
		"chrome:Personal",
	}

	SortByFrecency(items, func(s string) string { return s }, h)

	// Chrome window should be first
	if items[0] != "com.google.Chrome:github-issues:a1b2" {
		t.Errorf("expected Chrome window first, got %s", items[0])
	}
}

func TestSortByFrecencyWithBoosts_NilHistory(t *testing.T) {
	// Even without history, boosts should still apply
	items := []string{
		"zoxide:~/.config",
		"tmux:session:window",
		"app:com.apple.Safari",
	}

	SortByFrecency(items, func(s string) string { return s }, nil)

	// Should be: tmux (10x), app (1x), zoxide (0.5x)
	expected := []string{"tmux:session:window", "app:com.apple.Safari", "zoxide:~/.config"}
	for i, want := range expected {
		if items[i] != want {
			t.Errorf("position %d: expected %s, got %s", i, want, items[i])
		}
	}
}

func TestSortByFrecencyWithBoosts_WindowsOverZoxide(t *testing.T) {
	// Main use case: windows should rank above zoxide directories
	// even when both have no history
	h := NewPickerHistory()

	items := []string{
		"zoxide:~/.config",
		"zoxide:~/repos/dotfiles/.config",
		"tmux:_config:nvim",
		"zoxide:~/.config/bin",
	}

	SortByFrecency(items, func(s string) string { return s }, h)

	// Window (10x base) should be first, then zoxide dirs (0.5x base)
	if items[0] != "tmux:_config:nvim" {
		t.Errorf("expected tmux window first, got %s", items[0])
	}
}

func TestSortByFrecencyWithBoosts_HighFrecencyOvercomesBoost(t *testing.T) {
	// A frequently used zoxide dir should eventually beat a never-used window
	h := NewPickerHistory()

	// Use the zoxide item many times (simulating heavy usage)
	for i := 0; i < 50; i++ {
		h.RecordSelection("zoxide:~/repos/project")
	}

	items := []string{
		"tmux:session:window", // 10x boost but no history (score: 1.0 * 10 = 10)
		"zoxide:~/repos/project", // 0.5x boost but freq=50 (score: ~50 * 0.5 = 25)
	}

	SortByFrecency(items, func(s string) string { return s }, h)

	// High frecency zoxide should beat low-frecency window
	if items[0] != "zoxide:~/repos/project" {
		t.Errorf("expected high-frecency zoxide first, got %s", items[0])
	}
}
