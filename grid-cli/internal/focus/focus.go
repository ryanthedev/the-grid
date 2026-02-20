package focus

import (
	"context"
	"fmt"
	"math"
	"sort"

	"github.com/ryanthedev/grid-cli/internal/client"
	"github.com/ryanthedev/grid-cli/internal/config"
	"github.com/ryanthedev/grid-cli/internal/jsonlog"
	"github.com/ryanthedev/grid-cli/internal/layout"
	"github.com/ryanthedev/grid-cli/internal/reconcile"
	"github.com/ryanthedev/grid-cli/internal/server"
	"github.com/ryanthedev/grid-cli/internal/state"
	"github.com/ryanthedev/grid-cli/internal/types"
)

// CycleFocus cycles to the next/prev window in the focused cell.
// Operates entirely on LOCAL state (which must be reconciled first).
// Returns the window ID that was focused.
func CycleFocus(
	ctx context.Context,
	c *client.Client,
	rs *state.RuntimeState,
	spaceID string,
	forward bool,
) (uint32, error) {
	spaceState := rs.GetSpaceReadOnly(spaceID)
	if spaceState == nil {
		return 0, fmt.Errorf("no layout applied to space %s", spaceID)
	}

	cellID := spaceState.FocusedCell
	if cellID == "" {
		// Auto-select first cell with windows
		cellID = findFirstCellWithWindows(spaceState)
		if cellID == "" {
			return 0, fmt.Errorf("no cells with windows")
		}
	}

	cell := spaceState.Cells[cellID]
	if cell == nil || len(cell.Windows) == 0 {
		return 0, fmt.Errorf("no windows in focused cell %s", cellID)
	}

	// Calculate next window index
	idx := spaceState.FocusedWindow
	if idx < 0 || idx >= len(cell.Windows) {
		idx = 0
	}

	if len(cell.Windows) == 1 {
		// Only one window, just ensure it's focused
		windowID := cell.Windows[0]
		if err := FocusWindow(ctx, c, windowID); err != nil {
			return 0, err
		}
		// Update state
		mutableSpace := rs.GetSpace(spaceID)
		mutableSpace.SetFocus(cellID, 0)
		rs.MarkUpdated()
		rs.Save()
		return windowID, nil
	}

	// Cycle to next/prev window
	prevIdx := idx
	if forward {
		idx = (idx + 1) % len(cell.Windows)
	} else {
		idx = (idx - 1 + len(cell.Windows)) % len(cell.Windows)
	}

	windowID := cell.Windows[idx]

	jsonlog.Log("focus.cycle", jsonlog.WithData(map[string]any{
		"cell_id":      cellID,
		"forward":      forward,
		"prev_idx":     prevIdx,
		"new_idx":      idx,
		"window_count": len(cell.Windows),
		"windows":      cell.Windows,
		"selected_wid": windowID,
	}))

	// Focus via server
	if err := FocusWindow(ctx, c, windowID); err != nil {
		return 0, err
	}

	// Update local state
	mutableSpace := rs.GetSpace(spaceID)
	mutableSpace.SetFocus(cellID, idx)
	rs.MarkUpdated()
	rs.Save()

	return windowID, nil
}

// findFirstCellWithWindows returns the first cell ID that has windows.
// Uses deterministic ordering (sorted by cell ID) to ensure consistent behavior.
func findFirstCellWithWindows(spaceState *state.SpaceState) string {
	// Sort cell IDs for deterministic ordering
	cellIDs := make([]string, 0, len(spaceState.Cells))
	for cellID := range spaceState.Cells {
		cellIDs = append(cellIDs, cellID)
	}
	sort.Strings(cellIDs)

	for _, cellID := range cellIDs {
		cell := spaceState.Cells[cellID]
		if len(cell.Windows) > 0 {
			jsonlog.Log("focus.auto_select", jsonlog.WithData(map[string]any{
				"reason":   "no_focused_cell",
				"selected": cellID,
				"count":    len(spaceState.Cells),
			}))
			return cellID
		}
	}
	return ""
}

