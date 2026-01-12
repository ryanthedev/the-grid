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
