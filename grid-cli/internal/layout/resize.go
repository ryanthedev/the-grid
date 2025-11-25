package layout

import (
	"context"
	"fmt"

	"github.com/yourusername/grid-cli/internal/client"
	"github.com/yourusername/grid-cli/internal/config"
	"github.com/yourusername/grid-cli/internal/state"
	"github.com/yourusername/grid-cli/internal/types"
)

// SplitInfo contains information about splits in a cell
type SplitInfo struct {
	CellID       string
	WindowCount  int
	Ratios       []float64
	FocusedIndex int
}

// AdjustSplit adjusts the split ratio for the focused window.
// delta is the change in ratio (positive = grow, negative = shrink)
func AdjustSplit(
	ctx context.Context,
	c *client.Client,
	cfg *config.Config,
	runtimeState *state.RuntimeState,
	delta float64,
) error {
	// Refresh state to handle window changes
	RefreshSpaceState(ctx, c, cfg, runtimeState, "")

	// Get current space
	serverState, err := c.Dump(ctx)
	if err != nil {
		return fmt.Errorf("failed to get server state: %w", err)
	}

	spaceID := getCurrentSpaceID(serverState)
	spaceState := runtimeState.GetSpace(spaceID)

	if spaceState.CurrentLayoutID == "" {
		return fmt.Errorf("no layout applied")
	}

	if spaceState.FocusedCell == "" {
		return fmt.Errorf("no cell is focused")
	}

	cellState, ok := spaceState.Cells[spaceState.FocusedCell]
	if !ok || len(cellState.Windows) < 2 {
		return fmt.Errorf("need at least 2 windows in cell to adjust splits")
	}

	// Ensure split ratios are initialized
	if len(cellState.SplitRatios) != len(cellState.Windows) {
		cellState.SplitRatios = InitializeSplitRatios(len(cellState.Windows))
	}

	// Determine which boundary to adjust based on focused window
	// Positive delta grows the focused window, shrinks the next one
	boundaryIndex := spaceState.FocusedWindow
	adjustedDelta := delta

	if boundaryIndex >= len(cellState.Windows)-1 {
		// Last window - adjust boundary before it
		boundaryIndex = len(cellState.Windows) - 2
		adjustedDelta = -delta // Invert because we're adjusting from the other side
	}

	// Adjust ratios
	newRatios, err := AdjustSplitRatio(cellState.SplitRatios, boundaryIndex, adjustedDelta, MinimumRatio)
	if err != nil {
		return fmt.Errorf("failed to adjust split: %w", err)
	}

	cellState.SplitRatios = newRatios

	// Recalculate and apply window bounds
	if err := reapplyCell(ctx, c, cfg, runtimeState, spaceID, spaceState.FocusedCell); err != nil {
		return fmt.Errorf("failed to apply changes: %w", err)
	}

	// Save state
	runtimeState.MarkUpdated()
	return runtimeState.Save()
}

// ResetSplits resets all splits in the focused cell to equal
func ResetSplits(
	ctx context.Context,
	c *client.Client,
	cfg *config.Config,
	runtimeState *state.RuntimeState,
) error {
	// Refresh state to handle window changes
	RefreshSpaceState(ctx, c, cfg, runtimeState, "")

	// Get current space
	serverState, err := c.Dump(ctx)
	if err != nil {
		return fmt.Errorf("failed to get server state: %w", err)
	}

	spaceID := getCurrentSpaceID(serverState)
	spaceState := runtimeState.GetSpace(spaceID)

	if spaceState.FocusedCell == "" {
		return fmt.Errorf("no cell is focused")
	}

	cellState, ok := spaceState.Cells[spaceState.FocusedCell]
	if !ok {
		return fmt.Errorf("focused cell not found in state")
	}

	// Reset to equal ratios
	cellState.SplitRatios = InitializeSplitRatios(len(cellState.Windows))

	// Recalculate and apply window bounds
	if err := reapplyCell(ctx, c, cfg, runtimeState, spaceID, spaceState.FocusedCell); err != nil {
		return fmt.Errorf("failed to apply changes: %w", err)
	}

	// Save state
	runtimeState.MarkUpdated()
	return runtimeState.Save()
}

