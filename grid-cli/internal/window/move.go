package window

import (
	"context"
	"fmt"

	"github.com/yourusername/grid-cli/internal/client"
	"github.com/yourusername/grid-cli/internal/config"
	"github.com/yourusername/grid-cli/internal/focus"
	"github.com/yourusername/grid-cli/internal/layout"
	"github.com/yourusername/grid-cli/internal/logging"
	"github.com/yourusername/grid-cli/internal/server"
	"github.com/yourusername/grid-cli/internal/state"
	"github.com/yourusername/grid-cli/internal/types"
)

// MoveWindowOpts configures window movement behavior
type MoveWindowOpts struct {
	WrapAround bool   // Wrap within current monitor
	Extend     bool   // Allow crossing to adjacent monitors
	WindowID   uint32 // Specific window to move (0 = use focused)
}

// MoveResult contains the outcome of a window move
type MoveResult struct {
	WindowID     uint32 // Window that was moved
	SourceCell   string // Original cell ID
	TargetCell   string // Destination cell ID
	SourceSpace  string // Original space ID (for cross-display)
	TargetSpace  string // Destination space ID (for cross-display)
	CrossDisplay bool   // Whether move crossed displays
}

// MoveWindow moves a window to an adjacent cell in the given direction.
// Uses the same adjacency logic as focus movement.
// With opts.Extend=true, will cross to adjacent monitors when no cell exists in direction.
func MoveWindow(
	ctx context.Context,
	c *client.Client,
	snap *server.Snapshot,
	cfg *config.Config,
	rs *state.RuntimeState,
	direction types.Direction,
	opts MoveWindowOpts,
) (*MoveResult, error) {
	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil || spaceState.CurrentLayoutID == "" {
		return nil, fmt.Errorf("no layout applied")
	}

	// Determine which window to move
	windowID := opts.WindowID
	if windowID == 0 {
		windowID = spaceState.GetFocusedWindow()
		if windowID == 0 {
			return nil, fmt.Errorf("no focused window")
		}
	}

	// Find source cell containing the window
	sourceCell := spaceState.GetWindowCell(windowID)
	if sourceCell == "" {
		return nil, fmt.Errorf("window %d not assigned to any cell", windowID)
	}

	logging.Info().
		Uint32("windowId", windowID).
		Str("sourceCell", sourceCell).
		Str("direction", direction.String()).
		Msg("moving window")

	// Get current layout and calculate bounds
	layoutDef, err := cfg.GetLayout(spaceState.CurrentLayoutID)
	if err != nil {
		return nil, fmt.Errorf("layout not found: %w", err)
	}
	calculated := layout.CalculateLayout(layoutDef, snap.DisplayBounds, 0)

	// Find adjacent cells on current display
	adjacentMap := layout.GetAdjacentCells(sourceCell, calculated.CellBounds)
	candidates := adjacentMap[direction]

	if len(candidates) == 0 {
		// No adjacent cell on current display - try cross-monitor if extend is enabled
		if opts.Extend {
			result, err := moveWindowCrossDisplay(ctx, c, snap, cfg, rs, direction, windowID, sourceCell, calculated.CellBounds, opts.WrapAround)
			if err == nil {
				return result, nil
			}
			// If cross-display failed and wrap is not enabled, return the error
			if !opts.WrapAround {
				return nil, err
			}
		}

		if !opts.WrapAround {
			return nil, fmt.Errorf("no cell in direction %s", direction.String())
		}
		// Wrap: find cell on opposite edge of current display
		candidates = focus.FindWrapTarget(direction, sourceCell, calculated.CellBounds)
		if len(candidates) == 0 {
			return nil, fmt.Errorf("no cell in direction %s (wrap)", direction.String())
		}
	}

	// Pick closest candidate
	targetCell := focus.PickClosestCell(sourceCell, candidates, calculated.CellBounds)

	// Move window to target cell (same display/space)
	return moveWindowToCell(ctx, c, snap, cfg, rs, windowID, sourceCell, targetCell, snap.SpaceID)
}

