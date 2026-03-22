# Pseudocode: Phase 4 - Border-Per-Cell Model

## Design: Border Allocation Model

### Approaches Considered

1. **Approach A: Mode-Aware Rebuild** -- Keep existing pool architecture. Modify `rebuildBorderPool` to check `isActiveCellTabbed`: in tabbed mode, allocate only 1 border (for focused window); in split mode, allocate 1 per visible window. Pool continues to exist for recycling.

2. **Approach B: Eliminate Pool, Direct Cell Borders** -- Remove pool entirely. Each cell "owns" its borders directly. Borders are created when cells become active and destroyed when cells become inactive. In tabbed mode, a single border retargets. In split mode, borders are created per window.

3. **Approach C: Hybrid -- Keep Pool for Split, Retarget-Only for Tabbed** -- In tabbed mode, the active cell has exactly 1 border that retargets on focus change (never released to pool). In split mode, borders are acquired from pool per-window as before. Pool only serves split mode border recycling.

### Comparison

| Criterion | A: Mode-Aware Rebuild | B: No Pool | C: Hybrid |
|-----------|----------------------|------------|-----------|
| Interface simplicity | Same external API | Same external API | Same external API |
| Information hiding | Pool still leaks complexity | Simpler mental model | Pool hidden from tabbed path |
| Change scope | Smallest diff | Largest diff (remove pool infrastructure) | Medium diff |
| Pool eviction (wid:0) | Reduced but still possible | Eliminated entirely | Still possible for split |
| Tabbed border churn | Fixed (1 border + retarget) | Fixed | Fixed |
| Split border churn | Fixed (allocate only visible) | Slightly worse (no recycling) | Same as current (pool recycles) |
| `atomic-positionRefresh` spam | Must fix separately | Must fix separately | Must fix separately |
| Risk of regression | LOW | HIGH (removing tested infrastructure) | LOW-MEDIUM |

### Choice: A (Mode-Aware Rebuild)

**Rationale:** Approach A achieves all five acceptance criteria with the smallest change footprint. The pool infrastructure is stable and well-tested. Removing it (Approach B) introduces unnecessary risk -- SkyLight window creation is expensive and the pool serves split mode well. Approach C adds path-splitting complexity without clear benefit.

**What is sacrificed:** We keep the pool infrastructure (some code weight), but it now sees far less traffic because tabbed mode avoids it entirely.

### Depth Check
- Interface methods: 0 new public methods added (behavior change is internal)
- Hidden details: tabbed vs split allocation logic, position-only refresh optimization
- Common case complexity: simple (tabbed = 1 border, retarget on focus change)

---

## Files to Create/Modify

1. **`SimpleBorderManager.swift`** -- Major modifications (allocation model, rebuild logic, position refresh, completion signaling)
2. **`BorderWindow.swift`** -- No changes needed (retarget already works)
3. **`GridReconciler.swift`** -- Minor change to use completion-aware sync

---

## Pseudocode

### SimpleBorderManager.swift

#### Change 1: Mode-Aware `rebuildBorderPool`

Current behavior: allocates borders for ALL windows in cell regardless of mode.
New behavior: in tabbed mode, allocate 1 border for focused window only.

```
FUNCTION rebuildBorderPool(source)
  release all existing borders to pool (hide, don't destroy)

  guard we have activeCellID, currentDisplayUUID, and assignments for this display

  find all windows in the active cell from assignments
  look up stack mode for this cell (default "tabs")
  set isActiveCellTabbed = (stackMode == "tabs")

  IF tabbed mode:
    // Only the focused window gets a border
    IF we have a focusedWindowID AND it is in windowsInCell:
      acquire border for focusedWindowID
      set as activeBorder with active style
    ELSE IF windowsInCell is not empty:
      // No focused window known yet -- use first window in cell
      acquire border for first window in windowsInCell
      set as activeBorder with active style
    // No inactive borders in tabbed mode
  ELSE (split mode -- vertical or horizontal):
    // All windows in cell are visible -- each gets a border (current behavior)
    FOR EACH windowID in windowsInCell:
      acquire border for windowID
      IF windowID is focused:
        set as activeBorder with active style
      ELSE:
        add to inactiveBorders with inactive style

  log rebuild with source, cell, count, focused, tabbed, poolSize
```