// ResetAllSplits resets splits in all cells of the current layout
func ResetAllSplits(
	ctx context.Context,
	c *client.Client,
	cfg *config.Config,
	runtimeState *state.RuntimeState,
) error {
	serverState, err := c.Dump(ctx)
	if err != nil {
		return fmt.Errorf("failed to get server state: %w", err)
	}

	spaceID := getCurrentSpaceID(serverState)
	spaceState := runtimeState.GetSpace(spaceID)

	if spaceState.CurrentLayoutID == "" {
		return fmt.Errorf("no layout applied")
	}

	// Reset all cells
	for _, cellState := range spaceState.Cells {
		cellState.SplitRatios = InitializeSplitRatios(len(cellState.Windows))
	}

	// Reapply entire layout
	opts := DefaultApplyOptions()
	opts.SpaceID = spaceID
	opts.Strategy = types.AssignPreserve

	if err := ApplyLayout(ctx, c, cfg, runtimeState, spaceState.CurrentLayoutID, opts); err != nil {
		return fmt.Errorf("failed to reapply layout: %w", err)
	}

	return nil
}

// GetSplitInfo returns information about splits in the focused cell
func GetSplitInfo(runtimeState *state.RuntimeState, spaceID string) (*SplitInfo, error) {
	spaceState := runtimeState.GetSpaceReadOnly(spaceID)
	if spaceState == nil {
		return nil, fmt.Errorf("no state for space %s", spaceID)
	}

	if spaceState.FocusedCell == "" {
		return nil, fmt.Errorf("no cell is focused")
	}

	cellState, ok := spaceState.Cells[spaceState.FocusedCell]
	if !ok {
		return nil, fmt.Errorf("focused cell not found")
	}

	return &SplitInfo{
		CellID:       spaceState.FocusedCell,
		WindowCount:  len(cellState.Windows),
		Ratios:       cellState.SplitRatios,
		FocusedIndex: spaceState.FocusedWindow,
	}, nil
}

// reapplyCell recalculates and applies bounds for a single cell
func reapplyCell(
	ctx context.Context,
	c *client.Client,
	cfg *config.Config,
	runtimeState *state.RuntimeState,
	spaceID string,
	cellID string,
) error {
	spaceState := runtimeState.GetSpace(spaceID)

	// Get layout
	l, err := cfg.GetLayout(spaceState.CurrentLayoutID)
	if err != nil {
		return fmt.Errorf("layout not found: %w", err)
	}

	// Get display bounds
	serverState, err := c.Dump(ctx)
	if err != nil {
		return fmt.Errorf("failed to get server state: %w", err)
	}

	displayBounds, err := getDisplayBoundsForSpace(serverState, spaceID)
	if err != nil {
		return fmt.Errorf("failed to get display bounds: %w", err)
	}

	// Calculate layout
	gap := float64(cfg.Settings.CellPadding)
	calculatedLayout := CalculateLayout(l, displayBounds, gap)

	// Get cell bounds
	cellBounds, ok := calculatedLayout.CellBounds[cellID]
	if !ok {
		return fmt.Errorf("cell not found: %s", cellID)
	}

	// Get cell state
	cellState := spaceState.Cells[cellID]
	if cellState == nil || len(cellState.Windows) == 0 {
		return nil // Nothing to apply
	}

	// Determine stack mode
	mode := cfg.Settings.DefaultStackMode
	if l.CellModes != nil {
		if m, ok := l.CellModes[cellID]; ok && m != "" {
			mode = m
		}
	}
	if cellState.StackMode != "" {
		mode = cellState.StackMode
	}

	// Calculate window bounds
	padding := gap / 2 // Use half gap between windows
	windowBounds := CalculateWindowBounds(cellBounds, len(cellState.Windows), mode, cellState.SplitRatios, padding)

	// Apply bounds to server
	for i, windowID := range cellState.Windows {
		if i >= len(windowBounds) {
			break
		}

		_, err := c.UpdateWindow(ctx, int(windowID), map[string]interface{}{
			"x":      windowBounds[i].X,
			"y":      windowBounds[i].Y,
			"width":  windowBounds[i].Width,
			"height": windowBounds[i].Height,
		})
		if err != nil {
			// Log warning but continue with other windows
			fmt.Printf("Warning: failed to update window %d: %v\n", windowID, err)
		}
	}

	return nil
}
