# Pseudocode: Phase 2 - Command Fencing

## Design Decision: Fence Model

### Approaches Considered
1. **Simple Set** -- Single `Set<UInt32>` + single expiry timestamp
2. **Named Fences** -- Dictionary of fence objects keyed by UUID, each with own expiry
3. **Per-window Timestamp** -- `[UInt32: CFAbsoluteTime]` mapping each fenced window to its expiry

### Comparison
| Criterion | Simple Set | Named Fences | Per-window Timestamp |
|-----------|-----------|--------------|---------------------|
| Interface simplicity | 2 methods | 3+ methods | 2 methods |
| Concurrent fences | Single only | Overlapping | Naturally overlapping |
| Timeout handling | Coarse (single) | Per-fence | Per-window |
| Cleanup complexity | Clear all | Must GC | Lazy on check |

### Choice: Per-window Timestamp
Deepest module. Smallest interface. Callers say "fence this window" and "release this window." Concurrent rapid moves each fence their window independently. Expired entries cleaned lazily. No fence object lifecycle to manage.

---

## Files to Create/Modify

1. `GridReconciler.swift` -- add fence storage, acquire/release/check methods, replace cooldown in `handleFocusChanged`
2. `GridWindowMove.swift` -- replace `beginMove`/`endMove` with `acquireFence`/`releaseFence`, await border sync in same-display moves
3. `GridState.swift` -- make `findSpaceContaining` deterministic

---

## Pseudocode

### GridReconciler.swift

#### Remove old properties
```
REMOVE: moveTargetWindowID
REMOVE: moveEndTime
REMOVE: moveCooldownSeconds
REMOVE: isInMoveCooldown computed property
REMOVE: beginMove(targetWindowID:) method
REMOVE: endMove() method
REMOVE: clearMoveCooldown() method
```

#### Add fence properties
```
// Map from window ID to fence expiry time
// A fenced window's OS focus events are dropped until released or expired
private fencedWindows: [UInt32: CFAbsoluteTime] = empty dictionary

// Safety timeout: fences auto-expire after this duration
private fenceTimeoutSeconds: CFAbsoluteTime = 5.0
```

#### acquireFence method
```
// Fence one or more windows so OS focus events for them are dropped.
// Called by move commands before they begin mutating state.
// reason: logging context only (not stored)
func acquireFence(windowIDs: Set<UInt32>, reason: String)
    let expiresAt = currentTime + fenceTimeoutSeconds
    for each windowID in windowIDs
        fencedWindows[windowID] = expiresAt
    log "fence.acquire" with windowIDs, reason, expiresAt
```

#### releaseFence method
```
// Release fence for specific windows. Called after border sync completes.
func releaseFence(windowIDs: Set<UInt32>)
    for each windowID in windowIDs
        remove windowID from fencedWindows
    log "fence.release" with windowIDs
```

#### isWindowFenced query
```
// Check if a window is currently fenced (not expired).
// Lazily cleans up expired entries.
private func isWindowFenced(_ windowID: UInt32) -> Bool
    guard let expiresAt = fencedWindows[windowID] else
        return false

    if currentTime > expiresAt
        // Fence expired -- safety timeout hit
        remove windowID from fencedWindows
        log "fence.expired" with windowID (warning -- this means timeout was needed)
        return false

    return true
```

#### Modify handleFocusChanged
```
private func handleFocusChanged(focusState)
    guard gridState, stateManager, windowID from focusState else return

    // 1. Bulk suppression (layout apply, picker, terminal ops) -- unchanged
    if suppressReconciliation
        log "reconcile.focus.suppressed" with windowID
        return

    // 2. CHECK FENCE: if this window is fenced, drop the OS event.
    // This replaces the old isInMoveCooldown check.
    // Fences are per-window: other windows' events pass through normally.
    if isWindowFenced(windowID)
        log "reconcile.focus.fenced" with windowID
        return

    // 3. Rest of focus handling unchanged
    // (resolve spaceID, detect space change, update GridState focus, sync borders)
    ... existing logic unchanged ...
```