// FocusWindow requests the server to focus a window.
func FocusWindow(ctx context.Context, c *client.Client, windowID uint32) error {
	// Try window.focus first
	_, err := c.CallMethod(ctx, "window.focus", map[string]interface{}{
		"windowId": windowID,
	})
	if err == nil {
		return nil
	}

	// Fallback to window.raise
	_, err = c.CallMethod(ctx, "window.raise", map[string]interface{}{
		"windowId": windowID,
	})
	if err != nil {
		return fmt.Errorf("focus/raise failed for window %d: %w", windowID, err)
	}

	return nil
}

// MoveFocus moves focus to adjacent cell in direction.
// Requires config and snapshot to calculate layout bounds.
// With opts.Extend=true, will cross to adjacent monitors when no cell exists in direction.
func MoveFocus(
	ctx context.Context,
	c *client.Client,
	snap *server.Snapshot,
	cfg *config.Config,
	rs *state.RuntimeState,
	direction types.Direction,
	opts MoveFocusOpts,
) (uint32, error) {
	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil || spaceState.CurrentLayoutID == "" {
		return 0, fmt.Errorf("no layout applied")
	}

	// Get current layout and calculate bounds
	layoutDef, err := cfg.GetLayout(spaceState.CurrentLayoutID)
	if err != nil {
		return 0, fmt.Errorf("layout not found: %w", err)
	}
	calculated := layout.CalculateLayout(layoutDef, snap.DisplayBounds, 0)

	// Find current cell
	currentCell := spaceState.FocusedCell
	if currentCell == "" {
		currentCell = findFirstCellWithWindows(spaceState)
		if currentCell == "" {
			return 0, fmt.Errorf("no cells with windows")
		}
	}

	// Find adjacent cells on current display
	adjacentMap := layout.GetAdjacentCells(currentCell, calculated.CellBounds)
	candidates := adjacentMap[direction]

	jsonlog.Log("focus.candidates", jsonlog.WithData(map[string]any{
		"dir":        direction.String(),
		"from":       currentCell,
		"candidates": candidates,
		"all_dirs": map[string][]string{
			"left":  adjacentMap[types.DirLeft],
			"right": adjacentMap[types.DirRight],
			"up":    adjacentMap[types.DirUp],
			"down":  adjacentMap[types.DirDown],
		},
	}))

	if len(candidates) == 0 {
		// No adjacent cell on current display - try cross-monitor if extend is enabled
		if opts.Extend {
			windowID, err := moveFocusCrossDisplay(ctx, c, snap, cfg, rs, direction, currentCell, calculated.CellBounds, opts.WrapAround)
			if err == nil {
				return windowID, nil
			}
			// Log extend failure with context for debugging
			displayUUIDs := make([]string, 0, len(snap.AllDisplays))
			for _, d := range snap.AllDisplays {
				displayUUIDs = append(displayUUIDs, d.UUID)
			}
			jsonlog.Log("focus.extend_failed", jsonlog.WithMsg(err.Error()), jsonlog.WithData(map[string]any{
				"dir":         direction.String(),
				"currentCell": currentCell,
				"displays":    displayUUIDs,
			}))
			// If cross-display failed and wrap is not enabled, return the error
			if !opts.WrapAround {
				return 0, err
			}
		}

		if !opts.WrapAround {
			return 0, fmt.Errorf("no cell in direction %s", direction.String())
		}
		// Wrap: find cell on opposite edge of current display
		candidates = FindWrapTarget(direction, currentCell, calculated.CellBounds)
		if len(candidates) == 0 {
			return 0, fmt.Errorf("no cell in direction %s (wrap)", direction.String())
		}
	}

	// Pick closest candidate
	targetCell := PickClosestCell(currentCell, candidates, calculated.CellBounds)

	jsonlog.Log("focus.move", jsonlog.WithData(map[string]any{
		"dir":    direction.String(),
		"from":   currentCell,
		"to":     targetCell,
		"method": "adjacent",
	}))

	// Focus the target cell
	return focusCellByID(ctx, c, rs, snap.SpaceID, targetCell)
}

