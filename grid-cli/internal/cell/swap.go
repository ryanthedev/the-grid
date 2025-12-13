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

// SwapWindow swaps the focused window with an adjacent window in the same cell.
// Direction is interpreted based on the cell's stack mode:
// - vertical: up/down swap with adjacent windows
// - horizontal: left/right swap with adjacent windows
// - tabs: left/right cycle through window order
// All directions wrap around at edges.
func SwapWindow(
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

	// Get focused cell and validate it has windows
	cellID := spaceState.FocusedCell
	if cellID == "" {
		return fmt.Errorf("no focused cell")
	}

	cell := spaceState.Cells[cellID]
	if cell == nil || len(cell.Windows) < 2 {
		return fmt.Errorf("need at least 2 windows in cell to swap")
	}

	// Determine current window index
	currentIdx := spaceState.FocusedWindow
	if currentIdx < 0 || currentIdx >= len(cell.Windows) {
		currentIdx = 0
	}

	// Get effective stack mode for this cell
	stackMode := getEffectiveStackMode(spaceState, cellID, cfg)

	// Calculate swap target index
	targetIdx := calculateSwapTarget(currentIdx, len(cell.Windows), direction, stackMode)

	// Perform the swap in state
	mutableSpace := rs.GetSpace(snap.SpaceID)
	mutableCell := mutableSpace.GetCell(cellID)

	// Swap windows in the array
	mutableCell.Windows[currentIdx], mutableCell.Windows[targetIdx] =
		mutableCell.Windows[targetIdx], mutableCell.Windows[currentIdx]

	// Swap corresponding split ratios if they exist and match window count
	if len(mutableCell.SplitRatios) == len(mutableCell.Windows) {
		mutableCell.SplitRatios[currentIdx], mutableCell.SplitRatios[targetIdx] =
			mutableCell.SplitRatios[targetIdx], mutableCell.SplitRatios[currentIdx]
	}

	// Update focus to follow the window to its new position
	mutableSpace.SetFocus(cellID, targetIdx)

	// Save state
	rs.MarkUpdated()
	if err := rs.Save(); err != nil {
		return fmt.Errorf("failed to save state: %w", err)
	}

	// Reapply layout to update window positions
	opts := layout.DefaultApplyOptions()
	opts.Strategy = types.AssignPreserve // Honor existing state window order
	opts.BaseSpacing = cfg.GetBaseSpacing()
	if settingsPadding, err := cfg.GetSettingsPadding(); err == nil {
		opts.SettingsPadding = settingsPadding
	}
	if settingsWindowSpacing, err := cfg.GetSettingsWindowSpacing(); err == nil {
		opts.SettingsWindowSpacing = settingsWindowSpacing
	}
	return layout.ReapplyLayout(ctx, c, snap, cfg, rs, opts)
}

// calculateSwapTarget determines the target index for swapping based on direction and mode.
// Always wraps around at edges.
func calculateSwapTarget(currentIdx, windowCount int, direction types.Direction, stackMode types.StackMode) int {
	var delta int

	switch stackMode {
	case types.StackVertical:
		switch direction {
		case types.DirUp, types.DirLeft:
			delta = -1 // Previous (towards top)
		case types.DirDown, types.DirRight:
			delta = 1 // Next (towards bottom)
		}

	case types.StackHorizontal:
		switch direction {
		case types.DirLeft, types.DirUp:
			delta = -1 // Previous (towards left)
		case types.DirRight, types.DirDown:
			delta = 1 // Next (towards right)
		}

	case types.StackTabs:
		switch direction {
		case types.DirLeft, types.DirUp:
			delta = -1
		case types.DirRight, types.DirDown:
			delta = 1
		}

	default:
		// Default to vertical behavior
		switch direction {
		case types.DirUp, types.DirLeft:
			delta = -1
		case types.DirDown, types.DirRight:
			delta = 1
		}
	}

	// Calculate target with wrap-around using modulo
	return (currentIdx + delta + windowCount) % windowCount
}

// getEffectiveStackMode determines the stack mode for a cell.
// Priority: cell state override > layout cell config > layout CellModes > settings default
func getEffectiveStackMode(spaceState *state.SpaceState, cellID string, cfg *config.Config) types.StackMode {
	// 1. Check cell state override
	if cell, ok := spaceState.Cells[cellID]; ok && cell.StackMode != "" {
		return cell.StackMode
	}

	// 2. Check layout definition
	if spaceState.CurrentLayoutID != "" {
		if layoutDef, err := cfg.GetLayout(spaceState.CurrentLayoutID); err == nil {
			// Check per-cell StackMode in layout definition
			for _, c := range layoutDef.Cells {
				if c.ID == cellID && c.StackMode != "" {
					return c.StackMode
				}
			}
			// Check CellModes map
			if layoutDef.CellModes != nil {
				if mode, ok := layoutDef.CellModes[cellID]; ok {
					return mode
				}
			}
		}
	}

	// 3. Fall back to settings default
	return cfg.Settings.DefaultStackMode
}
