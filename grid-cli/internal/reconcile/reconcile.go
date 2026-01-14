package reconcile

import (
	"context"

	"github.com/ryanthedev/grid-cli/internal/client"
	"github.com/ryanthedev/grid-cli/internal/config"
	"github.com/ryanthedev/grid-cli/internal/jsonlog"
	"github.com/ryanthedev/grid-cli/internal/layout"
	"github.com/ryanthedev/grid-cli/internal/server"
	"github.com/ryanthedev/grid-cli/internal/state"
	"github.com/ryanthedev/grid-cli/internal/types"
)

// Sync updates runtimeState to match server reality.
// It removes windows from cells that no longer exist on the server,
// and syncs the focused cell to match the OS-focused window.
// This should be called before any command execution to ensure
// local state is accurate.
//
// NOTE: This does NOT sync borders. Call SyncBorders explicitly after
// operations that change cell assignments or bounds.
func Sync(ctx context.Context, c *client.Client, snap *server.Snapshot, rs *state.RuntimeState, cfg *config.Config) error {
	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil {
		return nil
	}

	changed := false
	for cellID, cell := range spaceState.Cells {
		var valid []uint32
		for _, wid := range cell.Windows {
			if snap.WindowIDs[wid] {
				valid = append(valid, wid)
			}
		}

		if len(valid) != len(cell.Windows) {
			// Windows were removed, update cell
			mutableCell := rs.GetSpace(snap.SpaceID).GetCell(cellID)
			mutableCell.Windows = valid
			mutableCell.SplitRatios = equalRatios(len(valid))
			changed = true
		}
	}

	// Sync focus: if OS-focused window is in a different cell, update state
	if snap.FocusedWindowID != 0 {
		if syncFocus(snap, rs) {
			changed = true
		}
	}

	if changed {
		rs.MarkUpdated()
		if err := rs.Save(); err != nil {
			return err
		}
	}

	return nil
}

// syncFocus updates local focus state to match the OS-focused window.
// Returns true if state was changed.
func syncFocus(snap *server.Snapshot, rs *state.RuntimeState) bool {
	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil {
		return false
	}

	// Find which cell contains the OS-focused window
	focusedCell := spaceState.GetWindowCell(snap.FocusedWindowID)
	if focusedCell == "" {
		return false // focused window not in any cell
	}

	cell := spaceState.Cells[focusedCell]
	if cell == nil {
		return false
	}

	// Find window index in the cell
	windowIndex := -1
	for i, wid := range cell.Windows {
		if wid == snap.FocusedWindowID {
			windowIndex = i
			break
		}
	}
	if windowIndex == -1 {
		return false
	}

	// Already correct?
	if focusedCell == spaceState.FocusedCell && windowIndex == spaceState.FocusedWindow {
		return false
	}

	// Update focus
	rs.GetSpace(snap.SpaceID).SetFocus(focusedCell, windowIndex)
	return true
}

