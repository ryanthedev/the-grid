package layout

import (
	"sort"

	"github.com/yourusername/grid-cli/internal/config"
	"github.com/yourusername/grid-cli/internal/logging"
	"github.com/yourusername/grid-cli/internal/types"
)

// Window represents a window from the server.
// This matches the structure returned by the server's dump command.
type Window struct {
	ID          uint32
	Title       string
	AppName     string
	BundleID    string
	PID         int
	Frame       types.Rect
	SpaceIDs    []uint64 // Spaces this window is on
	IsMinimized bool
	IsHidden    bool
	Level       int // Window level (0 = normal, higher = floating/overlay)

	// AX properties for floating/popup detection
	Role              string // AXRole (e.g., "AXWindow")
	Subrole           string // AXSubrole (e.g., "AXStandardWindow", "AXDialog")
	HasCloseButton    bool
	HasFullscreenButton bool
	HasMinimizeButton bool
	HasZoomButton     bool
	IsModal           bool
}

// WindowCategory classifies windows for tiling decisions
type WindowCategory int

const (
	WindowPopup    WindowCategory = iota // Ignore completely (menus, tooltips)
	WindowFloating                       // Track but don't tile (dialogs, PIP)
	WindowStandard                       // Normal window for tiling
)

// terminalApps that should be allowed to tile even without fullscreen button
var terminalApps = map[string]bool{
	"Alacritty":        true,
	"iTerm2":           true,
	"Terminal":         true,
	"kitty":            true,
	"WezTerm":          true,
	"Hyper":            true,
	"Code":             true, // VS Code
	"Visual Studio Code": true,
	"Emacs":            true,
	"GIMP":             true,
	"Activity Monitor": true,
	"Steam":            true,
}

// ClassifyWindow determines if a window should be tiled, floated, or ignored.
// Based on yabai and AeroSpace heuristics.
func ClassifyWindow(w Window) WindowCategory {
	// 1. Minimized or hidden windows are excluded
	if w.IsMinimized || w.IsHidden {
		return WindowPopup
	}

	// 2. Windows with non-zero level are floating (overlay windows)
	if w.Level != 0 {
		return WindowFloating
	}

	// 3. If no AX data available, use heuristics
	if w.Role == "" {
		// No AX data - check if it has any window buttons
		if !w.HasCloseButton && !w.HasFullscreenButton && !w.HasMinimizeButton && !w.HasZoomButton {
			// No buttons and no role = probably not a real window (popup/helper)
			return WindowPopup
		}
		// Has some buttons but no role data - treat as standard for safety
		return WindowStandard
	}

	// 4. Must be AXWindow role to be considered
	if w.Role != "AXWindow" {
		return WindowPopup
	}

	// 5. Check subrole
	switch w.Subrole {
	case "AXUnknown", "":
		// Unknown subrole with no buttons = popup
		if !w.HasCloseButton && !w.HasFullscreenButton && !w.HasMinimizeButton && !w.HasZoomButton {
			return WindowPopup
		}
		// Has buttons but unknown subrole - check if it's a floating type
		return WindowStandard

	case "AXDialog", "AXFloatingWindow":
		// Dialogs and floating windows should float
		return WindowFloating

	case "AXStandardWindow":
		// Standard windows are tileable, but check for modal
		if w.IsModal {
			return WindowFloating
		}
		return WindowStandard

	default:
		// Other subroles (AXSheet, etc.) - treat as floating
		return WindowFloating
	}
}

// ClassifyWindowWithPIPDetection adds PIP detection heuristics
func ClassifyWindowWithPIPDetection(w Window) WindowCategory {
	base := ClassifyWindow(w)
	if base != WindowStandard {
		return base
	}

	// Additional PIP detection: no fullscreen button (except for terminal apps)
	if !w.HasFullscreenButton && !terminalApps[w.AppName] {
		return WindowFloating
	}

	return WindowStandard
}

// AssignmentResult contains the result of window assignment
type AssignmentResult struct {
	Assignments map[string][]uint32 // cellID -> window IDs
	Floating    []uint32            // Windows that should float (not tiled)
	Excluded    []uint32            // Windows excluded from layout (minimized, hidden, etc.)
}

