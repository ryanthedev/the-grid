# Discovery: Phase 3 - Focus Tracking Hardening

## Files Found

All three plan-specified files exist in the worktree:

- `/Users/r/repos/theGrid/.claude/worktrees/reconciler-overhaul/grid-server/Sources/GridServer/Grid/GridFocus.swift` -- 864 lines
- `/Users/r/repos/theGrid/.claude/worktrees/reconciler-overhaul/grid-server/Sources/GridServer/Grid/GridReconciler.swift` -- 679 lines
- `/Users/r/repos/theGrid/.claude/worktrees/reconciler-overhaul/grid-server/Sources/GridServer/Grid/GridWindowMove.swift` -- 710 lines (fence call site, Phase 2 output)
- `/Users/r/repos/theGrid/.claude/worktrees/reconciler-overhaul/grid-server/Sources/GridServer/Grid/GridState.swift` -- 835 lines

## Current State

### Fence model (Phase 2, confirmed implemented)

`GridReconciler` has per-window fencing:
- `fencedWindows: [UInt32: CFAbsoluteTime]` -- per-window fence map
- `acquireFence(windowIDs:reason:)` / `releaseFence(windowIDs:)` -- public API
- `isWindowFenced(_ windowID: UInt32) -> Bool` -- lazy expiry check
- Fence timeout: 5 seconds
- `handleFocusChanged` drops OS events for fenced windows (line ~398)

Fence granularity confirmed as **per-window** (not per-cell). The plan uncertainty note is resolved.

### `focusCellByID` in GridFocus.swift (lines 256-302)

Current logic:
1. Gets `cellWindows` from GridState
2. Filters out dead windows by checking `wmState.windows[String(wid)] != nil`
3. Reads `cellState.lastFocusedWid` and tries `cellWindows.firstIndex(of:)` to restore
4. Falls back to `lastFocusedIdx` if `lastFocusedWid == 0`
5. Falls back to idx 0

**Bug #1 -- lastFocusedWid from moved window not validated against current cell membership:**
The `lastFocusedWid` check uses `cellWindows.firstIndex(of:)` on the already-filtered live window list. If the window moved to another cell/space (Phase 2 scenario: user moves window then focuses source cell), `cellWindows.firstIndex` returns `nil` and the code silently falls through to `lastFocusedIdx` (which may be stale). The code already handles this case by falling through -- but does so silently with no logging, and uses `lastFocusedIdx` which could also be wrong.

Actually, looking more carefully: the filter step already removes dead windows (not in wmState). A window that moved to another cell/space would be removed from the source cell's `windows` array by `prependWindow` (which calls `removeWindowInternal` first). So `lastFocusedWid` referring to a moved window would correctly find no match in `cellWindows` and fall through to `lastFocusedIdx`. This is **mostly correct** but `lastFocusedIdx` can be stale after a window moves.

**Bug #2 -- lastFocusedWid points to wid 0 sentinel incorrectly:**
`lastFocusedWid` is only checked when `!= 0` (line 283). This is correct.

**Bug #3 -- setFocus in handleFocusChanged can overwrite move-set focus:**
`handleFocusChanged` (lines 386-455) calls `gridState.setFocus(...)` at line 444 based on OS focus events. When a fence is active for the moved window, the event is dropped (line 398-401). However, if the OS fires a focus event for a *different* window on the target cell (e.g., the previously-focused window there surfaces briefly), that event passes through the fence and can corrupt the target cell's `lastFocusedWid`. This is the subtle snap-back mechanism described in the plan.

**Bug #4 -- No fence on setFocus in GridState:**
`GridState.setFocus()` has no fence awareness. Any caller (including reconciler) can overwrite focus state for a fenced window's cell.

### `handleFocusChanged` in GridReconciler (lines 386-455)

The fence check guards on `windowID` (the focused window). If OS fires a focus event for a *different* window that happens to be in the target cell (but not fenced itself), `setFocus` is called and may corrupt the cell's focus state. The fenced window's OS event is correctly blocked, but collateral events from co-inhabitants of the same cell are not.

### `GridState.setFocus` (lines 644-663)

No fence awareness. Updates `focusedCell`, `focusedWindow`, `lastFocusedWid`, `prevFocusedWid` unconditionally.

### `GridCellStateData` (lines 28-80)

Has `lastFocusedWid`, `lastFocusedIdx`, `prevFocusedWid`. The three-field scheme is already in place. The issue is not the data model but the guards around writes.

## Gaps Between Plan and Reality

1. **`focusCellByID` validation gap**: The current filter only prunes dead windows (not in wmState). It does NOT validate that `lastFocusedWid` is actually in the current cell's window list before using the fallback path. The window membership check via `firstIndex(of:)` implicitly handles this, but the code doesn't log or handle the "wid moved to another cell" case distinctly from "wid is dead." This makes diagnosing snap-back harder.

2. **`handleFocusChanged` fence scope gap**: The fence check only checks if the *incoming focused window* is fenced. It does not check whether the window is co-located in a cell with a fenced window. When a move happens (window A from cell-1 to cell-2), cell-2 previously had window B. If OS fires focus for window B during the move, B is not fenced so the event passes, calling `setFocus(cell-2, B)`, which corrupts `lastFocusedWid` for cell-2 back to B. This undoes the move's `setFocus(cell-2, A, 0)`.

3. **No `setFocus` guard in GridState**: GridState actor has no mechanism to reject `setFocus` calls for windows involved in an active fence. This is appropriate (GridState shouldn't know about fencing) -- the guard must live in `handleFocusChanged` in GridReconciler where fence state is held.

4. **`lastFocusedIdx` can be stale after moves**: When a window is moved out of a cell, `removeWindow` correctly adjusts `lastFocusedIdx` (lines 415-417 in GridState). When `focusCellByID` falls back to `lastFocusedIdx`, it clamps it to valid range, so this is safe but may pick an unexpected window.

## Prerequisites

- [x] Phase 1 (StateValidator) implemented
- [x] Phase 2 (Command Fencing) implemented -- per-window fence model confirmed
- [x] `fencedWindows` map is in GridReconciler (accessible within same class for guard checks)
- [x] `GridCellStateData` has `lastFocusedWid`, `lastFocusedIdx`, `prevFocusedWid`
- [x] `GridState.setFocus` is the single write point for focus tracking
- [x] `focusCellByID` already has a window-existence filter (wmState check)
- [x] Fence granularity is per-window (not per-cell) -- confirmed, no adaptation needed

## Recommendation

**BUILD**

Three focused changes:

1. **`GridFocus.focusCellByID`**: After the wmState existence filter, add an explicit validation that `lastFocusedWid` is still a member of the current cell's window list. Log when it is not (with "focus.restore.stale" event). This is already partially handled by `firstIndex(of:)` returning nil but needs explicit logging and a cleaner code path.

2. **`GridReconciler.handleFocusChanged`**: When an OS focus event arrives for a window that is *not itself fenced*, check if the cell it belongs to contains any fenced window. If so, drop the event. This prevents collateral OS events from co-cell windows corrupting the cell's `lastFocusedWid` during an active move.

3. **`GridReconciler.handleFocusChanged`**: Add a check: if `windowID` appears in a cell that currently has a fenced sibling, suppress the `setFocus` call even though the event itself is not for a fenced window.

The key insight is that fence protection needs to extend to the **cell level** for `setFocus` decisions, even though fence acquisition/release remains per-window. GridReconciler already has both `fencedWindows` and access to `gridState` to check cell membership.