#### Change 2: Mode-Aware `reassignBorders` for Tabbed Mode

Current behavior: demote active to inactive, promote inactive to active (swap borders between two windows).
New behavior in tabbed mode: retarget the single border to the new window (no inactive borders exist).

```
FUNCTION reassignBorders(previousFocused)
  guard we have a focusedWindowID (newFocused)

  IF isActiveCellTabbed:
    // Tabbed mode: retarget the single active border (no inactive borders)
    IF activeBorder exists:
      retarget activeBorder to newFocused
      apply active style (updates stack indicator for new index)
    ELSE:
      // Edge case: no active border -- acquire one
      acquire border for newFocused
      set as activeBorder with active style
    // No inactive borders to manage in tabbed mode
  ELSE:
    // Split mode: promote/demote as before
    IF previousFocused exists AND activeBorder exists:
      change activeBorder to inactive style
      move activeBorder to inactiveBorders keyed by previousFocused
      clear activeBorder

    IF newFocused has an entry in inactiveBorders:
      remove from inactiveBorders
      set as activeBorder with active style
    ELSE:
      // Edge case: window appeared without a border
      acquire border for newFocused
      set as activeBorder with active style
      log warning
```

#### Change 3: Eliminate `atomic-positionRefresh` Rebuild

Current behavior: when `setCellAssignmentsImpl` receives same cell + same focused window, it calls `rebuildBorderPool(source: "atomic-positionRefresh")` which releases all borders to pool and reacquires them.
New behavior: detect this case and only refresh positions of existing borders.

```
FUNCTION setCellAssignmentsImpl(assignments, displayUUID, newFocusedWindow, ...)
  // ... existing state update logic for cellAssignments, cellStackModes, etc ...

  IF newFocusedWindow is provided AND maps to a cell in assignments:
    update focusedWindowID, activeCellID, currentDisplayUUID

    IF display changed OR cell changed:
      rebuildBorderPool(source: "atomic-displayChange" or "atomic-cellChange")
    ELSE IF newFocused differs from previousFocusedWindow:
      update isActiveCellTabbed
      reassignBorders(previousFocused)
    ELSE:
      // CHANGED: same cell, same window -- position-only refresh
      refreshBorderPositions()
  ELSE IF displayUUID matches currentDisplayUUID:
    // ... existing non-atomic path unchanged ...
```

New helper:

```
FUNCTION refreshBorderPositions()
  // Update positions of all active borders without release/reacquire cycle
  IF activeBorder exists:
    get target window frame via SLSGetWindowBounds
    IF success:
      activeBorder.update(targetFrame: frame)

  FOR EACH (windowID, border) in inactiveBorders:
    get window frame via SLSGetWindowBounds
    IF success:
      border.update(targetFrame: frame)

  log "bdr.refresh" with cell, count
```

#### Change 4: Completion Signaling for `setCellAssignments`

Current behavior: `setCellAssignments` dispatches to `DispatchQueue.main.async` and returns immediately (fire-and-forget).
New behavior: add a `completion` callback parameter so callers can know when border work is done.

```
FUNCTION setCellAssignments(assignments, displayUUID, focusedWindowID, ..., completion: (() -> Void)? = nil)
  capture current span
  dispatch to main queue async:
    withValue(span):
      call setCellAssignmentsImpl(...)
      call completion?()
```

The reconciler's `syncBordersForSpace` will use this:

```
// In GridReconciler.syncBordersForSpace:
FUNCTION syncBordersForSpace(spaceID, displayUUID) async
  // ... existing assignment building logic ...

  // Use withCheckedContinuation to await the main-queue border work
  await withCheckedContinuation { continuation in
    simpleBorderManager?.setCellAssignments(
      windowToCellMap,
      forDisplay: displayUUID,
      focusedWindowID: ...,
      cellStackModes: ...,
      windowOrder: ...,
      displayFrame: ...,
      completion: { continuation.resume() }
    )
  }
```

