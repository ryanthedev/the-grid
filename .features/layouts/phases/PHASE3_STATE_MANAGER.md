# Phase 3: State Persistence Module

## Overview

Implement the state persistence system that tracks layout runtime state across CLI invocations. This module manages which layout is active per space, window-to-cell assignments, split ratios, and focus tracking.

**Location**: `grid-cli/internal/state/`

**State File**: `~/.local/state/thegrid/state.json`

**Dependencies**: Phase 0 (Shared Types)

**Parallelizes With**: Phase 1, Phase 2

---

## Scope

1. Persist layout state to JSON file
2. Track current layout per space
3. Track window-to-cell assignments
4. Track split ratios per cell
5. Track focused cell and window
6. Auto-create state directory if needed
7. Handle file locking for concurrent access

---

## Files to Create

```
grid-cli/internal/state/
├── state.go        # State structures and core operations
├── persistence.go  # File read/write operations
└── queries.go      # State query helpers
```

---

## Type Definitions

### state.go

```go
package state

import (
    "sync"
    "time"

    "github.com/yourusername/grid-cli/internal/types"
)

const (
    StateVersion = 1
)

// RuntimeState is the root state structure persisted to disk
type RuntimeState struct {
    Version     int                    `json:"version"`
    Spaces      map[string]*SpaceState `json:"spaces"`
    LastUpdated time.Time              `json:"lastUpdated"`

    mu sync.RWMutex `json:"-"` // For thread-safe access
}

// SpaceState tracks layout state for a single macOS Space
type SpaceState struct {
    SpaceID         string                `json:"spaceId"`
    CurrentLayoutID string                `json:"currentLayoutId"`
    LayoutIndex     int                   `json:"layoutIndex"`     // Index in the space's layout cycle
    Cells           map[string]*CellState `json:"cells"`           // cellID -> state
    FocusedCell     string                `json:"focusedCell"`     // Currently focused cell ID
    FocusedWindow   int                   `json:"focusedWindow"`   // Index of focused window in cell
}

// CellState tracks state for a single cell
type CellState struct {
    CellID      string          `json:"cellId"`
    Windows     []uint32        `json:"windows"`     // Ordered list of window IDs
    SplitRatios []float64       `json:"splitRatios"` // One per window, sum to 1.0
    StackMode   types.StackMode `json:"stackMode"`   // Override stack mode (empty = use default)
}

// NewRuntimeState creates a new empty runtime state
func NewRuntimeState() *RuntimeState {
    return &RuntimeState{
        Version:     StateVersion,
        Spaces:      make(map[string]*SpaceState),
        LastUpdated: time.Now(),
    }
}

// NewSpaceState creates a new empty space state
func NewSpaceState(spaceID string) *SpaceState {
    return &SpaceState{
        SpaceID:     spaceID,
        Cells:       make(map[string]*CellState),
        LayoutIndex: 0,
    }
}

// NewCellState creates a new empty cell state
func NewCellState(cellID string) *CellState {
    return &CellState{
        CellID:      cellID,
        Windows:     make([]uint32, 0),
        SplitRatios: make([]float64, 0),
    }
}

// GetSpace returns the state for a space, creating it if needed
func (rs *RuntimeState) GetSpace(spaceID string) *SpaceState {
    rs.mu.Lock()
    defer rs.mu.Unlock()

    if ss, ok := rs.Spaces[spaceID]; ok {
        return ss
    }

    ss := NewSpaceState(spaceID)
    rs.Spaces[spaceID] = ss
    return ss
}

// GetSpaceReadOnly returns the state for a space without creating it
func (rs *RuntimeState) GetSpaceReadOnly(spaceID string) *SpaceState {
    rs.mu.RLock()
    defer rs.mu.RUnlock()

    return rs.Spaces[spaceID]
}

// RemoveSpace removes a space from state
func (rs *RuntimeState) RemoveSpace(spaceID string) {
    rs.mu.Lock()
    defer rs.mu.Unlock()

    delete(rs.Spaces, spaceID)
}

// MarkUpdated updates the LastUpdated timestamp
func (rs *RuntimeState) MarkUpdated() {
    rs.mu.Lock()
    defer rs.mu.Unlock()

    rs.LastUpdated = time.Now()
}
```

---

## Space State Operations

### state.go (continued)

