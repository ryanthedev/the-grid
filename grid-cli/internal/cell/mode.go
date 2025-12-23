package cell

import (
	"context"
	"fmt"

	"github.com/ryanthedev/grid-cli/internal/client"
	"github.com/ryanthedev/grid-cli/internal/config"
	"github.com/ryanthedev/grid-cli/internal/layout"
	"github.com/ryanthedev/grid-cli/internal/server"
	"github.com/ryanthedev/grid-cli/internal/state"
	"github.com/ryanthedev/grid-cli/internal/types"
)

// ParseStackMode validates and converts a string to StackMode.
func ParseStackMode(s string) (types.StackMode, error) {
	mode := types.StackMode(s)
	switch mode {
	case types.StackVertical, types.StackHorizontal, types.StackTabs:
		return mode, nil
	default:
		return "", fmt.Errorf("invalid mode %q - use: vertical, horizontal, tabs", s)
	}
}

// NextMode cycles through stack modes: vertical → horizontal → tabs → vertical.
func NextMode(current types.StackMode) types.StackMode {
	switch current {
	case types.StackVertical:
		return types.StackHorizontal
	case types.StackHorizontal:
		return types.StackTabs
	case types.StackTabs:
		return types.StackVertical
	default:
		return types.StackVertical
	}
}

// GetEffectiveMode resolves the current effective stack mode for a cell.
// Priority: runtime override > cell config > layout cellModes > settings default.
func GetEffectiveMode(rs *state.RuntimeState, cfg *config.Config, spaceID, cellID, layoutID string) types.StackMode {
	// 1. Check runtime override
	if mode := rs.GetCellStackMode(spaceID, cellID); mode != "" {
		return mode
	}

	// 2-3. Check layout config (cell-level StackMode and cellModes map)
	if layoutDef, err := cfg.GetLayout(layoutID); err == nil {
		// Check cell-level StackMode
		for _, cell := range layoutDef.Cells {
			if cell.ID == cellID && cell.StackMode != "" {
				return cell.StackMode
			}
		}
		// Check cellModes map
		if mode, ok := layoutDef.CellModes[cellID]; ok && mode != "" {
			return mode
		}
	}

	// 4. Fall back to settings default
	if cfg.Settings.DefaultStackMode != "" {
		return cfg.Settings.DefaultStackMode
	}

	return types.StackVertical
}

// SetMode sets or cycles the stack mode for the focused cell.
// If targetMode is empty, it cycles through modes.
func SetMode(
	ctx context.Context,
	c *client.Client,
	snap *server.Snapshot,
	cfg *config.Config,
	rs *state.RuntimeState,
	targetMode types.StackMode,
) (cellID string, newMode types.StackMode, err error) {
	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil || spaceState.CurrentLayoutID == "" {
		return "", "", fmt.Errorf("no layout applied")
	}

	cellID = spaceState.FocusedCell
	if cellID == "" {
		return "", "", fmt.Errorf("no focused cell")
	}

	// Determine new mode
	if targetMode != "" {
		newMode = targetMode
	} else {
		// Cycle to next mode
		currentMode := GetEffectiveMode(rs, cfg, snap.SpaceID, cellID, spaceState.CurrentLayoutID)
		newMode = NextMode(currentMode)
	}

	// Update state
	rs.SetCellStackMode(snap.SpaceID, cellID, newMode)

	// Reapply layout
	opts := layout.DefaultApplyOptions()
	opts.Strategy = types.AssignPreserve
	opts.BaseSpacing = cfg.GetBaseSpacing()
	if settingsPadding, err := cfg.GetSettingsPadding(); err == nil {
		opts.SettingsPadding = settingsPadding
	}
	if settingsWindowSpacing, err := cfg.GetSettingsWindowSpacing(); err == nil {
		opts.SettingsWindowSpacing = settingsWindowSpacing
	}
	if err := layout.ReapplyLayout(ctx, c, snap, cfg, rs, opts); err != nil {
		return "", "", fmt.Errorf("failed to reapply layout: %w", err)
	}

	return cellID, newMode, nil
}
