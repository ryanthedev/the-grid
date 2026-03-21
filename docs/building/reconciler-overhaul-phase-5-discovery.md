# Discovery: Phase 5 - Resilience

## Files Found

Existing files mentioned in plan:
- [x] `grid-server/Sources/GridServer/Grid/GridReconciler.swift` -- wake handler, display disconnect handler exist
- [x] `grid-server/Sources/GridServer/Grid/GridState.swift` -- space migration exists
- [x] `grid-server/Sources/GridServer/Grid/GridApply.swift` -- `refreshAllDisplays()` exists (post-wake reapply path)
- [x] `grid-server/Sources/GridServer/Grid/StateValidator.swift` -- periodic validator from Phase 1 exists
- [x] `grid-server/Sources/GridServer/Borders/SimpleBorderManager.swift` -- `handleDisplayDisconnected()` exists

Relevant supporting files:
- [x] `grid-server/Sources/GridServer/EventRouter.swift` -- `displayConnected`, `displayDisconnected`, `systemWoke` event types all exist
- [x] `grid-server/Sources/GridServer/Grid/GridAssignment.swift` -- `isTileable()` and `minTileableDimension = 100.0`
- [x] `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` -- command entry point
- [x] `grid-server/Sources/GridServer/MessageHandler.swift` -- IPC request handler

## Current State

### Wake Handler (`handleSystemWake` in GridReconciler)
Already does:
1. Migrates space IDs via `gridState.migrateSpaceIDs()`
2. Calls `stateValidator?.validate(wmState:)` to prune zombies
3. Calls `syncBordersForCurrentSpace()` after validation

**Missing:** No gate that blocks user commands during wake validation. If a command arrives before validation completes, it runs against potentially stale/pre-migration state.

### Display Disconnect Handler
- `GridReconciler.handleDisplayDisconnected()` calls `simpleBorderManager?.handleDisplayDisconnected()` -- cleans up border state for that display
- `SimpleBorderManager.handleDisplayDisconnectedImpl()` removes cached assignments/modes, releases borders to pool if it was the active display

**Missing:**
- No pruning of GridState windows/spaces for the disconnected display. Windows from that display remain in GridState.
- No `displayConnected` handler in GridReconciler (the event exists in EventRouter, but the `default:` branch in `handle()` swallows it)
- No space migration triggered by display reconnect

### Window Creation Burst (Ghostty)
`isTileable()` in GridAssignment.swift:
- Checks `frame.height < 100.0 || frame.width < 100.0` -- this IS the zero-size filter
- Also checks `subrole != "AXStandardWindow"` -- secondary filter
- Both checks already apply in `handleWindowCreated()` via `isTileable(window:)` guard

**Assumption verification: Ghostty zero-size windows can be filtered by frame size (HIGH confidence) -- CONFIRMED.** The `isTileable()` check with `minTileableDimension = 100.0` already filters them. The plan notes "95 of 106 Ghostty windows created are never destroyed" -- these are the ephemeral zero-size ones that get filtered before assignment. Current code already handles this filtering correctly.

**Issue:** The `windowCreated` burst still generates AX observer calls and StateManager state queries for each of 9-14 windows in <1s. Each call traverses `handleWindowCreated()` up to the `isTileable()` guard. This is fast (no border work occurs) but does cause log noise and StateManager queries. Debouncing on `windowCreated` events is plausible but risky (could miss real windows). The filtering already in place IS sufficient -- no event storm for border/state operations since none reach assignment.

**Conclusion on Ghostty:** The existing `isTileable()` guard effectively prevents assignment and border operations for burst windows. The remaining concern is log noise only, not event storms. Adding explicit debounce would be overcomplicated for the actual risk. The "done when" criterion is already met by existing filtering.

### App Crash Recovery
StateValidator (Phase 1) already handles this:
- Runs every 30s via `DispatchSourceTimer`
- Calls `SLSGetWindowBounds()` for each tracked window
- Prunes those that fail the liveness check

**Confirmed:** "State survives app crashes (validator catches orphaned windows within 30s)" is already implemented by Phase 1.

## Gaps

### Gap 1: Wake gate -- commands not blocked during validation
`handleSystemWake()` is async but no mechanism prevents commands from executing concurrently. The `MessageHandler.handle()` dispatches commands in `Task {}` blocks without any coordination with wake state. Commands could interleave with `migrateSpaceIDs()` and `validate()`.

The `GridState` actor serializes state mutations, so individual operations are safe. But the issue is semantic: a `focus` command that reads old space IDs before migration completes may act on stale data and appear to succeed but do the wrong thing.

**Proposed fix:** Add a `wakeValidationTask: Task<Void, Never>?` to GridReconciler. Set it when `handleSystemWake()` starts, clear it when complete. Commands that touch GridState `await` this task before proceeding. Since GridCommandRouter routes commands, the gate can live in GridReconciler as `func awaitWakeCompletion() async`.

### Gap 2: Display disconnect -- GridState not pruned
When a display disconnects, its spaces and windows remain in GridState. They become orphaned -- the next validator pass (up to 30s later) will prune zombie windows, but spaces for the disconnected display survive indefinitely if their space IDs remain in wmState (e.g., macOS keeps the space IDs for disconnected displays for some time).

**Proposed fix:** In `handleDisplayDisconnected()`, look up which space IDs belong to this display (from last known wmState) and remove their windows from GridState tracking. The spaces themselves should not be removed immediately (space IDs may survive display disconnection) -- leave that to `pruneDeadSpaces()`.

### Gap 3: Display reconnect -- no handler
`displayConnected` events are swallowed by the `default:` branch. On reconnect, borders for that display are in the pool (from disconnect cleanup) but GridState still has the layout and window assignments. No border sync is triggered.

**Proposed fix:** Add `handleDisplayConnected()` handler that calls `syncBordersForCurrentSpace()` -- or more precisely, syncs borders for the space on the reconnected display. `refreshAllDisplays()` from GridApply is the right mechanism here (already handles per-display layout reapply).

## Assumption Verification

| Assumption | Status | Evidence |
|-----------|--------|---------|
| Ghostty zero-size windows filtered by frame size | CONFIRMED | `isTileable()` checks `frame < 100.0` before any assignment |
| Fallback (subrole filter) needed? | NOT NEEDED | Frame check sufficient and already in place |

## Prerequisites Met

- [x] Phase 1 (StateValidator): periodic validator and `validate()` method exist
- [x] Phase 2 (Fencing): `fencedWindows`, `acquireFence`, `releaseFence` exist in GridReconciler
- [x] Phase 3 (Focus hardening): fence-aware focus handling exists
- [x] Phase 4 (Border-per-cell): `SimpleBorderManager` display disconnect handler cleans up borders correctly
- [x] All required files exist and are buildable

## Recommendation

**BUILD**

Scope is narrower than the plan implies because:
1. Ghostty burst filtering is already handled by `isTileable()` -- no new work needed
2. App crash recovery is handled by StateValidator from Phase 1 -- no new work needed

Actual work:
1. Add wake gate to GridReconciler (new `wakeValidationTask` + `awaitWakeCompletion()`)
2. Add display disconnect GridState pruning in `handleDisplayDisconnected()`
3. Add `handleDisplayConnected()` to trigger border resync on reconnect
4. Wire `displayConnected` case in the event `switch` statement

Files to modify:
- `GridReconciler.swift` -- wake gate, display connect/disconnect handlers