#### Remove clearMoveCooldown usage
```
// clearMoveCooldown() is removed entirely.
// GridCommandRouter called it before focus commands to prevent stale cooldown.
// With fences, this is unnecessary: explicit focus commands go through
// GridFocus, not handleFocusChanged, so fences don't interfere.
// GridCommandRouter should stop calling clearMoveCooldown.
```

### GridWindowMove.swift

#### Same-display move: moveWindowToCell
```
// CHANGES:
// 1. Acquire fence for moved window BEFORE mutating state
// 2. Await border sync (not fire-and-forget)
// 3. Release fence AFTER border sync completes

private func moveWindowToCell(windowID, sourceCell, targetCell, spaceID, ...) async throws -> GridMoveResult
    guard gridState, gridConfig, gridFocus, gridReconciler else throw

    // FENCE: acquire before any state mutation
    let fencedIDs: Set<UInt32> = [windowID]
    gridReconciler.acquireFence(windowIDs: fencedIDs, reason: "move.same")

    // 1-8: existing logic unchanged (prependWindow, setFocus, calculate placements,
    //       build assignments, apply placements via AX, focus window, warp mouse)
    ... steps 1-10b unchanged ...

    // 11. AWAIT border sync (was fire-and-forget Task{})
    let displayUUIDForBorders = gridFocus.findCurrentDisplayUUID(wmState, spaceID)
    await gridReconciler.syncBordersForSpace(spaceID, displayUUID: displayUUIDForBorders)

    // FENCE: release after border sync completes
    gridReconciler.releaseFence(windowIDs: fencedIDs)

    // Track for rapid-move detection
    lastMovedWindowID = windowID
    lastMoveTime = currentTime

    return GridMoveResult(...)
```

#### Cross-display move: moveWindowCrossDisplay
```
// CHANGES:
// 1. Replace beginMove/endMove with acquireFence/releaseFence
// 2. Fence acquired before SLS move (earlier than current beginMove at step 8)

private func moveWindowCrossDisplay(direction, windowID, sourceCell, ...) async throws -> GridMoveResult
    guard gridState, gridConfig, gridFocus, windowManipulator, gridReconciler else throw

    // Steps 1-5 unchanged (find displays, get cells, map position, find target cell)
    ...

    // 6. FENCE: acquire before SLS move AND state mutation
    //    (replaces beginMove which was at step 8, after SLS move -- too late)
    let fencedIDs: Set<UInt32> = [windowID]
    gridReconciler.acquireFence(windowIDs: fencedIDs, reason: "move.cross")

    // 6b. Move window to target space via WindowManipulator (was step 6)
    windowManipulator.moveWindowToSpace(windowID, spaceID: targetSpaceID)

    // 7. Update state on both source and target spaces (unchanged)
    ...

    // 8. REMOVED: beginMove call -- replaced by acquireFence above

    // 9. Apply layouts on target and source displays in parallel (unchanged)
    ...

    // 10-11. Skip tab raise, focus moved window, override active space (unchanged)
    ...

    // 12. Sync borders (still awaited, same as before)
    await gridReconciler.syncBordersForSpace(sourceSpaceID, displayUUID: sourceDisplayUUID)
    await gridReconciler.syncBordersForSpace(targetSpaceIDStr, displayUUID: targetDisplayUUID)

    // FENCE: release after both border syncs complete
    //   (replaces endMove)
    gridReconciler.releaseFence(windowIDs: fencedIDs)

    // Track for rapid-move detection (unchanged)
    lastMovedWindowID = windowID
    lastMoveTime = currentTime

    return GridMoveResult(...)
```

### GridCommandRouter.swift

#### Remove clearMoveCooldown call
```
// Line ~165: remove gridReconciler.clearMoveCooldown()
// No replacement needed. Fences are per-window and only affect
// OS-originated events in handleFocusChanged. User focus commands
// go through GridFocus directly, bypassing handleFocusChanged.
```

### GridState.swift