// equalRatios returns equal split ratios for n windows.
func equalRatios(n int) []float64 {
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

// calculateCellBounds computes cell bounds from layout definition and display geometry.
func calculateCellBounds(layoutDef *types.Layout, snap *server.Snapshot, spaceState *state.SpaceState) map[string]client.CellRect {
	if layoutDef == nil || len(layoutDef.Cells) == 0 {
		return nil
	}

	// Use ratio overrides from space state if available
	calculated := layout.CalculateLayoutWithRatios(
		layoutDef,
		snap.DisplayBounds,
		0, // gap handled by layout
		spaceState.ColumnRatios,
		spaceState.RowRatios,
	)

	if calculated == nil || len(calculated.CellBounds) == 0 {
		return nil
	}

	// Convert types.Rect to client.CellRect
	result := make(map[string]client.CellRect, len(calculated.CellBounds))
	for cellID, rect := range calculated.CellBounds {
		result[cellID] = client.CellRect{
			X:      rect.X,
			Y:      rect.Y,
			Width:  rect.Width,
			Height: rect.Height,
		}
	}

	return result
}

// buildCellAssignments builds the window-to-cell assignment list from space state.
func buildCellAssignments(spaceState *state.SpaceState) []client.CellAssignment {
	var assignments []client.CellAssignment

	for cellID, cellState := range spaceState.Cells {
		for _, windowID := range cellState.Windows {
			assignments = append(assignments, client.CellAssignment{
				WindowID:  windowID,
				CellID:    cellID,
				StackMode: string(cellState.StackMode),
			})
		}
	}

	return assignments
}

// buildWindowOrder builds a map of cellID -> ordered window IDs for stack indicators.
func buildWindowOrder(spaceState *state.SpaceState) map[string][]uint32 {
	order := make(map[string][]uint32)
	for cellID, cellState := range spaceState.Cells {
		if len(cellState.Windows) > 0 {
			order[cellID] = cellState.Windows
		}
	}
	return order
}

// SyncBorders sends cell assignments and bounds to the server for border rendering.
// Call this after operations that change cell assignments or bounds.
// Errors are logged but don't fail - borders are a visual enhancement.
func SyncBorders(ctx context.Context, c *client.Client, snap *server.Snapshot, rs *state.RuntimeState, cfg *config.Config) {
	// 1. Check if borders are configured
	if cfg == nil || cfg.Borders == nil || !cfg.Borders.GetEnabled() {
		return
	}

	// 2. Get space state
	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil {
		return
	}

	// 3. Get current layout ID
	layoutID := spaceState.CurrentLayoutID
	if layoutID == "" {
		return
	}

	// 4. Get layout definition from config
	layoutDef, err := cfg.GetLayout(layoutID)
	if err != nil {
		jsonlog.Log("warn.sync_borders", jsonlog.WithData(map[string]any{"lid": layoutID, "err": err.Error()}))
		return
	}

	// 5. Calculate cell bounds
	calculated := calculateCellBounds(layoutDef, snap, spaceState)
	if calculated == nil {
		return
	}

	// 6. Build cell assignments from space state
	assignments := buildCellAssignments(spaceState)
	if len(assignments) == 0 {
		return
	}

	// 7. Get display UUID for per-display caching
	displayUUID := snap.GetCurrentDisplayUUID()
	if displayUUID == "" {
		jsonlog.Log("warn.sync_borders", jsonlog.WithMsg("could not determine display UUID"))
		return
	}

	// 9. Send to server (no focused window - caller handles focus separately)
	opts := &client.SendCellAssignmentsOpts{
		DisplayFrame: &snap.DisplayBounds,
		WindowOrder:  buildWindowOrder(spaceState),
	}
	if err := c.SendCellAssignments(ctx, displayUUID, assignments, opts); err != nil {
		jsonlog.Log("warn.sync_borders", jsonlog.WithData(map[string]any{"err": err.Error()}))
		return
	}
}

// SyncBordersForDisplay sends cell assignments for a specific display/space.
// Used when focus crosses displays and we need to sync borders for the target.
// This is similar to syncBorders but uses a DisplayInfo instead of a Snapshot,
// which is necessary when syncing borders for a display other than the current one.
//
// Error handling: Errors are logged but not returned. Border sync is best-effort
// and should not block focus operations.
func SyncBordersForDisplay(ctx context.Context, c *client.Client, displayInfo server.DisplayInfo, spaceID string, rs *state.RuntimeState, cfg *config.Config) {
	if cfg == nil || cfg.Borders == nil || !cfg.Borders.GetEnabled() {
		return
	}

	spaceState := rs.GetSpaceReadOnly(spaceID)
	if spaceState == nil || spaceState.CurrentLayoutID == "" {
		return
	}

	layoutDef, err := cfg.GetLayout(spaceState.CurrentLayoutID)
	if err != nil {
		jsonlog.Log("warn.sync_borders_display", jsonlog.WithData(map[string]any{"lid": spaceState.CurrentLayoutID, "err": err.Error()}))
		return
	}

	// Use display's visible frame for bounds calculation
	displayBounds := displayInfo.VisibleFrame
	if displayBounds == (types.Rect{}) {
		displayBounds = displayInfo.Frame
	}
	if displayBounds == (types.Rect{}) {
		jsonlog.Log("warn.sync_borders_display", jsonlog.WithData(map[string]any{"display": displayInfo.UUID, "msg": "no frame info"}))
		return
	}

	// Create a minimal Snapshot with only the fields needed by calculateCellBounds.
	// calculateCellBounds only uses SpaceID (for logging) and DisplayBounds (for layout calculation).
	pseudoSnap := &server.Snapshot{
		SpaceID:       spaceID,
		DisplayBounds: displayBounds,
	}

	cellBounds := calculateCellBounds(layoutDef, pseudoSnap, spaceState)
	if cellBounds == nil {
		return
	}

	assignments := buildCellAssignments(spaceState)
	if len(assignments) == 0 {
		return
	}

	opts := &client.SendCellAssignmentsOpts{
		DisplayFrame: &displayBounds,
		WindowOrder:  buildWindowOrder(spaceState),
	}
	if err := c.SendCellAssignments(ctx, displayInfo.UUID, assignments, opts); err != nil {
		jsonlog.Log("warn.sync_borders_display", jsonlog.WithData(map[string]any{"err": err.Error()}))
		return
	}
}

// SyncBordersWithFocus sends cell assignments AND updates focus atomically.
// This prevents race conditions when multiple commands execute rapidly.
// Use this instead of SyncBordersForDisplay + SyncBorderFocus for cross-display moves.
func SyncBordersWithFocus(ctx context.Context, c *client.Client, displayInfo server.DisplayInfo, spaceID string, focusedWindowID uint32, rs *state.RuntimeState, cfg *config.Config) {
	if cfg == nil || cfg.Borders == nil || !cfg.Borders.GetEnabled() {
		return
	}

	spaceState := rs.GetSpaceReadOnly(spaceID)
	if spaceState == nil || spaceState.CurrentLayoutID == "" {
		return
	}

	layoutDef, err := cfg.GetLayout(spaceState.CurrentLayoutID)
	if err != nil {
		jsonlog.Log("warn.sync_borders_focus", jsonlog.WithData(map[string]any{"lid": spaceState.CurrentLayoutID, "err": err.Error()}))
		return
	}

	displayBounds := displayInfo.VisibleFrame
	if displayBounds == (types.Rect{}) {
		displayBounds = displayInfo.Frame
	}
	if displayBounds == (types.Rect{}) {
		return
	}

	pseudoSnap := &server.Snapshot{
		SpaceID:       spaceID,
		DisplayBounds: displayBounds,
	}

	cellBounds := calculateCellBounds(layoutDef, pseudoSnap, spaceState)
	if cellBounds == nil {
		return
	}

	assignments := buildCellAssignments(spaceState)
	if len(assignments) == 0 {
		return
	}

	// Send assignments with focused window atomically
	opts := &client.SendCellAssignmentsOpts{
		FocusedWindowID: &focusedWindowID,
		DisplayFrame:    &displayBounds,
		WindowOrder:     buildWindowOrder(spaceState),
	}
	if err := c.SendCellAssignments(ctx, displayInfo.UUID, assignments, opts); err != nil {
		jsonlog.Log("warn.sync_borders_focus", jsonlog.WithData(map[string]any{"err": err.Error()}))
		return
	}
}

// SyncBorderFocus notifies the server of the currently focused window.
// Call this after FocusWindow() to ensure borders update correctly.
// displayUUID should be the display where the window is located.
// Errors are logged but don't fail - borders are a visual enhancement.
func SyncBorderFocus(ctx context.Context, c *client.Client, displayUUID string, windowID uint32, cfg *config.Config) {
	if cfg == nil || cfg.Borders == nil || !cfg.Borders.GetEnabled() {
		return
	}

	if displayUUID == "" {
		jsonlog.Log("warn.sync_border_focus", jsonlog.WithMsg("missing display UUID"))
		return
	}

	if err := c.SendBorderFocus(ctx, displayUUID, windowID); err != nil {
		jsonlog.Log("warn.sync_border_focus", jsonlog.WithData(map[string]any{"err": err.Error()}))
		return
	}
}