```go
// GetCell returns the state for a cell, creating it if needed
func (ss *SpaceState) GetCell(cellID string) *CellState {
    if cs, ok := ss.Cells[cellID]; ok {
        return cs
    }

    cs := NewCellState(cellID)
    ss.Cells[cellID] = cs
    return cs
}

// SetCurrentLayout sets the current layout and resets cell state
func (ss *SpaceState) SetCurrentLayout(layoutID string, layoutIndex int) {
    ss.CurrentLayoutID = layoutID
    ss.LayoutIndex = layoutIndex
    // Clear cell state when layout changes
    ss.Cells = make(map[string]*CellState)
    ss.FocusedCell = ""
    ss.FocusedWindow = 0
}

// CycleLayout moves to the next layout in the cycle
// Returns the new layout ID
func (ss *SpaceState) CycleLayout(availableLayouts []string) string {
    if len(availableLayouts) == 0 {
        return ss.CurrentLayoutID
    }

    ss.LayoutIndex = (ss.LayoutIndex + 1) % len(availableLayouts)
    newLayout := availableLayouts[ss.LayoutIndex]
    ss.SetCurrentLayout(newLayout, ss.LayoutIndex)
    return newLayout
}

// PreviousLayout moves to the previous layout in the cycle
func (ss *SpaceState) PreviousLayout(availableLayouts []string) string {
    if len(availableLayouts) == 0 {
        return ss.CurrentLayoutID
    }

    ss.LayoutIndex = (ss.LayoutIndex - 1 + len(availableLayouts)) % len(availableLayouts)
    newLayout := availableLayouts[ss.LayoutIndex]
    ss.SetCurrentLayout(newLayout, ss.LayoutIndex)
    return newLayout
}

// AssignWindow adds a window to a cell
func (ss *SpaceState) AssignWindow(windowID uint32, cellID string) {
    cell := ss.GetCell(cellID)

    // Check if already in this cell
    for _, wid := range cell.Windows {
        if wid == windowID {
            return
        }
    }

    // Remove from any other cell first
    ss.RemoveWindow(windowID)

    // Add to cell
    cell.Windows = append(cell.Windows, windowID)

    // Update split ratios to be equal
    cell.SplitRatios = equalRatios(len(cell.Windows))
}

// RemoveWindow removes a window from all cells
func (ss *SpaceState) RemoveWindow(windowID uint32) {
    for _, cell := range ss.Cells {
        for i, wid := range cell.Windows {
            if wid == windowID {
                // Remove window
                cell.Windows = append(cell.Windows[:i], cell.Windows[i+1:]...)
                // Update split ratios
                if len(cell.Windows) > 0 {
                    cell.SplitRatios = equalRatios(len(cell.Windows))
                } else {
                    cell.SplitRatios = nil
                }
                return
            }
        }
    }
}

// GetWindowCell returns the cell ID containing a window
func (ss *SpaceState) GetWindowCell(windowID uint32) string {
    for cellID, cell := range ss.Cells {
        for _, wid := range cell.Windows {
            if wid == windowID {
                return cellID
            }
        }
    }
    return ""
}

// SetFocus sets the focused cell and window index
func (ss *SpaceState) SetFocus(cellID string, windowIndex int) {
    ss.FocusedCell = cellID
    ss.FocusedWindow = windowIndex
}

// GetFocusedWindow returns the currently focused window ID
func (ss *SpaceState) GetFocusedWindow() uint32 {
    if ss.FocusedCell == "" {
        return 0
    }

    cell, ok := ss.Cells[ss.FocusedCell]
    if !ok || len(cell.Windows) == 0 {
        return 0
    }

    if ss.FocusedWindow < 0 || ss.FocusedWindow >= len(cell.Windows) {
        return cell.Windows[0]
    }

    return cell.Windows[ss.FocusedWindow]
}

// equalRatios returns equal split ratios for n windows
func equalRatios(n int) []float64 {
    if n <= 0 {
        return nil
    }
    ratio := 1.0 / float64(n)
    ratios := make([]float64, n)
    for i := range ratios {
        ratios[i] = ratio
    }
    return ratios
}
```

---

## Persistence Implementation

### persistence.go

```go
package state

import (
    "encoding/json"
    "fmt"
    "os"
    "path/filepath"
)

const (
    DefaultStateDir  = ".local/state/thegrid"
    DefaultStateFile = "state.json"
)

// GetStatePath returns the full path to the state file
func GetStatePath() string {
    home, _ := os.UserHomeDir()
    return filepath.Join(home, DefaultStateDir, DefaultStateFile)
}

// LoadState loads state from disk, creating new state if file doesn't exist
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

    // Initialize mutex (not persisted)
    if state.Spaces == nil {
        state.Spaces = make(map[string]*SpaceState)
    }

    return &state, nil
}

// Save persists state to disk
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

    // Write atomically using temp file
    tmpPath := path + ".tmp"
    if err := os.WriteFile(tmpPath, data, 0644); err != nil {
        return fmt.Errorf("failed to write state file: %w", err)
    }

    if err := os.Rename(tmpPath, path); err != nil {
        os.Remove(tmpPath) // Clean up temp file
        return fmt.Errorf("failed to rename state file: %w", err)
    }

    return nil
}

// Reset clears all state and saves
func (rs *RuntimeState) Reset() error {
    rs.mu.Lock()
    rs.Spaces = make(map[string]*SpaceState)
    rs.LastUpdated = time.Now()
    rs.mu.Unlock()

    return rs.Save()
}

// migrateState handles migration from older state versions
func migrateState(old *RuntimeState) *RuntimeState {
    // Currently no migrations needed
    // Future migrations would go here
    new := NewRuntimeState()
    new.Spaces = old.Spaces
    return new
}
```

