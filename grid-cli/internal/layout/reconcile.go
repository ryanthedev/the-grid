package layout

import (
	"context"
	"fmt"

	"github.com/yourusername/grid-cli/internal/client"
	"github.com/yourusername/grid-cli/internal/config"
	"github.com/yourusername/grid-cli/internal/logging"
	"github.com/yourusername/grid-cli/internal/state"
	"github.com/yourusername/grid-cli/internal/types"
)

// RefreshSpaceState ensures state matches actual windows before operations.
// It reconciles stale windows directly and reapplies layout only if new windows exist.
// Returns true if state was modified.
func RefreshSpaceState(
	ctx context.Context,
	c *client.Client,
	cfg *config.Config,
	runtimeState *state.RuntimeState,
	spaceID string,
) (bool, error) {
	// 1. Determine space ID if not provided
	if spaceID == "" {
		serverState, err := c.Dump(ctx)
		if err != nil {
			return false, fmt.Errorf("failed to get server state: %w", err)
		}
		spaceID = getCurrentSpaceID(serverState)
	}

	// 2. Always reconcile first - directly removes stale windows from state
	if err := ReconcileState(ctx, c, runtimeState, spaceID); err != nil {
		return false, fmt.Errorf("reconcile failed: %w", err)
	}

	// 2.5 Log context after reconcile
	if serverState, err := c.Dump(ctx); err == nil {
		logContextChange(runtimeState, serverState)
	}

	// 3. Check for new windows that need assignment
	newWins, err := CheckForNewWindows(ctx, c, runtimeState, spaceID)
	if err != nil {
		return false, fmt.Errorf("check new windows failed: %w", err)
	}

	// If no new windows, state is already clean
	if len(newWins) == 0 {
		return false, nil
	}

	// 4. Reapply layout to assign new windows
	spaceState := runtimeState.GetSpaceReadOnly(spaceID)
	if spaceState == nil || spaceState.CurrentLayoutID == "" {
		return false, nil // No layout to assign new windows to
	}

	opts := DefaultApplyOptions()
	opts.SpaceID = spaceID
	opts.Strategy = types.AssignPreserve

	err = ApplyLayout(ctx, c, cfg, runtimeState, spaceState.CurrentLayoutID, opts)
	return err == nil, err
}

// ReconcileState synchronizes runtime state with actual windows from the server.
// This removes windows that no longer exist from the state.
// Call this when windows might have changed externally (e.g., app quit, window closed).
func ReconcileState(
	ctx context.Context,
	c *client.Client,
	runtimeState *state.RuntimeState,
	spaceID string,
) error {
	// Get current windows from server
	serverState, err := c.Dump(ctx)
	if err != nil {
		return err
	}

	actualWindows := filterWindowsForSpace(serverState, spaceID)
	actualWindowIDs := make(map[uint32]bool)
	for _, w := range actualWindows {
		if !shouldExclude(w) {
			actualWindowIDs[w.ID] = true
		}
	}

	// Get space state
	spaceState := runtimeState.GetSpaceReadOnly(spaceID)
	if spaceState == nil {
		return nil // No state to reconcile
	}

	// Remove windows that no longer exist
	changed := false
	for cellID, cellState := range spaceState.Cells {
		var validWindows []uint32
		for _, wid := range cellState.Windows {
			if actualWindowIDs[wid] {
				validWindows = append(validWindows, wid)
			}
		}

		if len(validWindows) != len(cellState.Windows) {
			// Windows were removed, update cell
			cell := runtimeState.GetSpace(spaceID).GetCell(cellID)
			cell.Windows = validWindows
			cell.SplitRatios = reconcileEqualRatios(len(validWindows))
			changed = true
		}
	}

	if changed {
		runtimeState.MarkUpdated()
		return runtimeState.Save()
	}

	return nil
}

// CheckForNewWindows identifies windows that are not yet assigned to any cell.
// This is useful for detecting new windows that need to be tiled.
func CheckForNewWindows(
	ctx context.Context,
	c *client.Client,
	runtimeState *state.RuntimeState,
	spaceID string,
) ([]uint32, error) {
	serverState, err := c.Dump(ctx)
	if err != nil {
		return nil, err
	}

	actualWindows := filterWindowsForSpace(serverState, spaceID)

	// Build set of assigned windows
	assignedWindows := make(map[uint32]bool)
	if spaceState := runtimeState.GetSpaceReadOnly(spaceID); spaceState != nil {
		for _, cellState := range spaceState.Cells {
			for _, wid := range cellState.Windows {
				assignedWindows[wid] = true
			}
		}
	}

	// Find unassigned windows that are tileable
	var newWindows []uint32
	for _, w := range actualWindows {
		if !assignedWindows[w.ID] && !shouldExclude(w) {
			newWindows = append(newWindows, w.ID)
		}
	}

	return newWindows, nil
}

