# Discovery: Phase 2 - Wire up mouse warp for window move and swap

## Files Found

| File | Exists | Current State |
|------|--------|---------------|
| GridCommandRouter.swift | YES | `warpMouseToFocusedWindow()` helper exists (L245-253). `handleWindow` "move" case parses `-m` into `GridMoveOpts.warpMouse` (L413-417). `handleWindow` "swap" case routes to `gridCellOps.swapWindow()` + calls `warpMouseToFocusedWindow()` if mouse flag (L421-431). |
| GridWindowMove.swift | YES | `GridMoveOpts.warpMouse` field exists (L20). `moveWindow()` accepts opts but never reads `warpMouse`. `moveWindowToCell()` and `moveWindowCrossDisplay()` do NOT accept or use `warpMouse`. No mouse warp call anywhere in this file. |
| GridFocus.swift | YES | `warpMouseToCell()` (L797-804) is the reference implementation. It is `private` to GridFocus. Uses `CGWarpMouseCursorPosition(bounds.center)`. |
| GridCellOps.swift | YES | `swapWindow(direction:)` exists (L134-202). Swaps windows within same cell. Already wired from router. |
| bfd.yaml | YES | All `@window move` calls pass `--extend -m`. All `@window swap` calls pass `-m`. |

## Current State

### What is DONE (from earlier work in this conversation)
1. Router `warpMouseToFocusedWindow()` helper -- DONE, warps to focused window frame center
2. Router `handleWindow` "swap" case -- DONE, routes to swapWindow + mouse warp
3. Router `handleWindow` "move" case parses `-m` flag into `GridMoveOpts.warpMouse` -- DONE
4. `GridMoveOpts.warpMouse` field -- DONE

### What is NOT done
1. `moveWindow()` never reads `opts.warpMouse` -- it passes opts but discards the flag
2. `moveWindowToCell()` does not accept `warpMouse` parameter, does not warp mouse
3. `moveWindowCrossDisplay()` does not accept `warpMouse` parameter, does not warp mouse
4. Neither move function calls `CGWarpMouseCursorPosition` after focusing the window

### Key observation
The simplest fix is to NOT thread `warpMouse` through the private methods at all. Instead, have `moveWindow()` (the public entry point) call `CGWarpMouseCursorPosition` after the move completes, using the result's target cell position. This avoids modifying signatures of two private methods.

However, there is a subtlety: after `moveWindowToCell`/`moveWindowCrossDisplay`, the window has been focused and placed. We need the window's actual frame (post-placement) to warp to. The router already has `warpMouseToFocusedWindow()` which does exactly this -- warps to the focused window's frame center from wmState.

BUT `warpMouseToFocusedWindow()` reads from `stateManager.getState()` which may have stale frame data (the window was just repositioned via AX but the snapshot hasn't refreshed). The better approach: warp to the TARGET CELL center using layout-calculated bounds, not window frame. This is what `GridFocus.warpMouseToCell()` does.

Two options:
- **Option A**: Warp in `moveWindow()` after the result returns, using calculated cell bounds (requires recalculating or passing them back)
- **Option B**: Warp in `moveWindowToCell`/`moveWindowCrossDisplay` where cell bounds are already available, thread `warpMouse` bool through
- **Option C**: Warp in the router after `moveWindow()` returns, using `warpMouseToFocusedWindow()` which reads window frame from wmState (may be stale)

Option B is cleanest -- cell bounds are already calculated in both methods, and we add one parameter.

## Gaps

1. `moveWindow()` needs to pass `opts.warpMouse` to `moveWindowToCell()` and `moveWindowCrossDisplay()`
2. `moveWindowToCell()` needs a `warpMouse` parameter and a `CGWarpMouseCursorPosition` call after focus
3. `moveWindowCrossDisplay()` needs a `warpMouse` parameter and a `CGWarpMouseCursorPosition` call after focus
4. Both methods need access to the target cell bounds to compute warp position (already available in `calculated.cellBounds` in `moveWindowToCell`, and `targetCellBounds` in `moveWindowCrossDisplay`)

## Prerequisites
- [x] GridCommandRouter swap case already wired
- [x] GridMoveOpts.warpMouse field exists
- [x] Router parses -m flag correctly
- [x] Reference implementation in GridFocus.warpMouseToCell available
- [x] Phase 1 (removeWindow focus fix) completed

## Recommendation
BUILD - Thread warpMouse through moveWindowToCell and moveWindowCrossDisplay, add CGWarpMouseCursorPosition calls using target cell bounds.