---

## Query Helpers

### queries.go

```go
package state

import "github.com/yourusername/grid-cli/internal/types"

// GetAllWindowIDs returns all window IDs across all spaces
func (rs *RuntimeState) GetAllWindowIDs() []uint32 {
    rs.mu.RLock()
    defer rs.mu.RUnlock()

    var ids []uint32
    seen := make(map[uint32]bool)

    for _, space := range rs.Spaces {
        for _, cell := range space.Cells {
            for _, wid := range cell.Windows {
                if !seen[wid] {
                    seen[wid] = true
                    ids = append(ids, wid)
                }
            }
        }
    }

    return ids
}

// GetCellWindows returns window IDs for a specific cell in a space
func (rs *RuntimeState) GetCellWindows(spaceID, cellID string) []uint32 {
    rs.mu.RLock()
    defer rs.mu.RUnlock()

    space, ok := rs.Spaces[spaceID]
    if !ok {
        return nil
    }

    cell, ok := space.Cells[cellID]
    if !ok {
        return nil
    }

    return cell.Windows
}

// GetCellSplitRatios returns split ratios for a cell
func (rs *RuntimeState) GetCellSplitRatios(spaceID, cellID string) []float64 {
    rs.mu.RLock()
    defer rs.mu.RUnlock()

    space, ok := rs.Spaces[spaceID]
    if !ok {
        return nil
    }

    cell, ok := space.Cells[cellID]
    if !ok {
        return nil
    }

    return cell.SplitRatios
}

// GetCellStackMode returns the stack mode override for a cell
func (rs *RuntimeState) GetCellStackMode(spaceID, cellID string) types.StackMode {
    rs.mu.RLock()
    defer rs.mu.RUnlock()

    space, ok := rs.Spaces[spaceID]
    if !ok {
        return ""
    }

    cell, ok := space.Cells[cellID]
    if !ok {
        return ""
    }

    return cell.StackMode
}

// SetCellStackMode sets the stack mode override for a cell
func (rs *RuntimeState) SetCellStackMode(spaceID, cellID string, mode types.StackMode) {
    rs.mu.Lock()
    defer rs.mu.Unlock()

    space := rs.GetSpace(spaceID)
    cell := space.GetCell(cellID)
    cell.StackMode = mode
}

// GetCurrentLayoutForSpace returns the current layout ID for a space
func (rs *RuntimeState) GetCurrentLayoutForSpace(spaceID string) string {
    rs.mu.RLock()
    defer rs.mu.RUnlock()

    space, ok := rs.Spaces[spaceID]
    if !ok {
        return ""
    }

    return space.CurrentLayoutID
}

// GetWindowAssignments returns a map of cellID -> windowIDs for a space
func (rs *RuntimeState) GetWindowAssignments(spaceID string) map[string][]uint32 {
    rs.mu.RLock()
    defer rs.mu.RUnlock()

    space, ok := rs.Spaces[spaceID]
    if !ok {
        return nil
    }

    assignments := make(map[string][]uint32)
    for cellID, cell := range space.Cells {
        if len(cell.Windows) > 0 {
            assignments[cellID] = cell.Windows
        }
    }

    return assignments
}

// SetWindowAssignments bulk-sets window assignments for a space
func (rs *RuntimeState) SetWindowAssignments(spaceID string, assignments map[string][]uint32) {
    rs.mu.Lock()
    defer rs.mu.Unlock()

    space := rs.GetSpace(spaceID)

    // Clear existing cells
    space.Cells = make(map[string]*CellState)

    // Set new assignments
    for cellID, windowIDs := range assignments {
        cell := space.GetCell(cellID)
        cell.Windows = windowIDs
        cell.SplitRatios = equalRatios(len(windowIDs))
    }
}

// HasState returns true if there is any state for the given space
func (rs *RuntimeState) HasState(spaceID string) bool {
    rs.mu.RLock()
    defer rs.mu.RUnlock()

    space, ok := rs.Spaces[spaceID]
    if !ok {
        return false
    }

    return space.CurrentLayoutID != "" || len(space.Cells) > 0
}

// Summary returns a summary of the current state for display
func (rs *RuntimeState) Summary() map[string]interface{} {
    rs.mu.RLock()
    defer rs.mu.RUnlock()

    summary := map[string]interface{}{
        "version":     rs.Version,
        "lastUpdated": rs.LastUpdated,
        "spaceCount":  len(rs.Spaces),
        "spaces":      make(map[string]interface{}),
    }

    for spaceID, space := range rs.Spaces {
        windowCount := 0
        for _, cell := range space.Cells {
            windowCount += len(cell.Windows)
        }

        summary["spaces"].(map[string]interface{})[spaceID] = map[string]interface{}{
            "currentLayout": space.CurrentLayoutID,
            "cellCount":     len(space.Cells),
            "windowCount":   windowCount,
            "focusedCell":   space.FocusedCell,
        }
    }

    return summary
}
```