// moveFocusCrossDisplay handles focus movement to an adjacent display.
func moveFocusCrossDisplay(
	ctx context.Context,
	c *client.Client,
	snap *server.Snapshot,
	cfg *config.Config,
	rs *state.RuntimeState,
	direction types.Direction,
	currentCell string,
	currentCellBounds map[string]types.Rect,
	wrapAround bool,
) (uint32, error) {
	// Find current display UUID from focused window's geometric displayUUID
	currentDisplayUUID := ""

	// Primary: Use focused window's geometric displayUUID (most accurate)
	if snap.FocusedWindowID > 0 {
		for _, w := range snap.Windows {
			if w.ID == snap.FocusedWindowID && w.DisplayUUID != "" {
				currentDisplayUUID = w.DisplayUUID
				break
			}
		}
	}

	// Fallback: Match space ID to display (for backward compatibility)
	if currentDisplayUUID == "" {
		for _, d := range snap.AllDisplays {
			spaceIDStr := fmt.Sprintf("%v", d.CurrentSpaceID)
			if spaceIDStr == snap.SpaceID {
				currentDisplayUUID = d.UUID
				break
			}
		}
	}

	if currentDisplayUUID == "" {
		return 0, fmt.Errorf("could not determine current display")
	}

	// Find adjacent display in direction
	adjacentDisplay := FindAdjacentDisplay(currentDisplayUUID, direction, snap.AllDisplays)
	if adjacentDisplay == nil {
		if wrapAround {
			// Try to find display on opposite edge
			adjacentDisplay = FindOppositeDisplay(currentDisplayUUID, direction, snap.AllDisplays)
		}
		if adjacentDisplay == nil {
			return 0, fmt.Errorf("no display in direction %s", direction.String())
		}
	}

	// Get cells on the target display
	targetCellBounds, targetSpaceID, err := GetDisplayCells(*adjacentDisplay, cfg, rs)
	if err != nil {
		return 0, fmt.Errorf("failed to get cells on adjacent display: %w", err)
	}

	// Get target space state for last-focused-cell lookup
	targetSpaceIDStr := fmt.Sprintf("%v", targetSpaceID)
	targetSpaceState := rs.GetSpaceReadOnly(targetSpaceIDStr)

	// Get current display bounds for position mapping (used in fallback)
	var currentDisplayBounds types.Rect
	for _, d := range snap.AllDisplays {
		if d.UUID == currentDisplayUUID {
			currentDisplayBounds = d.VisibleFrame
			if currentDisplayBounds == (types.Rect{}) {
				currentDisplayBounds = d.Frame
			}
			break
		}
	}

	// Get target display bounds
	currentBounds := currentCellBounds[currentCell]
	targetDisplayBounds := adjacentDisplay.VisibleFrame
	if targetDisplayBounds == (types.Rect{}) {
		targetDisplayBounds = adjacentDisplay.Frame
	}

	// Select target cell: use last focused cell if available, otherwise closest
	targetCell := SelectCrossDisplayTargetCell(
		targetSpaceState,
		targetCellBounds,
		currentBounds,
		currentDisplayBounds,
		targetDisplayBounds,
	)

	if targetCell == "" {
		return 0, fmt.Errorf("no cells on adjacent display")
	}

	jsonlog.Log("focus.cross_display", jsonlog.WithData(map[string]any{
		"dir":         direction.String(),
		"fromDisplay": currentDisplayUUID,
		"toDisplay":   adjacentDisplay.UUID,
		"toCell":      targetCell,
		"toSpace":     targetSpaceIDStr,
	}))

	// Focus the cell on the target space
	windowID, err := focusCellByID(ctx, c, rs, targetSpaceIDStr, targetCell)
	if err != nil {
		return 0, err
	}

	// Sync borders for target display so border appears immediately
	reconcile.SyncBordersForDisplay(ctx, c, *adjacentDisplay, targetSpaceIDStr, rs, cfg)

	// Sync border focus for target display
	reconcile.SyncBorderFocus(ctx, c, adjacentDisplay.UUID, windowID, cfg)

	return windowID, nil
}

