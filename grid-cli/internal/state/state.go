package state

import (
	"sync"
	"time"

	"github.com/yourusername/grid-cli/internal/types"
)

const (
	// StateVersion is the current state file format version
	StateVersion = 1
)

// RuntimeState is the root state structure persisted to disk
type RuntimeState struct {
	Version     int                    `json:"version"`
	Spaces      map[string]*SpaceState `json:"spaces"`
	LastUpdated time.Time              `json:"lastUpdated"`

	mu sync.RWMutex `json:"-"` // For thread-safe access (not serialized)
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
	CellID         string          `json:"cellId"`
	Windows        []uint32        `json:"windows"`        // Ordered list of window IDs
	SplitRatios    []float64       `json:"splitRatios"`    // One per window, sum to 1.0
	StackMode      types.StackMode `json:"stackMode"`      // Override stack mode (empty = use default)
	LastFocusedIdx int             `json:"lastFocusedIdx"` // Last focused window index in this cell
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

// CycleLayout moves to the next layout in the cycle.
// Returns the new layout ID.
func (ss *SpaceState) CycleLayout(availableLayouts []string) string {
	if len(availableLayouts) == 0 {
		return ss.CurrentLayoutID
	}

	ss.LayoutIndex = (ss.LayoutIndex + 1) % len(availableLayouts)
	newLayout := availableLayouts[ss.LayoutIndex]
	ss.SetCurrentLayout(newLayout, ss.LayoutIndex)
	return newLayout
}

// PreviousLayout moves to the previous layout in the cycle.
// Returns the new layout ID.
func (ss *SpaceState) PreviousLayout(availableLayouts []string) string {
	if len(availableLayouts) == 0 {
		return ss.CurrentLayoutID
	}

	ss.LayoutIndex = (ss.LayoutIndex - 1 + len(availableLayouts)) % len(availableLayouts)
	newLayout := availableLayouts[ss.LayoutIndex]
	ss.SetCurrentLayout(newLayout, ss.LayoutIndex)
	return newLayout
}

// AssignWindow adds a window to a cell (appends to end).
// Sets LastFocusedIdx to the new window so it becomes the "top" (focused) window.
// If the window is already in another cell, it's moved.
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

	// Append to cell
	cell.Windows = append(cell.Windows, windowID)
	// New window becomes "top" (focused) via LastFocusedIdx
	cell.LastFocusedIdx = len(cell.Windows) - 1

	// Update split ratios to be equal
	cell.SplitRatios = equalRatios(len(cell.Windows))
}

// PrependWindowToCell adds a window to a cell (prepends to start).
// If the window is already in another cell, it's moved.
func (ss *SpaceState) PrependWindowToCell(windowID uint32, cellID string) {
	cell := ss.GetCell(cellID)

	// Check if already in this cell at position 0
	if len(cell.Windows) > 0 && cell.Windows[0] == windowID {
		return
	}

	// Remove from any other cell first (including this cell if not at position 0)
	ss.RemoveWindow(windowID)

	// Prepend to cell
	cell.Windows = append([]uint32{windowID}, cell.Windows...)
	cell.LastFocusedIdx = 0 // Prepended window becomes top

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

				// Adjust LastFocusedIdx if needed
				if len(cell.Windows) == 0 {
					cell.LastFocusedIdx = 0
				} else if cell.LastFocusedIdx >= len(cell.Windows) {
					cell.LastFocusedIdx = len(cell.Windows) - 1
				}

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

// GetWindowCell returns the cell ID containing a window, or empty string if not found
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

// SetFocus sets the focused cell and window index.
// Also updates the cell's LastFocusedIdx for persistence across cell switches.
func (ss *SpaceState) SetFocus(cellID string, windowIndex int) {
	ss.FocusedCell = cellID
	ss.FocusedWindow = windowIndex

	// Also update the cell's LastFocusedIdx for persistence
	if cell, ok := ss.Cells[cellID]; ok {
		cell.LastFocusedIdx = windowIndex
	}
}

// GetFocusedWindow returns the currently focused window ID, or 0 if none
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
