# Reconcile Border Sync Implementation Plan

**Status**: IMPLEMENTED (2025-12-17)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make every CLI command that calls reconcile automatically sync cell assignments and bounds to the server, enabling the cell highlight feature.

**Architecture:** Extend `gridReconcile.Sync()` to accept config and client, then after existing reconcile logic, calculate cell bounds from layout + display geometry and send to server via `borders.setCellAssignments` IPC.

**Tech Stack:** Go, existing layout calculation utilities, existing IPC client

---

## Task 1: Update Sync Function Signature

**Files:**
- Modify: `grid-cli/internal/reconcile/reconcile.go`

**Step 1: Update imports**

Add required imports at top of file:

```go
package reconcile

import (
	"context"

	"github.com/yourusername/grid-cli/internal/client"
	"github.com/yourusername/grid-cli/internal/config"
	"github.com/yourusername/grid-cli/internal/logging"
	"github.com/yourusername/grid-cli/internal/server"
	"github.com/yourusername/grid-cli/internal/state"
)
```

**Step 2: Update Sync function signature**

Change the Sync function signature from:

```go
func Sync(snap *server.Snapshot, rs *state.RuntimeState) error {
```

To:

```go
func Sync(ctx context.Context, c *client.Client, snap *server.Snapshot, rs *state.RuntimeState, cfg *config.Config) error {
```

**Step 3: Verify file compiles**

Run: `cd /Users/r/repos/theGrid/grid-cli && go build ./...`
Expected: Compilation errors (call sites need updating) - this is expected, we'll fix them in Task 3.

**Step 4: Commit**

```bash
git add grid-cli/internal/reconcile/reconcile.go
git commit -m "refactor(reconcile): expand Sync signature for border sync support"
```

---

## Task 2: Add syncBorders Helper Function

**Files:**
- Modify: `grid-cli/internal/reconcile/reconcile.go`

**Step 1: Add syncBorders function**

Add this new function after the `equalRatios` function at the end of the file:

```go
// syncBorders sends cell assignments and bounds to the server for border rendering.
// This is called after reconcile to keep server border state in sync with CLI state.
// Errors are logged but don't fail the reconcile - borders are a visual enhancement.
func syncBorders(ctx context.Context, c *client.Client, snap *server.Snapshot, rs *state.RuntimeState, cfg *config.Config) {
	// 1. Check if borders are configured
	if cfg == nil || cfg.Borders == nil || !cfg.Borders.GetEnabled() {
		logging.Debug().Msg("syncBorders: borders not enabled, skipping")
		return
	}

	// 2. Get space state
	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil {
		logging.Debug().
			Str("spaceID", snap.SpaceID).
			Msg("syncBorders: no local state for space, skipping")
		return
	}

	// 3. Get current layout ID
	layoutID := spaceState.CurrentLayoutID
	if layoutID == "" {
		logging.Debug().
			Str("spaceID", snap.SpaceID).
			Msg("syncBorders: no layout applied to space, skipping")
		return
	}

	// 4. Get layout definition from config
	layoutDef, err := cfg.GetLayout(layoutID)
	if err != nil {
		logging.Warn().
			Str("layoutID", layoutID).
			Err(err).
			Msg("syncBorders: failed to get layout definition")
		return
	}

	// 5. Calculate cell bounds
	calculated := calculateCellBounds(layoutDef, snap, spaceState)
	if calculated == nil {
		logging.Debug().Msg("syncBorders: no cell bounds calculated")
		return
	}

	// 6. Build cell assignments from space state
	assignments := buildCellAssignments(spaceState)
	if len(assignments) == 0 {
		logging.Debug().Msg("syncBorders: no cell assignments to send")
		return
	}

	// 7. Send to server
	if err := c.SendCellAssignments(ctx, assignments, nil, calculated); err != nil {
		logging.Warn().Err(err).Msg("syncBorders: failed to send cell assignments")
		return
	}

	logging.Debug().
		Int("assignments", len(assignments)).
		Int("cellBounds", len(calculated)).
		Msg("syncBorders: sent cell assignments to server")
}
```

**Step 2: Commit**

```bash
git add grid-cli/internal/reconcile/reconcile.go
git commit -m "feat(reconcile): add syncBorders helper function skeleton"
```

---

## Task 3: Add Helper Functions for Cell Bounds and Assignments

**Files:**
- Modify: `grid-cli/internal/reconcile/reconcile.go`

**Step 1: Add import for layout package**

Update imports to include the layout package:

```go
import (
	"context"

	"github.com/yourusername/grid-cli/internal/client"
	"github.com/yourusername/grid-cli/internal/config"
	"github.com/yourusername/grid-cli/internal/layout"
	"github.com/yourusername/grid-cli/internal/logging"
	"github.com/yourusername/grid-cli/internal/server"
	"github.com/yourusername/grid-cli/internal/state"
	"github.com/yourusername/grid-cli/internal/types"
)
```

**Step 2: Add calculateCellBounds function**

Add this function before `syncBorders`:

```go
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
```

**Step 3: Add buildCellAssignments function**

Add this function after `calculateCellBounds`:

```go
// buildCellAssignments builds the window-to-cell assignment list from space state.
func buildCellAssignments(spaceState *state.SpaceState) []client.CellAssignment {
	var assignments []client.CellAssignment

	for cellID, cellState := range spaceState.Cells {
		for _, windowID := range cellState.Windows {
			assignments = append(assignments, client.CellAssignment{
				WindowID: windowID,
				CellID:   cellID,
			})
		}
	}

	return assignments
}
```

