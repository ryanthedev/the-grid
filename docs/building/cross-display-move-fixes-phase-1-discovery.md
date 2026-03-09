# Discovery: Phase 1 - Fix source space focus after removeWindow

## Files Found
- `grid-server/Sources/GridServer/Grid/GridState.swift` -- exists, contains `removeWindow()` (line 396), `getFocusedWindow()` (line 619), `setFocus()` (line 598), `GridSpaceStateData` struct (line 12)
- `grid-server/Sources/GridServer/Grid/GridReconciler.swift` -- exists, contains `syncBordersForSpace()` (line 343) which calls `getFocusedWindow()`
- `grid-server/Sources/GridServer/Grid/GridWindowMove.swift` -- exists, `moveWindowCrossDisplay` calls `removeWindow` then `syncBordersForSpace` for source

## Current State

### The Bug
`removeWindow()` (line 396-441) correctly updates **cell-level** focus tracking (`lastFocusedIdx`, `lastFocusedWid`, `prevFocusedWid`) but never touches **space-level** focus (`space.focusedCell`, `space.focusedWindow`).

After a cross-display move:
1. `moveWindowCrossDisplay` calls `removeWindow(windowID, fromSpace: spaceID)` (line 411)
2. Source space's `focusedCell` and `focusedWindow` remain pointing at old values
3. `syncBordersForSpace(sourceSpaceID)` is called (line 460)
4. Inside, `getFocusedWindow(spaceID)` reads stale `space.focusedCell` and `space.focusedWindow`
5. If `focusedWindow` index is now out of bounds (window was removed), it falls back to `cell.windows[0]` -- wrong window gets border highlight

### `removeWindowInternal` (line 449)
Has the same gap but is only called by `assignWindow`/`prependWindow`/`insertWindow` which set focus explicitly afterward. Lower priority.

### getFocusedWindow flow (line 619-629)
```
1. Get space.focusedCell -> look up cell
2. Use space.focusedWindow as index into cell.windows[]
3. If index valid -> return cell.windows[focusedWindow]
4. If index out of bounds -> return cell.windows[0]  (WRONG fallback)
```

The fallback to `[0]` is the specific cause of wrong borders -- it picks an arbitrary remaining window instead of the cell's actual last-focused window.

## Gaps

1. `removeWindow()` does not update `space.focusedCell` or `space.focusedWindow` -- **this is the bug**
2. `removeWindowInternal()` has the same gap but is mitigated by callers setting focus afterward
3. No gap between plan and reality -- the plan accurately describes the problem

## Prerequisites
- [x] `GridState.swift` exists and is the only file to modify
- [x] `removeWindow()` method identified at line 396
- [x] Space-level focus fields (`focusedCell`, `focusedWindow`) identified in `GridSpaceStateData`
- [x] Cell-level focus fields (`lastFocusedIdx`, `lastFocusedWid`) already correctly updated
- [x] Caller chain understood: `moveWindowCrossDisplay` -> `removeWindow` -> `syncBordersForSpace` -> `getFocusedWindow`

## Recommendation
**BUILD** -- The fix is surgical: add space-level focus update logic to `removeWindow()` after the cell-level focus update block (around line 436).