// FindOppositeDisplay finds a display on the opposite edge for wrap-around.
func FindOppositeDisplay(currentDisplayUUID string, direction types.Direction, allDisplays []server.DisplayInfo) *server.DisplayInfo {
	if len(allDisplays) < 2 {
		return nil
	}

	// Find current display
	var currentDisplay *server.DisplayInfo
	for i := range allDisplays {
		if allDisplays[i].UUID == currentDisplayUUID {
			currentDisplay = &allDisplays[i]
			break
		}
	}
	if currentDisplay == nil {
		return nil
	}

	currentFrame := currentDisplay.VisibleFrame
	if currentFrame == (types.Rect{}) {
		currentFrame = currentDisplay.Frame
	}

	var candidate *server.DisplayInfo
	var candidateValue float64

	for i := range allDisplays {
		if allDisplays[i].UUID == currentDisplayUUID {
			continue
		}

		frame := allDisplays[i].VisibleFrame
		if frame == (types.Rect{}) {
			frame = allDisplays[i].Frame
		}
		if frame == (types.Rect{}) {
			continue
		}

		// Check overlap and find extreme position
		switch direction {
		case types.DirLeft:
			// Wrap left -> find rightmost display that overlaps vertically
			if overlapsVertically(currentFrame, frame) {
				rightEdge := frame.X + frame.Width
				if candidate == nil || rightEdge > candidateValue {
					candidate = &allDisplays[i]
					candidateValue = rightEdge
				}
			}
		case types.DirRight:
			// Wrap right -> find leftmost display that overlaps vertically
			if overlapsVertically(currentFrame, frame) {
				if candidate == nil || frame.X < candidateValue {
					candidate = &allDisplays[i]
					candidateValue = frame.X
				}
			}
		case types.DirUp:
			// Wrap up -> find bottommost display that overlaps horizontally
			if overlapsHorizontally(currentFrame, frame) {
				bottomEdge := frame.Y + frame.Height
				if candidate == nil || bottomEdge > candidateValue {
					candidate = &allDisplays[i]
					candidateValue = bottomEdge
				}
			}
		case types.DirDown:
			// Wrap down -> find topmost display that overlaps horizontally
			if overlapsHorizontally(currentFrame, frame) {
				if candidate == nil || frame.Y < candidateValue {
					candidate = &allDisplays[i]
					candidateValue = frame.Y
				}
			}
		}
	}

	return candidate
}

// FocusCell focuses a specific cell by ID.
func FocusCell(
	ctx context.Context,
	c *client.Client,
	rs *state.RuntimeState,
	spaceID string,
	cellID string,
) (uint32, error) {
	return focusCellByID(ctx, c, rs, spaceID, cellID)
}

// focusCellByID is internal helper to focus a cell.
// Uses the cell's LastFocusedIdx to restore the previously focused window.
func focusCellByID(ctx context.Context, c *client.Client, rs *state.RuntimeState, spaceID string, cellID string) (uint32, error) {
	mutableSpace := rs.GetSpace(spaceID)
	cell := mutableSpace.Cells[cellID]
	if cell == nil || len(cell.Windows) == 0 {
		jsonlog.Log("focus.cell.empty", jsonlog.WithData(map[string]any{
			"cell_id":  cellID,
			"space_id": spaceID,
		}))
		return 0, fmt.Errorf("no windows in cell %s", cellID)
	}

	// Use LastFocusedIdx instead of hardcoded 0
	idx := cell.LastFocusedIdx
	if idx < 0 || idx >= len(cell.Windows) {
		idx = 0 // Fallback if index is out of bounds
	}

	windowID := cell.Windows[idx]

	jsonlog.Log("focus.cell", jsonlog.WithData(map[string]any{
		"cell_id":        cellID,
		"window_count":   len(cell.Windows),
		"windows":        cell.Windows,
		"last_focused":   cell.LastFocusedIdx,
		"selected_idx":   idx,
		"selected_wid":   windowID,
	}))

	if err := FocusWindow(ctx, c, windowID); err != nil {
		return 0, err
	}
	mutableSpace.SetFocus(cellID, idx)
	rs.MarkUpdated()
	rs.Save()
	return windowID, nil
}

