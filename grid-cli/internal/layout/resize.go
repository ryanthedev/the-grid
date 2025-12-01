package layout

import (
	"context"
	"fmt"

	"github.com/yourusername/grid-cli/internal/client"
	"github.com/yourusername/grid-cli/internal/config"
	"github.com/yourusername/grid-cli/internal/server"
	"github.com/yourusername/grid-cli/internal/state"
)

// AdjustFocusedSplit grows/shrinks the focused window's split ratio.
func AdjustFocusedSplit(
	ctx context.Context,
	c *client.Client,
	snap *server.Snapshot,
	cfg *config.Config,
	rs *state.RuntimeState,
	delta float64,
) error {
	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil {
		return fmt.Errorf("no layout applied")
	}

	cellID := spaceState.FocusedCell
	if cellID == "" {
		return fmt.Errorf("no focused cell")
	}

	cell := spaceState.Cells[cellID]
	if cell == nil || len(cell.Windows) < 2 {
		return fmt.Errorf("need at least 2 windows to resize")
	}

	// Get focused window index in cell
	idx := spaceState.FocusedWindow
	if idx < 0 || idx >= len(cell.Windows) {
		idx = 0
	}

	// Ensure we have ratios
	ratios := cell.SplitRatios
	if len(ratios) != len(cell.Windows) {
		ratios = InitializeSplitRatios(len(cell.Windows))
	}

	// Boundary to adjust is between idx and idx+1 (or idx-1 and idx)
	boundaryIdx := idx
	if boundaryIdx >= len(ratios)-1 {
		boundaryIdx = len(ratios) - 2
	}

	newRatios, err := AdjustSplitRatio(ratios, boundaryIdx, delta, MinimumRatio)
	if err != nil {
		return err
	}

	// Update state
	mutableCell := rs.GetSpace(snap.SpaceID).GetCell(cellID)
	mutableCell.SplitRatios = newRatios
	rs.MarkUpdated()
	if err := rs.Save(); err != nil {
		return fmt.Errorf("failed to save state: %w", err)
	}

	// Reapply layout to update window positions
	opts := DefaultApplyOptions()
	opts.BaseSpacing = cfg.GetBaseSpacing()
	if settingsPadding, err := cfg.GetSettingsPadding(); err == nil {
		opts.SettingsPadding = settingsPadding
	}
	return ReapplyLayout(ctx, c, snap, cfg, rs, opts)
}

// ResetFocusedSplits resets the focused cell's splits to equal.
func ResetFocusedSplits(
	ctx context.Context,
	c *client.Client,
	snap *server.Snapshot,
	cfg *config.Config,
	rs *state.RuntimeState,
) error {
	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil {
		return fmt.Errorf("no layout applied")
	}

	cellID := spaceState.FocusedCell
	if cellID == "" {
		return fmt.Errorf("no focused cell")
	}

	cell := spaceState.Cells[cellID]
	if cell == nil {
		return fmt.Errorf("no focused cell")
	}

	// Reset to equal
	mutableCell := rs.GetSpace(snap.SpaceID).GetCell(cellID)
	mutableCell.SplitRatios = InitializeSplitRatios(len(cell.Windows))
	rs.MarkUpdated()
	if err := rs.Save(); err != nil {
		return fmt.Errorf("failed to save state: %w", err)
	}

	opts := DefaultApplyOptions()
	opts.BaseSpacing = cfg.GetBaseSpacing()
	if settingsPadding, err := cfg.GetSettingsPadding(); err == nil {
		opts.SettingsPadding = settingsPadding
	}
	return ReapplyLayout(ctx, c, snap, cfg, rs, opts)
}

// ResetAllSplits resets all cells' splits to equal.
func ResetAllSplits(
	ctx context.Context,
	c *client.Client,
	snap *server.Snapshot,
	cfg *config.Config,
	rs *state.RuntimeState,
) error {
	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil {
		return fmt.Errorf("no layout applied")
	}

	mutableSpace := rs.GetSpace(snap.SpaceID)
	for cellID, cell := range spaceState.Cells {
		mutableCell := mutableSpace.GetCell(cellID)
		mutableCell.SplitRatios = InitializeSplitRatios(len(cell.Windows))
	}
	rs.MarkUpdated()
	if err := rs.Save(); err != nil {
		return fmt.Errorf("failed to save state: %w", err)
	}

	opts := DefaultApplyOptions()
	opts.BaseSpacing = cfg.GetBaseSpacing()
	if settingsPadding, err := cfg.GetSettingsPadding(); err == nil {
		opts.SettingsPadding = settingsPadding
	}
	return ReapplyLayout(ctx, c, snap, cfg, rs, opts)
}
