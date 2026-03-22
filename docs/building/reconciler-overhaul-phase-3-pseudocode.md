# Pseudocode: Phase 3 - Focus Tracking Hardening

## Files to Create/Modify

- `grid-server/Sources/GridServer/Grid/GridFocus.swift` -- `focusCellByID` validation
- `grid-server/Sources/GridServer/Grid/GridReconciler.swift` -- cell-level fence guard in `handleFocusChanged`

`GridState.swift` requires no changes. The fence model stays per-window in GridReconciler; GridState has no fence awareness (correct separation).

## Design Notes

### Design It Twice: handleFocusChanged cell-level fence guard

**Approach A (chosen):** On each focus event, if the focused window is not itself fenced, look up which cell it belongs to in GridState, then check if that cell contains any window that *is* fenced. If yes, drop the event.

**Approach B:** Maintain `fencedCells: Set<String>` parallel to `fencedWindows`. Acquire/release both together.

**Approach C:** Only block events for windows in the exact target cell of a move (requires storing target cell in fence metadata).

**Comparison:**

| Criterion | A | B | C |
|-----------|---|---|---|
| Extra state to maintain | None | Yes (fencedCells) | Yes (fenced target cell per wid) |
| Correctness when window has multiple cells (cross-space) | Correct (queries actual cell) | Fragile (which cell to fence?) | Fragile |
| Handles source-cell collateral events | Yes (any cell with fenced sibling is blocked) | Yes | No (only protects target cell) |
| Handles cross-display moves | Yes | Requires dual acquire | No |
| Actor calls per focus event | 1 extra when not fenced | 0 extra | 0 extra |

**Choice: Approach A.** Keeps fence model as single source of truth (per-window map in GridReconciler). One additional GridState actor call per non-fenced focus event is acceptable; this path is not hyper-latency-sensitive.

### Information hiding principle

`GridState` must not know about fences. `GridReconciler` owns fence state and is the right place to decide whether to call `gridState.setFocus`. This respects the existing layering.

### focusCellByID: what exactly to fix

The window-existence filter (wmState check) already handles dead windows. The stale `lastFocusedWid` case (window moved to another cell) is already handled implicitly: `prependWindow` calls `removeWindowInternal` which removes the wid from the source cell, so `cellWindows.firstIndex(of: lastFocusedWid)` returns nil and falls through to `lastFocusedIdx`. The fix here is:
1. Add explicit logging when `lastFocusedWid` is non-zero but not found in cellWindows (so we can diagnose)
2. When falling through to `lastFocusedIdx`, clamp it (already done) -- no logic change needed
3. Ensure the fallback produces a valid, visible window -- it does because cellWindows is already filtered

The code is more correct than it first appears. The main hardening value is in (1) logging for diagnostics and ensuring no silent failure.

---

## Pseudocode

### GridFocus.swift -- focusCellByID

```
private func focusCellByID(spaceID: String, cellID: String) async throws -> UInt32

  Guard gridState and stateManager are available, else throw noLayout

  Get wmState from stateManager

  Get cellWindows from gridState for (spaceID, cellID)

  Filter cellWindows to only windows present in wmState.windows
    For each removed wid: fire removeWindow async, log "focus.prune" with wid+cell

  Guard cellWindows is not empty, else throw noWindowsInCell(cellID)

  Read spaceState (read-only) from gridState
  Read cellState = spaceState?.cells[cellID]

  Set targetIdx = 0

  If cellState is not nil:
    If cellState.lastFocusedWid != 0:
      Search cellWindows for lastFocusedWid
      If found at foundIdx:
        Set targetIdx = foundIdx
        // lastFocusedWid is valid -- use it
      Else:
        // lastFocusedWid refers to a window no longer in this cell
        // (moved to another cell/space, or pruned above)
        Log "focus.restore.stale" with data: [wid: lastFocusedWid, cell: cellID, spaceID: spaceID]
        // Fall through to lastFocusedIdx
        Set targetIdx = max(0, min(cellState.lastFocusedIdx, cellWindows.count - 1))
    Else:
      // No lastFocusedWid recorded -- use lastFocusedIdx
      Set targetIdx = max(0, min(cellState.lastFocusedIdx, cellWindows.count - 1))

  Set windowID = cellWindows[targetIdx]

  Call focusWindowByID(windowID)  // AX focus, throws on failure

  Call gridState.setFocus(spaceID: spaceID, cellID: cellID, windowIndex: targetIdx)

  Return windowID
```

This is the complete replacement for `focusCellByID`. The only behavioral change is the `focus.restore.stale` log line. All existing logic paths are preserved.

---

### GridReconciler.swift -- handleFocusChanged (cell-level fence guard)

