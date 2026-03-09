# Cross-Display Window Move Fixes

Status: complete

## Problem

After the Go-to-Swift migration, cross-display window moves have three bugs:
1. Source space focus goes stale after `removeWindow()` — borders sync with wrong focused window
2. Mouse warp not wired up for `@window move` and `@window swap` — BFD passes `-m` flag but handlers ignore it
3. Border sync order causes flicker — source display sync overwrites target display focus in SimpleBorderManager

## Investigation Summary

- **SimpleBorderManager is single-display**: Only ONE display has borders at a time. Last `setCellAssignments` call wins global focus state.
- **`removeWindow()` doesn't update space-level focus**: `space.focusedCell` and `space.focusedWindow` become stale, so `getFocusedWindow(sourceSpaceID)` returns wrong values.
- **`@window swap` silently fails**: BFD config routes to `@window swap <dir> -m` but `handleWindow` only has `case "move"`.
- **Focus events carry spaceID=0, displayUUID=""**: Reconciler resolves from metadata which can be stale after moves.

## Phase 1: Fix source space focus after removeWindow

**Files**: `GridState.swift`

Tasks:
- In `removeWindow()`, after removing a window from a cell, check if the removed window was the space's focused window
- If so, update `space.focusedCell` and `space.focusedWindow` to point to the next valid window in the same cell, or clear them if cell is empty
- This ensures `getFocusedWindow(sourceSpaceID)` returns a valid window for border sync

## Phase 2: Wire up mouse warp for window move and swap

**Files**: `GridCommandRouter.swift`, `GridWindowMove.swift`

Tasks:
- In `handleWindow` "move" case: parse `cmd.flags.contains("mouse")` into `GridMoveOpts.warpMouse`
- Add `handleWindow` "swap" case: route to `gridCellOps.swapWindow(direction:)`, warp mouse if `-m` flag
- Add `warpMouseToFocusedWindow()` helper to `GridCommandRouter`
- Pass `warpMouse` through `moveWindow` -> `moveWindowCrossDisplay` / `moveWindowToCell`
- In `moveWindowCrossDisplay`: after focus, call `CGWarpMouseCursorPosition` to target cell center
- In `moveWindowToCell`: after focus, call `CGWarpMouseCursorPosition` to target cell center
- Reference implementation: `GridFocus.warpMouseToCell` (line 796)

## Phase 3: Verify border sync and build

**Files**: `GridWindowMove.swift`, `GridReconciler.swift`

Tasks:
- Verify source-first-then-target sync order in `moveWindowCrossDisplay` (already fixed)
- Verify cooldown blocks delayed OS focus events
- Verify `findSpaceContaining` resolves correct display for post-cooldown events
- Build, deploy, test cross-display moves with border + mouse warp