// GetStaleWindows returns window IDs in state that no longer exist on the server.
func GetStaleWindows(
	ctx context.Context,
	c *client.Client,
	runtimeState *state.RuntimeState,
	spaceID string,
) ([]uint32, error) {
	serverState, err := c.Dump(ctx)
	if err != nil {
		return nil, err
	}

	actualWindows := filterWindowsForSpace(serverState, spaceID)
	actualWindowIDs := make(map[uint32]bool)
	for _, w := range actualWindows {
		actualWindowIDs[w.ID] = true
	}

	spaceState := runtimeState.GetSpaceReadOnly(spaceID)
	if spaceState == nil {
		return nil, nil
	}

	var staleWindows []uint32
	for _, cellState := range spaceState.Cells {
		for _, wid := range cellState.Windows {
			if !actualWindowIDs[wid] {
				staleWindows = append(staleWindows, wid)
			}
		}
	}

	return staleWindows, nil
}

// reconcileEqualRatios returns equal split ratios for n windows.
// This is a local copy to avoid circular dependency issues.
func reconcileEqualRatios(n int) []float64 {
	if n <= 0 {
		return nil
	}
	ratio := 1.0 / float64(n)
	ratios := make([]float64, n)
	for i := range ratios {
		ratios[i] = ratio
	}
	return ratios
}

// extractContext extracts context info from server state
func extractContext(serverState map[string]interface{}) (displayUUID, spaceID string, windowID uint32, appName, windowTitle string) {
	// Get metadata
	if metadata, ok := serverState["metadata"].(map[string]interface{}); ok {
		if uuid, ok := metadata["activeDisplayUUID"].(string); ok {
			displayUUID = uuid
		}
		if wid, ok := metadata["focusedWindowID"].(float64); ok {
			windowID = uint32(wid)
		}
	}

	// Find active space
	if spaces, ok := serverState["spaces"].(map[string]interface{}); ok {
		for sid, s := range spaces {
			if space, ok := s.(map[string]interface{}); ok {
				if isActive, ok := space["isActive"].(bool); ok && isActive {
					spaceID = sid
					break
				}
			}
		}
	}

	// Get focused window info
	if windowID > 0 {
		if windows, ok := serverState["windows"].(map[string]interface{}); ok {
			widStr := fmt.Sprintf("%d", windowID)
			if w, ok := windows[widStr].(map[string]interface{}); ok {
				if name, ok := w["appName"].(string); ok {
					appName = name
				}
				if title, ok := w["title"].(string); ok {
					windowTitle = title
				}
			}
		}
	}

	return
}

// logContextChange logs the context change after reconcile
func logContextChange(
	runtimeState *state.RuntimeState,
	serverState map[string]interface{},
) {
	// Extract current context from server state
	curDisplay, curSpace, curWindowID, curApp, curTitle := extractContext(serverState)

	// Update state and get previous values
	prevDisplay, prevSpace, prevWindowID, prevApp, prevTitle := runtimeState.UpdateContext(
		curDisplay, curSpace, curWindowID, curApp, curTitle,
	)

	// Check if anything changed
	changed := prevDisplay != curDisplay || prevSpace != curSpace ||
		prevWindowID != curWindowID || prevApp != curApp || prevTitle != curTitle

	if changed && (prevDisplay != "" || prevSpace != "" || prevWindowID != 0) {
		logging.Log("Context changed:")
		logging.Log("  Previous: display=%s space=%s app=%s window=%d \"%s\"",
			prevDisplay, prevSpace, prevApp, prevWindowID, prevTitle)
		logging.Log("  Current:  display=%s space=%s app=%s window=%d \"%s\"",
			curDisplay, curSpace, curApp, curWindowID, curTitle)
	} else {
		logging.Log("Context: display=%s space=%s app=%s window=%d \"%s\"",
			curDisplay, curSpace, curApp, curWindowID, curTitle)
	}
}
