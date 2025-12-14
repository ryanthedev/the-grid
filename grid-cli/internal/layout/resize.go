package layout

import (
	"context"
	"fmt"

	"github.com/yourusername/grid-cli/internal/client"
	"github.com/yourusername/grid-cli/internal/config"
	"github.com/yourusername/grid-cli/internal/server"
	"github.com/yourusername/grid-cli/internal/state"
	"github.com/yourusername/grid-cli/internal/types"
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
	opts.Strategy = types.AssignPreserve
	opts.BaseSpacing = cfg.GetBaseSpacing()
	if settingsPadding, err := cfg.GetSettingsPadding(); err == nil {
		opts.SettingsPadding = settingsPadding
	}
	if settingsWindowSpacing, err := cfg.GetSettingsWindowSpacing(); err == nil {
		opts.SettingsWindowSpacing = settingsWindowSpacing
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
	opts.Strategy = types.AssignPreserve
	opts.BaseSpacing = cfg.GetBaseSpacing()
	if settingsPadding, err := cfg.GetSettingsPadding(); err == nil {
		opts.SettingsPadding = settingsPadding
	}
	if settingsWindowSpacing, err := cfg.GetSettingsWindowSpacing(); err == nil {
		opts.SettingsWindowSpacing = settingsWindowSpacing
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
	opts.Strategy = types.AssignPreserve
	opts.BaseSpacing = cfg.GetBaseSpacing()
	if settingsPadding, err := cfg.GetSettingsPadding(); err == nil {
		opts.SettingsPadding = settingsPadding
	}
	if settingsWindowSpacing, err := cfg.GetSettingsWindowSpacing(); err == nil {
		opts.SettingsWindowSpacing = settingsWindowSpacing
	}
	return ReapplyLayout(ctx, c, snap, cfg, rs, opts)
}

// AdjustCellBoundary grows/shrinks the focused cell in the specified direction.
// Direction specifies which edge to move: left/right for columns, up/down for rows.
// Delta is the amount to adjust (positive = grow in that direction).
func AdjustCellBoundary(
	ctx context.Context,
	c *client.Client,
	snap *server.Snapshot,
	cfg *config.Config,
	rs *state.RuntimeState,
	direction string,
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

	// Get layout to find cell and track info
	layout, err := cfg.GetLayout(spaceState.CurrentLayoutID)
	if err != nil {
		return fmt.Errorf("layout not found: %w", err)
	}

	// Find the cell definition
	var cell *types.Cell
	for i := range layout.Cells {
		if layout.Cells[i].ID == cellID {
			cell = &layout.Cells[i]
			break
		}
	}
	if cell == nil {
		return fmt.Errorf("cell %s not found in layout", cellID)
	}

	// Determine if we're adjusting columns or rows based on direction
	isColumn := direction == "left" || direction == "right"
	isGrowing := direction == "right" || direction == "down"

	var tracks []types.TrackSize
	var currentRatios []float64
	var trackStart, trackEnd int

	if isColumn {
		tracks = layout.Columns
		currentRatios = spaceState.ColumnRatios
		trackStart = cell.ColumnStart - 1 // Convert to 0-indexed
		trackEnd = cell.ColumnEnd - 2     // End line is AFTER last column
	} else {
		tracks = layout.Rows
		currentRatios = spaceState.RowRatios
		trackStart = cell.RowStart - 1
		trackEnd = cell.RowEnd - 2 // End line is AFTER last row
	}

	// Count flexible tracks and initialize ratios if needed
	flexCount := countFlexibleTracks(tracks)
	if flexCount < 2 {
		return fmt.Errorf("need at least 2 flexible tracks to resize cells")
	}

	if len(currentRatios) != flexCount {
		currentRatios = initializeTrackRatios(tracks)
	}

	// Find which boundary to adjust
	// For "left" or "up", we adjust the boundary BEFORE the cell
	// For "right" or "down", we adjust the boundary AFTER the cell
	boundaryIdx := -1
	if isGrowing {
		// Growing right/down: adjust boundary after cell
		boundaryIdx = getFlexBoundaryIndex(tracks, trackEnd)
	} else {
		// Growing left/up: adjust boundary before cell
		boundaryIdx = getFlexBoundaryIndex(tracks, trackStart) - 1
	}

	if boundaryIdx < 0 || boundaryIdx >= flexCount-1 {
		return fmt.Errorf("cannot resize in direction %s: at edge of layout", direction)
	}

	// Adjust the ratios
	// Growing means: increase the cell's ratio, decrease neighbor's
	// For left/up: we decrease boundaryIdx, increase boundaryIdx+1
	// For right/down: we increase boundaryIdx, decrease boundaryIdx+1
	adjustDelta := delta
	if !isGrowing {
		// For left/up, we're adjusting from the other side
		adjustDelta = -delta
	}

	// Use config min/max ratio if set, otherwise use defaults
	minRatio := MinimumRatio
	maxRatio := 1.0 - MinimumRatio // Default max
	if cfg.Settings.Resize.MinRatio > 0 {
		minRatio = cfg.Settings.Resize.MinRatio
	}
	if cfg.Settings.Resize.MaxRatio > 0 {
		maxRatio = cfg.Settings.Resize.MaxRatio
	}

	newRatios, err := AdjustSplitRatioWithMax(currentRatios, boundaryIdx, adjustDelta, minRatio, maxRatio)
	if err != nil {
		return err
	}

	// Update state
	mutableSpace := rs.GetSpace(snap.SpaceID)
	if isColumn {
		mutableSpace.ColumnRatios = newRatios
	} else {
		mutableSpace.RowRatios = newRatios
	}
	rs.MarkUpdated()
	if err := rs.Save(); err != nil {
		return fmt.Errorf("failed to save state: %w", err)
	}

	// Reapply layout
	opts := DefaultApplyOptions()
	opts.Strategy = types.AssignPreserve
	opts.BaseSpacing = cfg.GetBaseSpacing()
	if settingsPadding, err := cfg.GetSettingsPadding(); err == nil {
		opts.SettingsPadding = settingsPadding
	}
	if settingsWindowSpacing, err := cfg.GetSettingsWindowSpacing(); err == nil {
		opts.SettingsWindowSpacing = settingsWindowSpacing
	}
	return ReapplyLayout(ctx, c, snap, cfg, rs, opts)
}

// ResetCellRatios resets track ratios to layout defaults.
func ResetCellRatios(
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

	// Clear track ratios
	mutableSpace := rs.GetSpace(snap.SpaceID)
	mutableSpace.ColumnRatios = nil
	mutableSpace.RowRatios = nil
	rs.MarkUpdated()
	if err := rs.Save(); err != nil {
		return fmt.Errorf("failed to save state: %w", err)
	}

	opts := DefaultApplyOptions()
	opts.Strategy = types.AssignPreserve
	opts.BaseSpacing = cfg.GetBaseSpacing()
	if settingsPadding, err := cfg.GetSettingsPadding(); err == nil {
		opts.SettingsPadding = settingsPadding
	}
	if settingsWindowSpacing, err := cfg.GetSettingsWindowSpacing(); err == nil {
		opts.SettingsWindowSpacing = settingsWindowSpacing
	}
	return ReapplyLayout(ctx, c, snap, cfg, rs, opts)
}

// countFlexibleTracks returns the number of fr or minmax tracks.
func countFlexibleTracks(tracks []types.TrackSize) int {
	count := 0
	for _, t := range tracks {
		if t.Type == types.TrackFr || t.Type == types.TrackMinMax {
			count++
		}
	}
	return count
}

// initializeTrackRatios creates equal ratios for flexible tracks.
func initializeTrackRatios(tracks []types.TrackSize) []float64 {
	flexCount := countFlexibleTracks(tracks)
	if flexCount == 0 {
		return nil
	}

	// Calculate ratios based on original fr values
	var totalFr float64
	for _, t := range tracks {
		if t.Type == types.TrackFr {
			totalFr += t.Value
		} else if t.Type == types.TrackMinMax {
			totalFr += t.Max
		}
	}

	if totalFr == 0 {
		// Equal distribution if no fr values
		ratio := 1.0 / float64(flexCount)
		ratios := make([]float64, flexCount)
		for i := range ratios {
			ratios[i] = ratio
		}
		return ratios
	}

	// Distribute based on fr values
	ratios := make([]float64, 0, flexCount)
	for _, t := range tracks {
		if t.Type == types.TrackFr {
			ratios = append(ratios, t.Value/totalFr)
		} else if t.Type == types.TrackMinMax {
			ratios = append(ratios, t.Max/totalFr)
		}
	}

	return NormalizeRatios(ratios)
}

// getFlexBoundaryIndex returns the index in the flex ratios array
// for the track at the given overall track index.
// Returns -1 if the track is not flexible.
func getFlexBoundaryIndex(tracks []types.TrackSize, trackIdx int) int {
	flexIdx := 0
	for i, t := range tracks {
		if i == trackIdx {
			if t.Type == types.TrackFr || t.Type == types.TrackMinMax {
				return flexIdx
			}
			return -1
		}
		if t.Type == types.TrackFr || t.Type == types.TrackMinMax {
			flexIdx++
		}
	}
	return -1
}