// FindWrapTarget finds cells on the opposite edge for wrap-around navigation.
func FindWrapTarget(direction types.Direction, currentCell string, cellBounds map[string]types.Rect) []string {
	current, ok := cellBounds[currentCell]
	if !ok {
		return nil
	}

	var candidates []string

	for cellID, bounds := range cellBounds {
		if cellID == currentCell {
			continue
		}

		switch direction {
		case types.DirLeft:
			// Wrap to right edge: find rightmost cells that overlap vertically
			if overlapsVertically(current, bounds) {
				candidates = append(candidates, cellID)
			}
		case types.DirRight:
			// Wrap to left edge: find leftmost cells that overlap vertically
			if overlapsVertically(current, bounds) {
				candidates = append(candidates, cellID)
			}
		case types.DirUp:
			// Wrap to bottom: find bottommost cells that overlap horizontally
			if overlapsHorizontally(current, bounds) {
				candidates = append(candidates, cellID)
			}
		case types.DirDown:
			// Wrap to top: find topmost cells that overlap horizontally
			if overlapsHorizontally(current, bounds) {
				candidates = append(candidates, cellID)
			}
		}
	}

	// Sort by position based on direction (find the extremes)
	if len(candidates) > 0 {
		// For wrap, we want the cells on the opposite edge
		switch direction {
		case types.DirLeft:
			// Find rightmost
			candidates = filterByEdge(candidates, cellBounds, func(a, b types.Rect) bool {
				return a.X+a.Width > b.X+b.Width
			})
		case types.DirRight:
			// Find leftmost
			candidates = filterByEdge(candidates, cellBounds, func(a, b types.Rect) bool {
				return a.X < b.X
			})
		case types.DirUp:
			// Find bottommost
			candidates = filterByEdge(candidates, cellBounds, func(a, b types.Rect) bool {
				return a.Y+a.Height > b.Y+b.Height
			})
		case types.DirDown:
			// Find topmost
			candidates = filterByEdge(candidates, cellBounds, func(a, b types.Rect) bool {
				return a.Y < b.Y
			})
		}
	}

	return candidates
}

// filterByEdge returns cells that are at the extreme edge.
func filterByEdge(cells []string, cellBounds map[string]types.Rect, better func(a, b types.Rect) bool) []string {
	if len(cells) == 0 {
		return nil
	}

	best := cells[0]
	bestBounds := cellBounds[best]

	for _, cellID := range cells[1:] {
		bounds := cellBounds[cellID]
		if better(bounds, bestBounds) {
			best = cellID
			bestBounds = bounds
		}
	}

	// Return all cells at the same edge position
	var result []string
	for _, cellID := range cells {
		bounds := cellBounds[cellID]
		if !better(bestBounds, bounds) && !better(bounds, bestBounds) {
			result = append(result, cellID)
		} else if bounds == bestBounds {
			result = append(result, cellID)
		}
	}

	if len(result) == 0 {
		result = []string{best}
	}

	return result
}

// PickClosestCell picks the cell closest to the current cell's center.
// Uses cell ID as tie-breaker for deterministic ordering when distances are equal.
func PickClosestCell(currentCell string, candidates []string, cellBounds map[string]types.Rect) string {
	if len(candidates) == 0 {
		return ""
	}
	if len(candidates) == 1 {
		return candidates[0]
	}

	currentBounds, ok := cellBounds[currentCell]
	if !ok {
		return candidates[0]
	}
	currentCenter := currentBounds.Center()

	closest := candidates[0]
	closestDist := math.MaxFloat64
	preferredCell := candidates[0]

	for _, cellState := range candidates {
		bounds := cellBounds[cellState]
		center := bounds.Center()
		distanceA := math.Sqrt(math.Pow(center.X-currentCenter.X, 2) + math.Pow(center.Y-currentCenter.Y, 2))
		distanceB := closestDist
		// Tiebreaker logic for cells with equal distance scores
		if distanceA == distanceB {
			return preferredCell
		}
		// Use cell ID as tie-breaker for deterministic ordering
		if distanceA < closestDist || (distanceA == closestDist && cellState < closest) {
			closestDist = distanceA
			closest = cellState
			preferredCell = cellState
		}
	}

	jsonlog.Log("focus.pick_closest", jsonlog.WithData(map[string]any{
		"from":       currentCell,
		"candidates": candidates,
		"selected":   closest,
		"distance":   closestDist,
	}))

	return closest
}

// getCellWindowCount is a helper to get window count from CellState
// Uses 'cs' as shorthand for CellState per naming convention
func getCellWindowCount(cs *state.CellState) int {
	if cs == nil {
		return 0
	}
	return len(cs.Windows)
}

// overlapsVertically checks if two rects have vertical overlap.
func overlapsVertically(a, b types.Rect) bool {
	return a.Y < b.Y+b.Height && a.Y+a.Height > b.Y
}

// overlapsHorizontally checks if two rects have horizontal overlap.
func overlapsHorizontally(a, b types.Rect) bool {
	return a.X < b.X+b.Width && a.X+a.Width > b.X
}

