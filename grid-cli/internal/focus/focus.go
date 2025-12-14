package focus

import (
	"context"
	"fmt"
	"math"

	"github.com/yourusername/grid-cli/internal/client"
	"github.com/yourusername/grid-cli/internal/config"
	"github.com/yourusername/grid-cli/internal/layout"
	"github.com/yourusername/grid-cli/internal/server"
	"github.com/yourusername/grid-cli/internal/state"
	"github.com/yourusername/grid-cli/internal/types"
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
	if forward {
		idx = (idx + 1) % len(cell.Windows)
	} else {
		idx = (idx - 1 + len(cell.Windows)) % len(cell.Windows)
	}

	windowID := cell.Windows[idx]

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
func findFirstCellWithWindows(spaceState *state.SpaceState) string {
	for cellID, cell := range spaceState.Cells {
		if len(cell.Windows) > 0 {
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

	if len(candidates) == 0 {
		// No adjacent cell on current display - try cross-monitor if extend is enabled
		if opts.Extend {
			windowID, err := moveFocusCrossDisplay(ctx, c, snap, cfg, rs, direction, currentCell, calculated.CellBounds, opts.WrapAround)
			if err == nil {
				return windowID, nil
			}
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
	// Find current display UUID from snapshot
	currentDisplayUUID := ""
	for _, d := range snap.AllDisplays {
		spaceIDStr := fmt.Sprintf("%v", d.CurrentSpaceID)
		if spaceIDStr == snap.SpaceID {
			currentDisplayUUID = d.UUID
			break
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

	// Get current display bounds for position mapping
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

	// Map visual position from current cell to target display
	currentBounds := currentCellBounds[currentCell]
	targetDisplayBounds := adjacentDisplay.VisibleFrame
	if targetDisplayBounds == (types.Rect{}) {
		targetDisplayBounds = adjacentDisplay.Frame
	}

	targetPoint := MatchVisualPosition(currentBounds, currentDisplayBounds, targetDisplayBounds)

	// Find closest cell to target point
	targetCell := FindClosestCellToPoint(targetPoint, targetCellBounds)
	if targetCell == "" {
		return 0, fmt.Errorf("no cells on adjacent display")
	}

	// Focus the cell on the target space
	targetSpaceIDStr := fmt.Sprintf("%v", targetSpaceID)
	return focusCellByID(ctx, c, rs, targetSpaceIDStr, targetCell)
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
		return 0, fmt.Errorf("no windows in cell %s", cellID)
	}

	// Use LastFocusedIdx instead of hardcoded 0
	idx := cell.LastFocusedIdx
	if idx < 0 || idx >= len(cell.Windows) {
		idx = 0 // Fallback if index is out of bounds
	}

	windowID := cell.Windows[idx]
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

	for _, cellID := range candidates {
		bounds := cellBounds[cellID]
		center := bounds.Center()
		dist := math.Sqrt(math.Pow(center.X-currentCenter.X, 2) + math.Pow(center.Y-currentCenter.Y, 2))
		if dist < closestDist {
			closestDist = dist
			closest = cellID
		}
	}

	return closest
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
// Uses ~5px tolerance for edge matching to handle minor alignment differences.
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
	if currentFrame == (types.Rect{}) && currentDisplay.Frame != (types.Rect{}) {
		currentFrame = currentDisplay.Frame
	}
	if currentFrame == (types.Rect{}) {
		return nil
	}

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
		isAdjacent := false
		switch direction {
		case types.DirLeft:
			// B is to the left: B.X + B.Width ≈ A.X AND vertical overlap
			edgesAlign := math.Abs((candidateFrame.X+candidateFrame.Width)-currentFrame.X) <= edgeTolerance
			verticalOverlap := overlapsVertically(currentFrame, candidateFrame)
			isAdjacent = edgesAlign && verticalOverlap

		case types.DirRight:
			// B is to the right: A.X + A.Width ≈ B.X AND vertical overlap
			edgesAlign := math.Abs((currentFrame.X+currentFrame.Width)-candidateFrame.X) <= edgeTolerance
			verticalOverlap := overlapsVertically(currentFrame, candidateFrame)
			isAdjacent = edgesAlign && verticalOverlap

		case types.DirUp:
			// B is above: B.Y + B.Height ≈ A.Y AND horizontal overlap
			edgesAlign := math.Abs((candidateFrame.Y+candidateFrame.Height)-currentFrame.Y) <= edgeTolerance
			horizontalOverlap := overlapsHorizontally(currentFrame, candidateFrame)
			isAdjacent = edgesAlign && horizontalOverlap

		case types.DirDown:
			// B is below: A.Y + A.Height ≈ B.Y AND horizontal overlap
			edgesAlign := math.Abs((currentFrame.Y+currentFrame.Height)-candidateFrame.Y) <= edgeTolerance
			horizontalOverlap := overlapsHorizontally(currentFrame, candidateFrame)
			isAdjacent = edgesAlign && horizontalOverlap
		}

		if isAdjacent {
			return &allDisplays[i]
		}
	}

	return nil
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

		if dist < closestDist {
			closestDist = dist
			closestCell = cellID
		}
	}

	return closestCell
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