---

## Example State File

```json
{
  "version": 1,
  "spaces": {
    "1": {
      "spaceId": "1",
      "currentLayoutId": "two-column",
      "layoutIndex": 0,
      "cells": {
        "left": {
          "cellId": "left",
          "windows": [12345, 12346],
          "splitRatios": [0.5, 0.5],
          "stackMode": ""
        },
        "right": {
          "cellId": "right",
          "windows": [12347],
          "splitRatios": [1.0],
          "stackMode": "tabs"
        }
      },
      "focusedCell": "left",
      "focusedWindow": 0
    }
  },
  "lastUpdated": "2024-01-15T10:30:00Z"
}
```

---

## Acceptance Criteria

1. State loads correctly from existing file
2. State creates new file with proper directory structure if none exists
3. State saves atomically (no corruption on crash)
4. Thread-safe operations with proper locking
5. Window assignments are tracked correctly
6. Split ratios maintained correctly when windows added/removed
7. Layout cycling works correctly

---

## Test Scenarios

```go
func TestLoadState_NoFile(t *testing.T) {
    // Should return new empty state
    state, err := LoadStateFrom("/nonexistent/path")
    if err != nil {
        t.Fatal(err)
    }
    if len(state.Spaces) != 0 {
        t.Error("expected empty state")
    }
}

func TestSaveAndLoad(t *testing.T) {
    tmpFile := "/tmp/test-state.json"
    defer os.Remove(tmpFile)

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
}

func TestWindowAssignment(t *testing.T) {
    state := NewRuntimeState()
    space := state.GetSpace("1")

    space.AssignWindow(123, "left")
    space.AssignWindow(456, "left")

    if len(space.Cells["left"].Windows) != 2 {
        t.Error("expected 2 windows in cell")
    }

    // Move window to different cell
    space.AssignWindow(123, "right")

    if len(space.Cells["left"].Windows) != 1 {
        t.Error("expected 1 window in left cell after move")
    }
    if len(space.Cells["right"].Windows) != 1 {
        t.Error("expected 1 window in right cell after move")
    }
}

func TestLayoutCycling(t *testing.T) {
    state := NewRuntimeState()
    space := state.GetSpace("1")
    space.SetCurrentLayout("layout1", 0)

    layouts := []string{"layout1", "layout2", "layout3"}

    next := space.CycleLayout(layouts)
    if next != "layout2" {
        t.Errorf("expected layout2, got %s", next)
    }

    next = space.CycleLayout(layouts)
    if next != "layout3" {
        t.Errorf("expected layout3, got %s", next)
    }

    next = space.CycleLayout(layouts)
    if next != "layout1" {
        t.Errorf("expected layout1 (wrap), got %s", next)
    }
}

func TestSplitRatios(t *testing.T) {
    state := NewRuntimeState()
    space := state.GetSpace("1")

    space.AssignWindow(1, "cell")
    ratios := space.Cells["cell"].SplitRatios
    if len(ratios) != 1 || ratios[0] != 1.0 {
        t.Error("expected [1.0]")
    }

    space.AssignWindow(2, "cell")
    ratios = space.Cells["cell"].SplitRatios
    if len(ratios) != 2 || ratios[0] != 0.5 || ratios[1] != 0.5 {
        t.Error("expected [0.5, 0.5]")
    }

    space.RemoveWindow(1)
    ratios = space.Cells["cell"].SplitRatios
    if len(ratios) != 1 || ratios[0] != 1.0 {
        t.Error("expected [1.0] after removal")
    }
}
```

---

## Notes for Implementing Agent

1. State file location follows XDG conventions (`~/.local/state/`)
2. Use atomic writes (temp file + rename) to prevent corruption
3. The `sync.RWMutex` is not serialized - initialize after loading
4. Split ratios auto-equalize when windows are added/removed
5. Consider adding file locking for multi-process safety (optional for v1)
6. State should be backward compatible - handle missing fields gracefully
7. Run `go test ./internal/state/...` to verify implementation
