package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"
)

const (
	PickerHistoryVersion = 1
	MaxHistoryEntries    = 100
	PickerHistoryFile    = "picker-history.json"
)

// PickerHistory tracks window selection history for the picker
type PickerHistory struct {
	Version    int              `json:"version"`
	Previous   string           `json:"previous"`
	Frequency  map[string]int   `json:"frequency"`
	LastPicked map[string]int64 `json:"lastPicked"`
}

// NewPickerHistory creates a new empty picker history
func NewPickerHistory() *PickerHistory {
	return &PickerHistory{
		Version:    PickerHistoryVersion,
		Frequency:  make(map[string]int),
		LastPicked: make(map[string]int64),
	}
}

// GetPickerHistoryPath returns the full path to the picker history file
func GetPickerHistoryPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, DefaultStateDir, PickerHistoryFile)
}

// LoadPickerHistory loads from state dir. Returns empty history if file missing.
func LoadPickerHistory() (*PickerHistory, error) {
	return LoadPickerHistoryFrom(GetPickerHistoryPath())
}

// LoadPickerHistoryFrom loads picker history from a specific path
func LoadPickerHistoryFrom(path string) (*PickerHistory, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return NewPickerHistory(), nil
		}
		return nil, fmt.Errorf("failed to read picker history: %w", err)
	}

	var history PickerHistory
	if err := json.Unmarshal(data, &history); err != nil {
		return nil, fmt.Errorf("failed to parse picker history: %w", err)
	}

	// Initialize maps if nil
	if history.Frequency == nil {
		history.Frequency = make(map[string]int)
	}
	if history.LastPicked == nil {
		history.LastPicked = make(map[string]int64)
	}

	if err := history.Validate(); err != nil {
		return nil, fmt.Errorf("invalid picker history: %w", err)
	}

	return &history, nil
}

// Save writes atomically (write to .tmp, rename). Calls Prune() first.
func (h *PickerHistory) Save() error {
	return h.SaveTo(GetPickerHistoryPath())
}

// SaveTo writes picker history atomically to a specific path
func (h *PickerHistory) SaveTo(path string) error {
	h.Prune()

	// Ensure directory exists
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("failed to create state directory: %w", err)
	}

	data, err := json.MarshalIndent(h, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal picker history: %w", err)
	}

	// Write atomically using temp file + rename
	tmpPath := path + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0644); err != nil {
		return fmt.Errorf("failed to write picker history: %w", err)
	}

	if err := os.Rename(tmpPath, path); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("failed to rename picker history: %w", err)
	}

	return nil
}

// Validate checks semantic correctness (no negative frequencies, etc.)
func (h *PickerHistory) Validate() error {
	for id, freq := range h.Frequency {
		if freq < 0 {
			return fmt.Errorf("negative frequency for %q: %d", id, freq)
		}
	}
	for id, ts := range h.LastPicked {
		if ts < 0 {
			return fmt.Errorf("negative timestamp for %q: %d", id, ts)
		}
	}
	return nil
}

// RecordSelection updates Previous, increments Frequency, sets LastPicked timestamp.
func (h *PickerHistory) RecordSelection(stableID string) {
	if stableID == "" {
		return
	}
	h.Previous = stableID
	h.Frequency[stableID]++
	h.LastPicked[stableID] = time.Now().Unix()
}

// Prune removes oldest entries if over MaxHistoryEntries, using LastPicked for LRU.
func (h *PickerHistory) Prune() {
	if len(h.Frequency) <= MaxHistoryEntries {
		return
	}

	// Build list of entries sorted by LastPicked (oldest first)
	type entry struct {
		id         string
		lastPicked int64
	}
	entries := make([]entry, 0, len(h.Frequency))
	for id := range h.Frequency {
		entries = append(entries, entry{id: id, lastPicked: h.LastPicked[id]})
	}
	sort.Slice(entries, func(i, j int) bool {
		return entries[i].lastPicked < entries[j].lastPicked
	})

	// Remove oldest entries until at MaxHistoryEntries
	toRemove := len(entries) - MaxHistoryEntries
	for i := 0; i < toRemove; i++ {
		id := entries[i].id
		delete(h.Frequency, id)
		delete(h.LastPicked, id)
	}
}

// GetFrequency returns the frequency for a stable ID, or 0 if not found
func (h *PickerHistory) GetFrequency(stableID string) int {
	return h.Frequency[stableID]
}

// IsPrevious returns true if the given stable ID matches the previous selection
func (h *PickerHistory) IsPrevious(stableID string) bool {
	return h.Previous != "" && h.Previous == stableID
}