#### Make findSpaceContaining deterministic
```
// Replace unordered dictionary iteration with sorted key iteration.
// Prefer the space matching the current display when possible.
//
// Two-signature approach:
// 1. Original signature (backwards compatible): sorts space keys
// 2. New overload with preferredDisplaySpaceIDs for display-aware ordering

func findSpaceContaining(windowID: UInt32) -> String?
    // Sort space keys for deterministic iteration order
    for spaceID in spaces.keys.sorted()
        for (_, cell) in spaces[spaceID].cells
            if cell.windows contains windowID
                return spaceID
    return nil

func findSpaceContaining(windowID: UInt32, preferredSpaceIDs: [String]) -> String?
    // First pass: search preferred spaces in order (current display's spaces)
    for spaceID in preferredSpaceIDs
        guard let space = spaces[spaceID] else continue
        for (_, cell) in space.cells
            if cell.windows contains windowID
                return spaceID

    // Second pass: search remaining spaces in sorted order
    for spaceID in spaces.keys.sorted() where !preferredSpaceIDs.contains(spaceID)
        for (_, cell) in spaces[spaceID].cells
            if cell.windows contains windowID
                return spaceID

    return nil
```

---

## Error Handling Analysis (aposd-simplifying-complexity)

| Error Condition | Technique | Gate Check | Reasoning |
|-----------------|-----------|------------|-----------|
| Fence expires before release | Define out | PASS | Expiry is safety net, not error. Lazy cleanup on next check. Log as warning for debugging. |
| acquireFence on already-fenced window | Define out | PASS | Overwriting expiry with later time is correct behavior. No special case needed. |
| releaseFence on non-fenced window | Define out | PASS | Removing non-existent key from dictionary is a no-op. No error to handle. |
| suppressionDepth underflow | Mask | PASS | Already handled: `max(0, depth - 1)` with warning log. Unchanged. |

---

## Defensive Programming Analysis (cc-defensive-programming)

### Barricade
The fence API is the barricade between OS events (external input) and grid state (trusted internal state). `handleFocusChanged` validates fences at the entry point before allowing any state mutation.

### Assertions vs Error Handling
- Fence timeout expiry: not an error -- it is a safety mechanism. Log as warning, not assert.
- `releaseFence` for unfenced window: not an error -- define out of existence (dictionary removal of missing key is no-op).
- `acquireFence` with empty windowIDs: defensive guard -- return early, log warning.

### Safety Timeout
5-second fence timeout prevents deadlocks if `releaseFence` is never called (e.g., exception during border sync). This is a robustness decision: prefer dropping some OS events for 5 seconds over permanently blocking them.

---

## Design Notes

### Key Decision: Keep `setSuppressed` for non-move callers
The plan says "remove `suppressionDepth`" but 4 callers (GridApply, PickerManager, GridTerminalManager, GridCommandRouter) use `setSuppressed` for bulk suppression unrelated to moves. Removing it would require refactoring all callers to use fences, which is out of scope. Instead, we keep `setSuppressed`/`suppressionDepth` for bulk operations and add fences as a separate, orthogonal mechanism specifically for move-induced focus event blocking.

The check order in `handleFocusChanged` is:
1. `suppressReconciliation` (bulk ops -- blocks ALL events)
2. `isWindowFenced(windowID)` (per-window -- blocks only fenced windows)
3. Normal processing

### Key Decision: Fence acquired before state mutation, released after border sync
This ensures the entire window from state change through visual update is covered. Any OS focus event arriving during this window is dropped.

### Key Decision: `findSpaceContaining` uses sorted keys as baseline
Dictionary iteration order is non-deterministic in Swift. Sorting keys provides stable results across runs. The `preferredSpaceIDs` overload lets callers express display affinity without `findSpaceContaining` needing to know about displays.

### Key Decision: Same-display border sync is now awaited
The fire-and-forget `Task {}` pattern for same-display border sync created a window where OS focus events could arrive and corrupt state before borders synced. Awaiting the sync and bracketing it with a fence eliminates this race.

---

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (Design-It-Twice for fence model)
- [x] Error handling analyzed (aposd-simplifying-complexity)
- [x] Defensive programming analyzed (cc-defensive-programming)
- [x] Per-window fencing assumption verified
- [x] Ready for implementation