// moveWindowToCell handles the actual window movement within the same space.
func moveWindowToCell(
	ctx context.Context,
	c *client.Client,
	snap *server.Snapshot,
	cfg *config.Config,
	rs *state.RuntimeState,
	windowID uint32,
	sourceCell string,
	targetCell string,
	spaceID string,
) (*MoveResult, error) {
	logging.Info().
		Uint32("windowId", windowID).
		Str("sourceCell", sourceCell).
		Str("targetCell", targetCell).
		Str("space", spaceID).
		Msg("moving window to cell")

	// Update state: move window from source to target cell
	mutableSpace := rs.GetSpace(spaceID)
	mutableSpace.PrependWindowToCell(windowID, targetCell)

	// Update focus to follow the window
	mutableSpace.SetFocus(targetCell, 0)

	// Calculate placements for affected cells only (not full layout re-assignment)
	layoutDef, err := cfg.GetLayout(mutableSpace.CurrentLayoutID)
	if err != nil {
		return nil, fmt.Errorf("layout not found: %w", err)
	}
	calculated := layout.CalculateLayout(layoutDef, snap.DisplayBounds, 0)

	// Build assignments for just the affected cells
	affectedAssignments := make(map[string][]uint32)
	if sourceCell != "" {
		if cellState := mutableSpace.Cells[sourceCell]; cellState != nil {
			affectedAssignments[sourceCell] = cellState.Windows
		}
	}
	if cellState := mutableSpace.Cells[targetCell]; cellState != nil {
		affectedAssignments[targetCell] = cellState.Windows
	}

	// Get cell modes from layout config AND state (matching ApplyLayout hierarchy)
	cellModes := make(map[string]types.StackMode)
	cellRatios := make(map[string][]float64)
	for cellID := range affectedAssignments {
		// 1. Check layout definition's per-cell StackMode
		for _, cell := range layoutDef.Cells {
			if cell.ID == cellID && cell.StackMode != "" {
				cellModes[cellID] = cell.StackMode
				break
			}
		}
		// 2. Check layout's CellModes map (overrides per-cell)
		if layoutDef.CellModes != nil {
			if mode, ok := layoutDef.CellModes[cellID]; ok {
				cellModes[cellID] = mode
			}
		}
		// 3. State override (highest priority)
		if cellState, ok := mutableSpace.Cells[cellID]; ok {
			if cellState.StackMode != "" {
				cellModes[cellID] = cellState.StackMode
			}
			if len(cellState.SplitRatios) > 0 {
				cellRatios[cellID] = cellState.SplitRatios
			}
		}
	}

	// Calculate and apply placements for affected cells only
	settingsPadding, _ := cfg.GetSettingsPadding()
	settingsWindowSpacing, _ := cfg.GetSettingsWindowSpacing()
	placements := layout.CalculateAllWindowPlacements(
		calculated,
		layoutDef,
		affectedAssignments,
		cellModes,
		cellRatios,
		cfg.Settings.DefaultStackMode,
		cfg.GetBaseSpacing(),
		settingsPadding,
		settingsWindowSpacing,
	)

	if err := layout.ApplyPlacements(ctx, c, placements); err != nil {
		return nil, fmt.Errorf("failed to apply placements: %w", err)
	}

	// Focus the window
	if err := focus.FocusWindow(ctx, c, windowID); err != nil {
		logging.Warn().Err(err).Uint32("windowId", windowID).Msg("failed to focus moved window")
		// Non-fatal - window was moved successfully
	}

	// Save state
	rs.MarkUpdated()
	if err := rs.Save(); err != nil {
		logging.Warn().Err(err).Msg("failed to save state")
	}

	return &MoveResult{
		WindowID:     windowID,
		SourceCell:   sourceCell,
		TargetCell:   targetCell,
		SourceSpace:  spaceID,
		TargetSpace:  spaceID,
		CrossDisplay: false,
	}, nil
}