// AssignWindows distributes windows to cells based on the given strategy.
//
// Parameters:
//   - windows: Windows from server (filtered to current space)
//   - layout: The layout being applied
//   - cellBounds: Pre-calculated cell bounds
//   - appRules: Application-specific rules
//   - previousAssignments: Previous window-to-cell mappings (for preserve strategy)
//   - strategy: How to assign windows
//
// Returns: AssignmentResult with cell assignments and floating windows
func AssignWindows(
	windows []Window,
	layout *types.Layout,
	cellBounds map[string]types.Rect,
	appRules []config.AppRule,
	previousAssignments map[string][]uint32,
	strategy types.AssignmentStrategy,
) *AssignmentResult {
	result := &AssignmentResult{
		Assignments: make(map[string][]uint32),
		Floating:    make([]uint32, 0),
		Excluded:    make([]uint32, 0),
	}

	// Initialize empty assignments for all cells
	for _, cell := range layout.Cells {
		result.Assignments[cell.ID] = make([]uint32, 0)
	}

	// Filter windows and identify floating/excluded
	var tileable []Window
	for _, w := range windows {
		// Check if window should be excluded first (minimized, hidden, overlay)
		if shouldExclude(w) {
			result.Excluded = append(result.Excluded, w.ID)
			continue
		}

		// Check if window should float
		if shouldFloat(w, appRules) {
			result.Floating = append(result.Floating, w.ID)
			continue
		}

		tileable = append(tileable, w)
	}

	// Apply assignment strategy
	switch strategy {
	case types.AssignPinned:
		assignPinned(tileable, layout, appRules, result)
	case types.AssignPreserve:
		assignPreserve(tileable, layout, previousAssignments, result)
	case types.AssignAutoFlow:
		assignAutoFlow(tileable, layout, cellBounds, result)
	default:
		assignByPosition(tileable, cellBounds, result)
	}

	return result
}

// shouldFloat checks if a window should be floating.
// Uses AX properties (role/subrole/buttons) combined with app rules.
func shouldFloat(w Window, rules []config.AppRule) bool {
	// Check app rules first
	for _, rule := range rules {
		if matchesAppRule(w, rule) && rule.Float {
			return true
		}
	}

	// Use window classification with PIP detection
	category := ClassifyWindowWithPIPDetection(w)
	return category == WindowFloating
}

// shouldExclude checks if a window should be excluded from layout entirely.
// Excludes minimized, hidden, and overlay windows (non-zero level).
func shouldExclude(w Window) bool {
	return w.IsMinimized || w.IsHidden || w.Level != 0
}

// matchesAppRule checks if a window matches an app rule.
func matchesAppRule(w Window, rule config.AppRule) bool {
	return rule.App == w.AppName || rule.App == w.BundleID
}

// assignAutoFlow distributes windows evenly across cells using round-robin.
func assignAutoFlow(windows []Window, layout *types.Layout, cellBounds map[string]types.Rect, result *AssignmentResult) {
	if len(windows) == 0 || len(layout.Cells) == 0 {
		return
	}

	// Sort cells by visual position (left-to-right, top-to-bottom)
	sortedCells := SortCellsByPosition(cellBounds)

	// If no bounds available, use cell order from layout
	if len(sortedCells) == 0 {
		for _, cell := range layout.Cells {
			sortedCells = append(sortedCells, cell.ID)
		}
	}

	// Round-robin assignment
	for i, w := range windows {
		cellID := sortedCells[i%len(sortedCells)]
		result.Assignments[cellID] = append(result.Assignments[cellID], w.ID)
	}
}

// assignPinned assigns windows to preferred cells based on app rules.
func assignPinned(windows []Window, layout *types.Layout, rules []config.AppRule, result *AssignmentResult) {
	var unpinned []Window

	// First pass: assign pinned windows
	for _, w := range windows {
		assigned := false
		for _, rule := range rules {
			if matchesAppRule(w, rule) && rule.PreferredCell != "" {
				// Check if cell exists in layout
				if _, ok := result.Assignments[rule.PreferredCell]; ok {
					result.Assignments[rule.PreferredCell] = append(result.Assignments[rule.PreferredCell], w.ID)
					assigned = true
					break
				}
			}
		}
		if !assigned {
			unpinned = append(unpinned, w)
		}
	}

	// Second pass: distribute unpinned windows
	if len(unpinned) > 0 {
		// Find cells with no windows yet
		emptyCells := make([]string, 0)
		for cellID, windows := range result.Assignments {
			if len(windows) == 0 {
				emptyCells = append(emptyCells, cellID)
			}
		}

		// Sort empty cells for consistent ordering
		sort.Strings(emptyCells)

		// Assign unpinned windows to empty cells first, then round-robin
		for i, w := range unpinned {
			var cellID string
			if i < len(emptyCells) {
				cellID = emptyCells[i]
			} else {
				// Round-robin to cells with fewest windows
				cellID = findLeastPopulatedCell(result.Assignments)
			}
			result.Assignments[cellID] = append(result.Assignments[cellID], w.ID)
		}
	}
}