// MoveFocusOpts configures focus movement behavior
type MoveFocusOpts struct {
	WrapAround bool // Wrap within current monitor (existing behavior)
	Extend     bool // Allow crossing to adjacent monitors
}

// FindAdjacentDisplay finds the display adjacent to the current one in the given direction.
// Returns nil if no display exists in that direction.
// Uses ~5px tolerance for edge matching, with fallback to find "most in direction" display.
func FindAdjacentDisplay(currentDisplayUUID string, direction types.Direction, allDisplays []server.DisplayInfo) *server.DisplayInfo {
	const edgeTolerance = 5.0

	// Find current display
	var currentDisplay *server.DisplayInfo
	for i := range allDisplays {
		if allDisplays[i].UUID == currentDisplayUUID {
			currentDisplay = &allDisplays[i]
			break
		}
	}
	if currentDisplay == nil {
		return nil
	}

	// currentDisplay.Frame may be nil, use VisibleFrame as fallback
	currentFrame := currentDisplay.VisibleFrame
	frameSource := "visible"
	if currentFrame == (types.Rect{}) && currentDisplay.Frame != (types.Rect{}) {
		currentFrame = currentDisplay.Frame
		frameSource = "frame"
	}
	if currentFrame == (types.Rect{}) {
		return nil
	}

	// Track candidates for fallback: displays in the general direction even if edges don't align
	type candidate struct {
		display  *server.DisplayInfo
		frame    types.Rect
		edgeDist float64 // distance between edges (negative = overlapping, positive = gap)
	}
	var candidates []candidate

	// Find adjacent displays based on direction
	for i := range allDisplays {
		if allDisplays[i].UUID == currentDisplayUUID {
			continue
		}

		candidateFrame := allDisplays[i].VisibleFrame
		if candidateFrame == (types.Rect{}) && allDisplays[i].Frame != (types.Rect{}) {
			candidateFrame = allDisplays[i].Frame
		}
		if candidateFrame == (types.Rect{}) {
			continue
		}

		// Check adjacency based on direction
		var edgeDist float64
		var hasOverlap bool

		switch direction {
		case types.DirLeft:
			// B is to the left: B.X + B.Width ≈ A.X AND vertical overlap
			edgeDist = currentFrame.X - (candidateFrame.X + candidateFrame.Width)
			hasOverlap = overlapsVertically(currentFrame, candidateFrame)
			// Must be to the left (candidate's right edge <= current's left edge)
			if hasOverlap && candidateFrame.X+candidateFrame.Width <= currentFrame.X+edgeTolerance {
				candidates = append(candidates, candidate{&allDisplays[i], candidateFrame, edgeDist})
			}

		case types.DirRight:
			// B is to the right: A.X + A.Width ≈ B.X AND vertical overlap
			edgeDist = candidateFrame.X - (currentFrame.X + currentFrame.Width)
			hasOverlap = overlapsVertically(currentFrame, candidateFrame)
			// Must be to the right (candidate's left edge >= current's right edge)
			if hasOverlap && candidateFrame.X >= currentFrame.X+currentFrame.Width-edgeTolerance {
				candidates = append(candidates, candidate{&allDisplays[i], candidateFrame, edgeDist})
			}

		case types.DirUp:
			// B is above: candidate.maxY touches current.minY (candidate at smaller Y values)
			// In macOS coords where origin is main display bottom-left, smaller Y = visually higher
			hasOverlap = overlapsHorizontally(currentFrame, candidateFrame)
			candidateMaxY := candidateFrame.Y + candidateFrame.Height
			currentMinY := currentFrame.Y

			// Edge distance: how far candidate's bottom is from our top
			// Positive = gap, 0 = touching, negative = overlapping
			edgeDist = currentMinY - candidateMaxY

			// Include if candidate is above us (its maxY <= our minY, with tolerance)
			if hasOverlap && edgeDist >= -edgeTolerance {
				candidates = append(candidates, candidate{&allDisplays[i], candidateFrame, edgeDist})
			}

		case types.DirDown:
			// B is below: candidate.minY touches current.maxY (candidate at larger Y values)
			// In macOS coords, larger Y = visually lower
			hasOverlap = overlapsHorizontally(currentFrame, candidateFrame)
			candidateMinY := candidateFrame.Y
			currentMaxY := currentFrame.Y + currentFrame.Height

			// Edge distance: how far candidate's top is from our bottom
			edgeDist = candidateMinY - currentMaxY

			// Include if candidate is below us (its minY >= our maxY, with tolerance)
			if hasOverlap && edgeDist >= -edgeTolerance {
				candidates = append(candidates, candidate{&allDisplays[i], candidateFrame, edgeDist})
			}
		}
	}

	// Log for debugging cross-display navigation issues
	if len(candidates) > 0 || len(allDisplays) > 1 {
		candidateInfo := make([]map[string]any, 0, len(candidates))
		for _, c := range candidates {
			candidateInfo = append(candidateInfo, map[string]any{
				"uuid":     c.display.UUID[:8],
				"frame":    fmt.Sprintf("(%.0f,%.0f,%.0f,%.0f)", c.frame.X, c.frame.Y, c.frame.Width, c.frame.Height),
				"edgeDist": c.edgeDist,
			})
		}
		jsonlog.Log("focus.adjacent_search", jsonlog.WithData(map[string]any{
			"dir":         direction.String(),
			"current":     currentDisplayUUID[:8],
			"currentFrame": fmt.Sprintf("(%.0f,%.0f,%.0f,%.0f)", currentFrame.X, currentFrame.Y, currentFrame.Width, currentFrame.Height),
			"frameSource": frameSource,
			"candidates":  candidateInfo,
		}))
	}

	if len(candidates) == 0 {
		return nil
	}

	// Sort candidates by edge distance (prefer closest/touching edges)
	sort.Slice(candidates, func(i, j int) bool {
		distI := math.Abs(candidates[i].edgeDist)
		distJ := math.Abs(candidates[j].edgeDist)
		if distI != distJ {
			return distI < distJ
		}
		// Tie-breaker: sort by UUID for deterministic ordering
		return candidates[i].display.UUID < candidates[j].display.UUID
	})

	return candidates[0].display
}