// moveWindowCrossDisplay handles moving a window to an adjacent display.
func moveWindowCrossDisplay(
	ctx context.Context,
	c *client.Client,
	snap *server.Snapshot,
	cfg *config.Config,
	rs *state.RuntimeState,
	direction types.Direction,
	windowID uint32,
	currentCell string,
	currentCellBounds map[string]types.Rect,
	wrapAround bool,
) (*MoveResult, error) {
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
		return nil, fmt.Errorf("could not determine current display")
	}

	// Find adjacent display in direction
	adjacentDisplay := focus.FindAdjacentDisplay(currentDisplayUUID, direction, snap.AllDisplays)
	if adjacentDisplay == nil {
		if wrapAround {
			// Try to find display on opposite edge
			adjacentDisplay = focus.FindOppositeDisplay(currentDisplayUUID, direction, snap.AllDisplays)
		}
		if adjacentDisplay == nil {
			return nil, fmt.Errorf("no display in direction %s", direction.String())
		}
	}

	// Get cells on the target display
	targetCellBounds, targetSpaceID, err := focus.GetDisplayCells(*adjacentDisplay, cfg, rs)
	if err != nil {
		return nil, fmt.Errorf("failed to get cells on adjacent display: %w", err)
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

	targetPoint := focus.MatchVisualPosition(currentBounds, currentDisplayBounds, targetDisplayBounds)

	// Find closest cell to target point
	targetCell := focus.FindClosestCellToPoint(targetPoint, targetCellBounds)
	if targetCell == "" {
		return nil, fmt.Errorf("no cells on adjacent display")
	}

	targetSpaceIDStr := fmt.Sprintf("%v", targetSpaceID)

	logging.Info().
		Uint32("windowId", windowID).
		Str("sourceCell", currentCell).
		Str("targetCell", targetCell).
		Str("sourceSpace", snap.SpaceID).
		Str("targetSpace", targetSpaceIDStr).
		Str("targetDisplay", adjacentDisplay.UUID).
		Msg("moving window cross-display")

	// Move window to target space via server RPC
	_, err = c.UpdateWindow(ctx, int(windowID), map[string]interface{}{
		"spaceId": targetSpaceID,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to move window to space %v: %w", targetSpaceID, err)
	}

	// Update state on both source and target spaces
	sourceSpace := rs.GetSpace(snap.SpaceID)
	sourceSpace.RemoveWindow(windowID)

	targetSpace := rs.GetSpace(targetSpaceIDStr)
	targetSpace.PrependWindowToCell(windowID, targetCell)
	targetSpace.SetFocus(targetCell, 0)

	// Calculate placements for just the target cell (not full layout re-assignment)
	layoutDef, err := cfg.GetLayout(targetSpace.CurrentLayoutID)
	if err != nil {
		logging.Warn().Err(err).Msg("layout not found for target space")
	} else {
		targetDisplayBounds := adjacentDisplay.VisibleFrame
		if targetDisplayBounds == (types.Rect{}) {
			targetDisplayBounds = adjacentDisplay.Frame
		}
		calculated := layout.CalculateLayout(layoutDef, targetDisplayBounds, 0)

		// Build assignments for just the target cell
		affectedAssignments := make(map[string][]uint32)
		if cellState := targetSpace.Cells[targetCell]; cellState != nil {
			affectedAssignments[targetCell] = cellState.Windows
		}

		// Get cell modes from layout config AND state (matching ApplyLayout hierarchy)
		cellModes := make(map[string]types.StackMode)
		cellRatios := make(map[string][]float64)
		// 1. Check layout definition's per-cell StackMode
		for _, cell := range layoutDef.Cells {
			if cell.ID == targetCell && cell.StackMode != "" {
				cellModes[targetCell] = cell.StackMode
				break
			}
		}
		// 2. Check layout's CellModes map (overrides per-cell)
		if layoutDef.CellModes != nil {
			if mode, ok := layoutDef.CellModes[targetCell]; ok {
				cellModes[targetCell] = mode
			}
		}
		// 3. State override (highest priority)
		if cellState, ok := targetSpace.Cells[targetCell]; ok {
			if cellState.StackMode != "" {
				cellModes[targetCell] = cellState.StackMode
			}
			if len(cellState.SplitRatios) > 0 {
				cellRatios[targetCell] = cellState.SplitRatios
			}
		}

		// Calculate and apply placements for target cell only
		settingsPadding, _ := cfg.GetSettingsPadding()
		settingsWindowSpacing, _ := cfg.GetSettingsWindowSpacing()
		placements := layout.CalculateAllWindowPlacements(
			calculated,
			layoutDef,
			affectedAssignments,
			cellModes,
			cellRatios,
			cfg.Settings.DefaultStackMode,
			cfg.GetBaseSpacing(),
			settingsPadding,
			settingsWindowSpacing,
		)

		if err := layout.ApplyPlacements(ctx, c, placements); err != nil {
			logging.Warn().Err(err).Msg("failed to apply placements on target space")
		}
	}

	// Focus the window
	if err := focus.FocusWindow(ctx, c, windowID); err != nil {
		logging.Warn().Err(err).Uint32("windowId", windowID).Msg("failed to focus moved window")
	}

	// Save state
	rs.MarkUpdated()
	if err := rs.Save(); err != nil {
		logging.Warn().Err(err).Msg("failed to save state")
	}

	return &MoveResult{
		WindowID:     windowID,
		SourceCell:   currentCell,
		TargetCell:   targetCell,
		SourceSpace:  snap.SpaceID,
		TargetSpace:  targetSpaceIDStr,
		CrossDisplay: true,
	}, nil
}