**Step 4: Commit**

```bash
git add grid-cli/internal/reconcile/reconcile.go
git commit -m "feat(reconcile): add calculateCellBounds and buildCellAssignments helpers"
```

---

## Task 4: Integrate syncBorders into Sync

**Files:**
- Modify: `grid-cli/internal/reconcile/reconcile.go`

**Step 1: Call syncBorders at end of Sync**

Update the `Sync` function to call `syncBorders` before returning. Add after the existing logic (after the `if changed` block):

```go
func Sync(ctx context.Context, c *client.Client, snap *server.Snapshot, rs *state.RuntimeState, cfg *config.Config) error {
	logging.Debug().
		Str("spaceID", snap.SpaceID).
		Uint32("focusedWindowID", snap.FocusedWindowID).
		Int("windowCount", len(snap.Windows)).
		Msg("reconcile: starting sync")

	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil {
		logging.Debug().
			Str("spaceID", snap.SpaceID).
			Msg("reconcile: no local state for space")
		// Still try to sync borders even with no local state
		syncBorders(ctx, c, snap, rs, cfg)
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

	// Sync borders to server (errors logged but don't fail reconcile)
	syncBorders(ctx, c, snap, rs, cfg)

	return nil
}
```

**Step 2: Commit**

```bash
git add grid-cli/internal/reconcile/reconcile.go
git commit -m "feat(reconcile): integrate syncBorders into Sync function"
```

---

## Task 5: Update All Sync Call Sites

**Files:**
- Modify: `grid-cli/cmd/grid/main.go`

This task updates all commands that call `gridReconcile.Sync()` to pass the new parameters.

**Step 1: Find all Sync call sites**

Run: `grep -n "gridReconcile.Sync" grid-cli/cmd/grid/main.go`

This will show all lines that need updating.

**Step 2: Update each call site pattern**

For each command that calls `gridReconcile.Sync`, change from:

```go
if err := gridReconcile.Sync(snap, runtimeState); err != nil {
```

To:

```go
cfg, _ := gridConfig.Load() // Load config for border sync
if err := gridReconcile.Sync(ctx, c, snap, runtimeState, cfg); err != nil {
```

**Commands to update** (each follows the same pattern):
- `focusNextCmd` (around line 1877)
- `focusPrevCmd` (around line 1935)
- `focusLeftCmd`, `focusRightCmd`, `focusUpCmd`, `focusDownCmd`
- `focusCellCmd`
- `sendCmd` (send to cell)
- `moveCmd` (move window)
- Any other command calling `gridReconcile.Sync`

**Step 3: Example update for focusNextCmd**

Before:
```go
// 2. Reconcile local state with server
if err := gridReconcile.Sync(snap, runtimeState); err != nil {
    logging.Error().Str("cmd", "focus-next").Err(err).Msg("failed to reconcile")
    return fmt.Errorf("failed to reconcile state: %w", err)
}
```

After:
```go
// 2. Load config for border sync
cfg, _ := gridConfig.Load()

// 3. Reconcile local state with server (includes border sync)
if err := gridReconcile.Sync(ctx, c, snap, runtimeState, cfg); err != nil {
    logging.Error().Str("cmd", "focus-next").Err(err).Msg("failed to reconcile")
    return fmt.Errorf("failed to reconcile state: %w", err)
}
```

**Step 4: Verify compilation**

Run: `cd /Users/r/repos/theGrid/grid-cli && go build ./...`
Expected: SUCCESS - no compilation errors

**Step 5: Commit**

```bash
git add grid-cli/cmd/grid/main.go
git commit -m "feat(cli): update all commands to pass config to reconcile for border sync"
```

---

## Task 6: Test End-to-End

**Step 1: Rebuild and restart**

```bash
cd /Users/r/repos/theGrid/grid-cli && go build -o thegrid ./cmd/grid
# Restart the server if needed
```

**Step 2: Apply a layout**

```bash
./thegrid layout apply
```

**Step 3: Test focus commands**

```bash
./thegrid focus next
./thegrid focus prev
./thegrid focus left
./thegrid focus right
```

**Step 4: Check server logs**

```bash
tail -50 ~/.local/state/thegrid/grid-server.log | grep -E "(setCellAssignments|Cell bounds|Focus changed)"
```

Expected: You should see:
- `Cell bounds updated` log entries
- `Cell assignments updated` log entries
- `Focus changed` with non-nil `oldCell`/`newCell` values
- Cell highlight should be visible when focusing windows

**Step 5: Commit (if any fixes needed)**

```bash
git add -A
git commit -m "fix(reconcile): address integration issues from testing"
```

---

## Summary

**Files modified:**
1. `grid-cli/internal/reconcile/reconcile.go` - Core changes:
   - Updated `Sync` signature to accept `ctx`, `client`, and `cfg`
   - Added `syncBorders()` function
   - Added `calculateCellBounds()` helper
   - Added `buildCellAssignments()` helper

2. `grid-cli/cmd/grid/main.go` - Updated all `gridReconcile.Sync()` call sites to:
   - Load config before reconcile
   - Pass new parameters

**Behavior change:**
- Every CLI command that reconciles now automatically sends cell assignments to the server
- Server receives cell bounds + window assignments on every focus change
- Cell highlight feature now works without requiring manual layout re-apply