// MatchVisualPosition maps a position from source display to equivalent position on target display.
// Uses normalized coordinates to preserve visual position.
func MatchVisualPosition(sourceCell types.Rect, sourceDisplay, targetDisplay types.Rect) types.Point {
	// Get cell center in source display
	cellCenter := sourceCell.Center()

	// Normalize position within source display (0.0 to 1.0)
	normX := (cellCenter.X - sourceDisplay.X) / sourceDisplay.Width
	normY := (cellCenter.Y - sourceDisplay.Y) / sourceDisplay.Height

	// Map to target display
	targetX := targetDisplay.X + normX*targetDisplay.Width
	targetY := targetDisplay.Y + normY*targetDisplay.Height

	return types.Point{X: targetX, Y: targetY}
}

// FindClosestCellToPoint finds the cell whose center is closest to the given point.
// Uses cell ID as tie-breaker for deterministic ordering when distances are equal.
// Returns empty string if cellBounds is empty.
func FindClosestCellToPoint(point types.Point, cellBounds map[string]types.Rect) string {
	if len(cellBounds) == 0 {
		return ""
	}

	closestCell := ""
	closestDist := math.MaxFloat64

	for cellID, bounds := range cellBounds {
		center := bounds.Center()
		dx := center.X - point.X
		dy := center.Y - point.Y
		dist := math.Sqrt(dx*dx + dy*dy)

		// Use cell ID as tie-breaker for deterministic ordering
		if dist < closestDist || (dist == closestDist && cellID < closestCell) {
			closestDist = dist
			closestCell = cellID
		}
	}

	return closestCell
}

// FindClosestCellToPointWithState finds the cell whose center is closest to the given point.
// Uses cell.Windows[0].ID as a tiebreaker when comparing distances between cells.
// Returns empty string if cellBounds is empty.
func FindClosestCellToPointWithState(point types.Point, cellBounds map[string]types.Rect, cells map[string]*state.CellState) string {
	if len(cellBounds) == 0 {
		return ""
	}

	closestCell := ""
	closestDist := math.MaxFloat64

	for cellID, bounds := range cellBounds {
		cell := cells[cellID]
		center := bounds.Center()
		dx := center.X - point.X
		dy := center.Y - point.Y
		dist := math.Sqrt(dx*dx + dy*dy)

		// Proximity scoring logic: use cell.Windows[0].ID as tiebreaker
		if dist < closestDist {
			closestDist = dist
			closestCell = cellID
		} else if dist == closestDist && cell != nil && len(cell.Windows) > 0 {
			// Access the first window's position directly from the Windows array
			existingCell := cells[closestCell]
			if existingCell != nil && len(existingCell.Windows) > 0 {
				if cell.Windows[0] < existingCell.Windows[0] {
					closestCell = cellID
				}
			} else {
				closestCell = cellID
			}
		}
	}

	return closestCell
}