// assignPreserve tries to maintain previous window-to-cell mappings.
func assignPreserve(windows []Window, layout *types.Layout, previous map[string][]uint32, result *AssignmentResult) {
	var unassigned []Window

	// Build a lookup of previous cell assignments
	prevCellMap := make(map[uint32]string)
	for cellID, windowIDs := range previous {
		for _, wid := range windowIDs {
			prevCellMap[wid] = cellID
		}
	}

	// First pass: preserve previous assignments
	for _, w := range windows {
		if prevCellID, ok := prevCellMap[w.ID]; ok {
			// Check if cell exists in new layout
			if _, cellExists := result.Assignments[prevCellID]; cellExists {
				result.Assignments[prevCellID] = append(result.Assignments[prevCellID], w.ID)
				continue
			}
		}
		unassigned = append(unassigned, w)
	}

	// Second pass: auto-flow unassigned windows
	if len(unassigned) > 0 {
		for _, w := range unassigned {
			cellID := findLeastPopulatedCell(result.Assignments)
			result.Assignments[cellID] = append(result.Assignments[cellID], w.ID)
		}
	}

	// Third pass: reorder windows within each cell to match previous order
	for cellID, prevWindowIDs := range previous {
		currentWindows, ok := result.Assignments[cellID]
		if !ok || len(currentWindows) == 0 {
			continue
		}

		// Build set of currently assigned windows for O(1) lookup
		currentSet := make(map[uint32]bool)
		for _, wid := range currentWindows {
			currentSet[wid] = true
		}

		// Rebuild list preserving previous order
		reordered := make([]uint32, 0, len(currentWindows))

		// First: add windows in their previous order
		for _, wid := range prevWindowIDs {
			if currentSet[wid] {
				reordered = append(reordered, wid)
				delete(currentSet, wid)
			}
		}

		// Then: append any new windows (not in previous)
		for _, wid := range currentWindows {
			if currentSet[wid] {
				reordered = append(reordered, wid)
			}
		}

		result.Assignments[cellID] = reordered
	}
}

// assignByPosition assigns windows to cells based on maximum overlap with current position.
func assignByPosition(windows []Window, cellBounds map[string]types.Rect, result *AssignmentResult) {
	logging.Debug().Int("windows", len(windows)).Int("cells", len(cellBounds)).Msg("assign by position")

	for _, w := range windows {
		logging.Debug().
			Uint32("wid", w.ID).
			Str("app", w.AppName).
			Float64("x", w.Frame.X).
			Float64("y", w.Frame.Y).
			Float64("w", w.Frame.Width).
			Float64("h", w.Frame.Height).
			Msg("window frame")

		bestCell := ""
		bestOverlap := 0.0

		for cellID, bounds := range cellBounds {
			overlap := w.Frame.Overlap(bounds)
			logging.Debug().
				Str("cell", cellID).
				Float64("x", bounds.X).
				Float64("y", bounds.Y).
				Float64("w", bounds.Width).
				Float64("h", bounds.Height).
				Float64("overlap", overlap).
				Msg("cell overlap")
			if overlap > bestOverlap {
				bestOverlap = overlap
				bestCell = cellID
			}
		}

		if bestCell != "" {
			logging.Debug().Str("cell", bestCell).Float64("overlap", bestOverlap).Msg("assigned")
			result.Assignments[bestCell] = append(result.Assignments[bestCell], w.ID)
		} else {
			cellID := findLeastPopulatedCell(result.Assignments)
			logging.Debug().Str("cell", cellID).Msg("no overlap, fallback")
			result.Assignments[cellID] = append(result.Assignments[cellID], w.ID)
		}
	}
}

// findLeastPopulatedCell returns the cell ID with fewest windows.
// Uses alphabetical ordering as tiebreaker for deterministic behavior.
func findLeastPopulatedCell(assignments map[string][]uint32) string {
	var minCellID string
	minCount := -1

	// Sort keys for deterministic behavior
	var cellIDs []string
	for id := range assignments {
		cellIDs = append(cellIDs, id)
	}
	sort.Strings(cellIDs)

	for _, id := range cellIDs {
		count := len(assignments[id])
		if minCount < 0 || count < minCount {
			minCount = count
			minCellID = id
		}
	}

	return minCellID
}

// GetPreferredCell returns the preferred cell for a window based on app rules.
// Returns empty string if no preference is defined.
func GetPreferredCell(w Window, rules []config.AppRule) string {
	for _, rule := range rules {
		if matchesAppRule(w, rule) && rule.PreferredCell != "" {
			return rule.PreferredCell
		}
	}
	return ""
}