This ensures `releaseFence` in `GridWindowMove` only fires after border work completes on main queue.

**Edge case:** if `simpleBorderManager` is nil, the continuation must still resume:

```
IF simpleBorderManager is nil:
  continuation.resume()
  return
```

#### Change 5: Display Disconnect Cleanup

Current behavior already correct: `handleDisplayDisconnectedImpl` removes per-display caches and releases borders to pool if active display disconnected.

No change needed -- the cell-based model does not change display disconnect semantics. When the active display disconnects, borders are released. When a new display connects and focus moves there, borders are rebuilt via `syncBordersForSpace`.

---

### GridReconciler.swift

#### Change 1: Awaitable `syncBordersForSpace`

Convert from fire-and-forget to completion-awaitable.

```
FUNCTION syncBordersForSpace(spaceID, displayUUID) async
  guard gridState and gridConfig exist

  // ... existing layout lookup, assignment building (unchanged) ...

  // Build windowToCellMap, cellStackModes, windowOrder (unchanged)

  // Get focused window
  let focusedWID = await gridState.getFocusedWindow(spaceID)

  // NEW: await border manager completion via withCheckedContinuation
  IF simpleBorderManager exists:
    await withCheckedContinuation { continuation in
      simpleBorderManager.setCellAssignments(
        windowToCellMap,
        forDisplay: displayUUID,
        focusedWindowID: focusedWID != 0 ? focusedWID : nil,
        cellStackModes: cellStackModes,
        windowOrder: windowOrder,
        displayFrame: bounds,
        completion: { continuation.resume() }
      )
    }
  // If simpleBorderManager is nil, return immediately (nothing to await)
```

---

## Design Notes

### Tabbed vs Split Summary
| Mode | Borders per Cell | Focus Change Behavior |
|------|-----------------|----------------------|
| Tabs | 1 (active only) | Retarget active border to new focused window |
| Vertical/Horizontal | N (1 per visible window) | Promote/demote active/inactive styles |

### Why Keep the Pool
The pool remains for split mode, where cells may have 3-4 visible windows each needing a border. When switching between cells, released borders go to pool and are reused. This avoids SkyLight window creation cost (~8MB backing store per border window).

In tabbed mode, the pool sees minimal traffic: only 1 border is active, and it retargets rather than being released.

### `atomic-positionRefresh` Coalescing
The root cause is `syncBordersForSpace` being called repeatedly with identical data (same assignments, same focus). The position-only refresh replaces the expensive release-reacquire cycle with simple `SLSGetWindowBounds` + `border.update()` calls.

**Callers that trigger `atomic-positionRefresh`:**
- `GridWindowMove` calls `syncBordersForSpace` after moving windows (same cell, same focus -- windows repositioned)
- `GridApply` calls `syncBordersForSpace` after layout apply (same cell, same focus -- windows repositioned)

These are the 69% of rebuilds (754/1090) the plan identified. After this change, they become lightweight position refreshes.

### Completion Signaling Design
Using `withCheckedContinuation` bridges the `DispatchQueue.main.async` boundary cleanly. The completion closure is optional (default nil) to avoid breaking existing call sites that don't need awaiting. Only `GridReconciler.syncBordersForSpace` uses it.

### What Does NOT Change
- `BorderWindow.swift` -- no modifications needed
- `BorderEvents.swift` -- already a no-op
- `SimpleBorderConfig.swift` -- config unchanged
- `BorderRenderer.swift` -- rendering unchanged
- Public API surface of `SimpleBorderManager` -- only internal parameter added (optional completion)
- `GridWindowMove.swift` -- fence acquire/release calls unchanged (benefit from awaitable sync automatically)
- Display disconnect handling -- already correct

---

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (design-it-twice: 3 approaches compared, A selected)
- [x] Ready for implementation