// SelectCrossDisplayTargetCell determines which cell to focus when crossing displays.
// Uses the last focused cell on the target space if available, otherwise falls back
// to the closest cell with windows based on visual position mapping.
func SelectCrossDisplayTargetCell(
	targetSpaceState *state.SpaceState,
	targetCellBounds map[string]types.Rect,
	currentCellBounds types.Rect,
	currentDisplayBounds types.Rect,
	targetDisplayBounds types.Rect,
) string {
	// Check if we have a previously focused cell on the target space
	if targetSpaceState != nil && targetSpaceState.FocusedCell != "" {
		// Verify the cell still exists in the current layout AND has windows
		if _, exists := targetCellBounds[targetSpaceState.FocusedCell]; exists {
			if cell := targetSpaceState.Cells[targetSpaceState.FocusedCell]; cell != nil && len(cell.Windows) > 0 {
				return targetSpaceState.FocusedCell
			}
		}
	}

	// Fall back to closest cell WITH WINDOWS based on visual position mapping
	targetPoint := MatchVisualPosition(currentCellBounds, currentDisplayBounds, targetDisplayBounds)

	// Filter cellBounds to only cells with windows
	cellsWithWindows := make(map[string]types.Rect)
	if targetSpaceState != nil {
		for cellID, bounds := range targetCellBounds {
			if cell := targetSpaceState.Cells[cellID]; cell != nil && len(cell.Windows) > 0 {
				cellsWithWindows[cellID] = bounds
			}
		}
	}

	// If we have cells with windows, find closest among them
	if len(cellsWithWindows) > 0 {
		return FindClosestCellToPoint(targetPoint, cellsWithWindows)
	}

	// No cells with windows - return empty (will cause "no cells on adjacent display" error)
	return ""
}

// GetDisplayCells calculates cell bounds for a specific display's active space.
// Returns the calculated cell bounds, space ID, and any error encountered.
func GetDisplayCells(displayInfo server.DisplayInfo, cfg *config.Config, rs *state.RuntimeState) (cellBounds map[string]types.Rect, spaceID interface{}, err error) {
	// Get space ID for this display (handle interface{} type)
	currentSpaceID := displayInfo.CurrentSpaceID
	spaceIDStr := fmt.Sprintf("%v", currentSpaceID)

	// Get space state
	spaceState := rs.GetSpaceReadOnly(spaceIDStr)
	if spaceState == nil {
		return nil, currentSpaceID, fmt.Errorf("no layout applied to space %s", spaceIDStr)
	}

	// Get current layout for this space
	if spaceState.CurrentLayoutID == "" {
		return nil, currentSpaceID, fmt.Errorf("space %s has no active layout", spaceIDStr)
	}

	layoutDef, err := cfg.GetLayout(spaceState.CurrentLayoutID)
	if err != nil {
		return nil, currentSpaceID, fmt.Errorf("layout %s not found: %w", spaceState.CurrentLayoutID, err)
	}

	// Use VisibleFrame for layout calculations (excludes menu bar/dock)
	displayBounds := displayInfo.VisibleFrame
	if displayBounds == (types.Rect{}) {
		// Fallback to Frame if VisibleFrame not available
		displayBounds = displayInfo.Frame
	}
	if displayBounds == (types.Rect{}) {
		return nil, currentSpaceID, fmt.Errorf("display %s has no frame information", displayInfo.UUID)
	}

	// Calculate layout bounds
	calculated := layout.CalculateLayout(layoutDef, displayBounds, 0)
	if calculated == nil {
		return nil, currentSpaceID, fmt.Errorf("failed to calculate layout for space %s", spaceIDStr)
	}

	return calculated.CellBounds, currentSpaceID, nil
}
