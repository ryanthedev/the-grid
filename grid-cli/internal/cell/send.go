package cell

import (
	"context"
	"fmt"

	"github.com/yourusername/grid-cli/internal/client"
	"github.com/yourusername/grid-cli/internal/config"
	"github.com/yourusername/grid-cli/internal/layout"
	"github.com/yourusername/grid-cli/internal/server"
	"github.com/yourusername/grid-cli/internal/state"
	"github.com/yourusername/grid-cli/internal/types"
)

// SendWindow moves the focused window to an adjacent cell.
func SendWindow(
	ctx context.Context,
	c *client.Client,
	snap *server.Snapshot,
	cfg *config.Config,
	rs *state.RuntimeState,
	direction types.Direction,
) error {
	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil || spaceState.CurrentLayoutID == "" {
		return fmt.Errorf("no layout applied")
	}

	// Get focused window
	windowID := spaceState.GetFocusedWindow()
	if windowID == 0 {
		return fmt.Errorf("no focused window")
	}

	currentCell := spaceState.FocusedCell
	if currentCell == "" {
		return fmt.Errorf("no focused cell")
	}

	// Calculate layout bounds
	layoutDef, err := cfg.GetLayout(spaceState.CurrentLayoutID)
	if err != nil {
		return fmt.Errorf("layout not found: %w", err)
	}
	calculated := layout.CalculateLayout(layoutDef, snap.DisplayBounds, float64(cfg.Settings.CellPadding))

	// Find target cell
	adjacentMap := layout.GetAdjacentCells(currentCell, calculated.CellBounds)
	candidates := adjacentMap[direction]
	if len(candidates) == 0 {
		return fmt.Errorf("no cell in direction %s", direction.String())
	}

	// Pick closest candidate
	targetCell := pickClosestCell(currentCell, candidates, calculated.CellBounds)

	// Move window in state
	mutableSpace := rs.GetSpace(snap.SpaceID)
	mutableSpace.RemoveWindow(windowID)
	mutableSpace.AssignWindow(windowID, targetCell)

	// Update focus to follow window
	targetCellState := mutableSpace.Cells[targetCell]
	mutableSpace.SetFocus(targetCell, len(targetCellState.Windows)-1)
	rs.MarkUpdated()
	if err := rs.Save(); err != nil {
		return fmt.Errorf("failed to save state: %w", err)
	}

	// Reapply layout
	opts := layout.DefaultApplyOptions()
	opts.Gap = float64(cfg.Settings.CellPadding)
	return layout.ReapplyLayout(ctx, c, snap, cfg, rs, opts)
}

// pickClosestCell picks the cell closest to the current cell's center.
func pickClosestCell(currentCell string, candidates []string, cellBounds map[string]types.Rect) string {
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
	closestDist := float64(1e18)

	for _, cellID := range candidates {
		bounds := cellBounds[cellID]
		center := bounds.Center()
		dx := center.X - currentCenter.X
		dy := center.Y - currentCenter.Y
		dist := dx*dx + dy*dy // No need for sqrt, just comparing
		if dist < closestDist {
			closestDist = dist
			closest = cellID
		}
	}

	return closest
}