```
private func handleFocusChanged(_ focusState: FocusState) async

  Guard gridState, stateManager, windowID from focusState are available

  // Guard 1: bulk suppression (unchanged)
  If suppressReconciliation:
    Log "reconcile.focus.suppressed" with wid
    Return

  // Guard 2: direct window fence (unchanged -- window is itself fenced)
  If isWindowFenced(windowID):
    Log "reconcile.focus.fenced" with wid
    Return

  // Guard 3 (NEW): cell-level fence guard
  // If the focused window is NOT itself fenced but shares a cell with a fenced window,
  // drop the event to prevent collateral corruption of lastFocusedWid.
  // This is the primary mechanism preventing snap-back after moves.
  If await isCellMateOfFencedWindow(windowID):
    Log "reconcile.focus.fenced.cell" with data: [wid: windowID]
    Return

  // ... rest of handleFocusChanged unchanged from Phase 2 ...
  // Resolve spaceID and displayUUID (existing logic)
  // Detect space change (existing logic)
  // Update GridState focus to match OS focus (existing setFocus call)
  // Update border focus and sync (existing logic)
```

---

### GridReconciler.swift -- new helper: isCellMateOfFencedWindow

```
// isCellMateOfFencedWindow: returns true if any currently-fenced window
// is in the same cell as windowID (in any space).
// Called only when windowID itself is not fenced.
// Performs lazy expiry cleanup during fence iteration.
private func isCellMateOfFencedWindow(_ windowID: UInt32) async -> Bool

  Guard gridState is available, else return false

  // Collect the set of currently-active fenced window IDs
  // (exclude expired entries, cleaning up as we go)
  Let now = CFAbsoluteTimeGetCurrent()
  Var activeFencedIDs: Set<UInt32> = []
  Var expiredIDs: [UInt32] = []

  For each (fencedWID, expiresAt) in fencedWindows:
    If now > expiresAt:
      Append fencedWID to expiredIDs
    Else:
      Insert fencedWID into activeFencedIDs

  For each expiredID in expiredIDs:
    Remove fencedWindows[expiredID]
    Log "fence.expired" with data: [wid: Int(expiredID)]

  If activeFencedIDs is empty:
    Return false

  // For each space, check if windowID and any activeFencedID share a cell
  Let spaceIDs = await gridState.getSpaceIDs()

  For each spaceID in spaceIDs:
    // Find which cell contains our target windowID
    Let cellOfTarget = await gridState.getWindowCell(windowID: windowID, inSpace: spaceID)
    Guard cellOfTarget is not nil, else continue to next space

    // Get all windows in that cell
    Let cellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: cellOfTarget!)

    // Check if any fenced window is in the same cell
    For each cellWID in cellWindows:
      If activeFencedIDs.contains(cellWID):
        Return true

  Return false
```

**Note on performance:** This helper is only called when the focused window is *not* directly fenced (the cheap `isWindowFenced` check at guard 2 already returns false). In normal (non-move) operation, `fencedWindows` is empty so `activeFencedIDs` is empty and the function returns immediately after the empty-set check. The actor calls only happen during the brief window of an active move fence.

---

### GridReconciler.swift -- isWindowFenced cleanup (minor)

The existing `isWindowFenced` performs lazy expiry. With `isCellMateOfFencedWindow` also doing expiry, there is no double-free risk (both use `removeValue(forKey:)` which is idempotent). No change needed to `isWindowFenced`.

---

## Call Flow: Move + Immediate Focus Switch

```
User: move window A (cell-1 -> cell-2) then immediately focus cell-3

1. GridWindowMove.moveWindowToCell:
   - acquireFence([A], "move.same")
   - prependWindow(A, cell-2)
   - setFocus(cell-2, A, 0)
   - applyPlacementsViaAX(...)
   - focusWindowByID(A)
   - syncBordersForSpace(...)
   - releaseFence([A])

2. OS fires focusChanged(A) during step 1:
   - isWindowFenced(A) -> true -> DROPPED (correct, unchanged)

3. OS fires focusChanged(B) where B was previously in cell-2:
   (B surfaces briefly because A vacated cell-1, making room)
   - isWindowFenced(B) -> false (B is not fenced)
   - isCellMateOfFencedWindow(B):
       * activeFencedIDs = {A}
       * cell of B in some space -> cell-2
       * cellWindows of cell-2 -> [A, B] (A was prepended)
       * A is in activeFencedIDs -> return true
   - DROPPED (correct, NEW behavior)
   - Result: cell-2's lastFocusedWid stays A

4. User triggers focus-right (cell-3):
   - focusCellByID(cell-3)
   - lastFocusedWid for cell-3 is C (valid, in cell-3's window list)
   - C is focused correctly

5. releaseFence([A]) fires after border sync completes
   - Subsequent OS events for A and B pass through normally
```

---

## PRE-GATE Status

- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed -- Approach A chosen over B and C (see Design Notes)
- [ ] Ready for implementation
