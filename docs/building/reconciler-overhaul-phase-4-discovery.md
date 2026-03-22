# Discovery: Phase 4 - Border-Per-Cell Model

## Files Found

| File | Exists | Lines | Role |
|------|--------|-------|------|
| `grid-server/Sources/GridServer/Borders/SimpleBorderManager.swift` | YES | 1001 | Main target: allocation model, rebuild logic, pool management |
| `grid-server/Sources/GridServer/Borders/BorderWindow.swift` | YES | 619 | Retarget behavior already implemented |
| `grid-server/Sources/GridServer/Borders/BorderEvents.swift` | YES | 37 | No-op handler (legacy); no changes needed |
| `grid-server/Sources/GridServer/Borders/SimpleBorderConfig.swift` | YES | 509 | Config; no changes needed |
| `grid-server/Sources/GridServer/Borders/BorderRenderer.swift` | YES | -- | Rendering; no changes needed |
| `grid-server/Sources/GridServer/Grid/GridReconciler.swift` | YES | 736 | Call site: `syncBordersForSpace` builds assignments and calls `setCellAssignments` |
| `grid-server/Sources/GridServer/Grid/GridWindowMove.swift` | YES | -- | Call site: fence acquire/release bracketing `syncBordersForSpace` |
| `grid-server/Sources/GridServer/Grid/GridApply.swift` | YES | -- | Call site: `syncBordersForSpace` after layout apply |
| `grid-server/Sources/GridServer/Grid/GridState.swift` | YES | -- | `getCellStackMode` returns `GridStackMode?` (tabs/vertical/horizontal) |

## Current State

### Border Allocation Model (Pool-Based, Per-Window)
- `SimpleBorderManager` maintains a **global pool of 10** (`maxPoolSize = 10`) reusable `BorderWindow` instances.
- `rebuildBorderPool()` creates borders for **all windows in the active cell**, regardless of stack mode.
- `isActiveCellTabbed` is tracked (set on every rebuild/focus change) but **never used to filter allocation**. In tabbed mode, all windows in cell get borders, even though only the visible (focused) window needs one.
- Pool evictions (`bdr.pool.evict`) occur when borders are released and the pool is full (> 10). Evicted borders often have `wid: 0` (already destroyed).

### Rebuild Trigger Analysis
- `rebuildBorderPool()` is called from **6 locations** inside `SimpleBorderManager`:
  1. `atomic-displayChange` -- display changed during atomic focus update
  2. `atomic-cellChange` -- cell changed during atomic focus update
  3. `atomic-positionRefresh` -- **same cell, same window, assignments resent** (69% of rebuilds per plan notes)
  4. `setCellAssignments` -- assignments changed on current display
  5. `setCellAssignments-init` -- first assignment after startup
  6. `updateFocus-displayChange` / `updateFocus-cellChange` -- cell/display change via `updateFocus`

- `syncBordersForCurrentSpace()` is called from **8 locations** in GridReconciler:
  - suppression release, window destroyed, window created, picker launch, focus changed, space changed, system wake, window minimized

### Existing Retarget Capability
- `BorderWindow.retarget(to:)` already exists and works: updates `targetWindowID`, fetches new bounds, moves to target space, re-orders below new target.
- `reassignBorders()` already handles same-cell focus changes by **promoting/demoting** active/inactive borders without destroy/recreate.

### `atomic-positionRefresh` Problem
- When `setCellAssignments` receives the **same focused window in the same cell**, it falls through to `rebuildBorderPool(source: "atomic-positionRefresh")`.
- This triggers: release all borders to pool -> re-acquire from pool for every window -> re-style -> show.
- This is a full destroy/recreate cycle disguised as a "refresh". It should be a position-only update.

### Fire-and-Forget Sync
- `setCellAssignments` dispatches to `DispatchQueue.main.async` -- fire-and-forget.
- The Phase 2 fencing model works by **awaiting** `syncBordersForSpace` (which calls `setCellAssignments`) then releasing the fence. But since `setCellAssignments` dispatches async, the fence release may happen before the border work actually executes on main queue.
- This is a latent race that hasn't caused visible issues because the main queue processes the work quickly, but it should be fixed as part of this phase.

### Display Disconnect Handling
- `handleDisplayDisconnectedImpl` already exists: clears per-display caches, releases borders to pool if disconnected display was active.
- This is functionally correct but releases to pool rather than destroying -- needs slight adaptation for cell-based model.

## Gaps

### Gap 1: Tabbed Mode Ignores `isActiveCellTabbed`
**Plan says:** Tabbed cells get exactly 1 border.
**Reality:** `rebuildBorderPool` allocates borders for ALL windows in cell regardless of `isActiveCellTabbed`.
**Fix:** In tabbed mode, allocate only 1 border (for focused window). Use `retarget` when focus changes within cell.

### Gap 2: `atomic-positionRefresh` Causes Full Rebuild
**Plan says:** Coalesce rebuilds (max 1 per user action).
**Reality:** Every `syncBordersForSpace` call that finds same-cell/same-window triggers a full release-and-reacquire cycle.
**Fix:** Detect "same cell, same window, same assignments" and do position-only update instead of rebuild.

### Gap 3: No Completion Signal from `setCellAssignments`
**Plan says:** Adapt awaited sync call site from Phase 2.
**Reality:** `setCellAssignments` uses `DispatchQueue.main.async` with no completion callback. Phase 2 fence release after `await syncBordersForSpace` does not actually wait for border work to complete.
**Fix:** Add async/await completion mechanism so fence release waits for border work.

### Gap 4: Split Mode Border Count Undefined
**Plan says:** N borders for split mode (uncertainty noted).
**Reality:** Current code already allocates 1 border per visible window in split mode (all windows visible). This is correct behavior for split -- each window is independently positioned and needs its own border.
**Answer to uncertainty:** Split mode = 1 border per window in cell (all visible). Tabbed mode = 1 border total (only focused window visible).

## Prerequisites
- [x] Phase 2 (Command Fencing) completed -- fences exist, `syncBordersForSpace` is awaited
- [x] Phase 3 (Focus Tracking) completed -- `handleFocusChanged` respects fences
- [x] `BorderWindow.retarget()` already implemented
- [x] `reassignBorders()` already handles same-cell focus changes
- [x] `isActiveCellTabbed` already tracked (just not used)
- [x] `cellStackModes` already passed through the border sync pipeline
- [x] `GridStackMode` enum exists: `.tabs`, `.vertical`, `.horizontal`

## Recommendation
**BUILD**

The changes are well-scoped and modify primarily `SimpleBorderManager.swift` with a minor addition for completion signaling. The existing `retarget` and `reassignBorders` infrastructure makes the tabbed-mode optimization straightforward. The main complexity is:
1. Changing `rebuildBorderPool` to be mode-aware (tabbed vs split)
2. Converting `atomic-positionRefresh` from full rebuild to position-only update
3. Adding completion signaling to `setCellAssignments` for proper fence integration
