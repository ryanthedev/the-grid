package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

const (
	// DefaultStateDir is the directory under $HOME for state files
	DefaultStateDir = ".local/state/thegrid"
	// DefaultStateFile is the state file name
	DefaultStateFile = "state.json"
)

// GetStatePath returns the full path to the state file
func GetStatePath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, DefaultStateDir, DefaultStateFile)
}

// LoadState loads state from the default path, creating new state if file doesn't exist
func LoadState() (*RuntimeState, error) {
	return LoadStateFrom(GetStatePath())
}

// LoadStateFrom loads state from a specific path
func LoadStateFrom(path string) (*RuntimeState, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			// Return new empty state if file doesn't exist
			return NewRuntimeState(), nil
		}
		return nil, fmt.Errorf("failed to read state file: %w", err)
	}

	var state RuntimeState
	if err := json.Unmarshal(data, &state); err != nil {
		return nil, fmt.Errorf("failed to parse state file: %w", err)
	}

	// Handle version migration if needed
	if state.Version < StateVersion {
		state = *migrateState(&state)
	}

	// Initialize maps if nil (not persisted or old format)
	if state.Spaces == nil {
		state.Spaces = make(map[string]*SpaceState)
	}

	// Ensure nested maps are initialized
	for _, space := range state.Spaces {
		if space.Cells == nil {
			space.Cells = make(map[string]*CellState)
		}
	}

	return &state, nil
}

// Save persists state to the default path
func (rs *RuntimeState) Save() error {
	return rs.SaveTo(GetStatePath())
}

// SaveTo persists state to a specific path
func (rs *RuntimeState) SaveTo(path string) error {
	rs.mu.RLock()
	defer rs.mu.RUnlock()

	// Update timestamp
	rs.LastUpdated = time.Now()

	// Ensure directory exists
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("failed to create state directory: %w", err)
	}

	// Marshal with indentation for readability
	data, err := json.MarshalIndent(rs, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal state: %w", err)
	}

	// Write atomically using temp file + rename
	tmpPath := path + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0644); err != nil {
		return fmt.Errorf("failed to write state file: %w", err)
	}

	if err := os.Rename(tmpPath, path); err != nil {
		os.Remove(tmpPath) // Clean up temp file on failure
		return fmt.Errorf("failed to rename state file: %w", err)
	}

	return nil
}

// Reset clears all state and saves to disk
func (rs *RuntimeState) Reset() error {
	rs.mu.Lock()
	rs.Spaces = make(map[string]*SpaceState)
	rs.LastUpdated = time.Now()
	rs.mu.Unlock()

	return rs.Save()
}

// migrateState handles migration from older state versions
func migrateState(old *RuntimeState) *RuntimeState {
	// Currently no migrations needed - just update version
	// Future migrations would go here (e.g., v1 -> v2 field changes)
	new := NewRuntimeState()
	new.Spaces = old.Spaces
	new.LastUpdated = old.LastUpdated
	return new
}
