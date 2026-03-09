# Review: Cross-Display Window Move Fixes (All Phases)

## Verdict: PASS

## Scope

This review covers all changes across three phases:
- **Phase 1**: Fix source space focus after `removeWindow()` in GridState
- **Phase 2**: Wire up mouse warp (`-m` flag) for `@window move` and `@window swap`
- **Phase 3**: Verify border sync order, suppression, cooldown, and rapid-move detection

Additional changes beyond the plan:
- MSS availability cache in MSSClient
- Rapid-move detection (`lastMovedWindowID`/`lastMoveTime`) in GridWindowMove
- Parallel layout apply in `moveWindowCrossDisplay` (TaskGroup)
- Short flag parsing (`-m`, `-w`, `-e`) in GridCommandRouter
- Timing instrumentation in `moveWindowCrossDisplay`
- `findSpaceContaining(windowID:)` query in GridState
- `findDisplayUUIDForSpace`, `findCurrentSpaceID`/`findCurrentDisplayUUID` metadata-first resolution in GridReconciler
- `beginMove`/`endMove` cooldown API in GridReconciler
- `setSuppressed` `syncOnResume` parameter
- ConfigSnapshot batching in `applyPartialLayout` and `moveWindowToCell`
- Tab raise skipped for cross-display moves
- Border sync deferred via `Task {}` in same-display `moveWindowToCell`

## Spec Match
- [x] Phase 1: `removeWindow()` space-level focus fix -- implemented at GridState.swift lines 436-444
- [x] Phase 2: `warpMouse` threaded to `moveWindowToCell` and `moveWindowCrossDisplay` -- lines 327-329 and 471-473
- [x] Phase 2: `@window swap` routing added to `handleWindow` -- GridCommandRouter lines 421-431
- [x] Phase 2: `warpMouseToFocusedWindow` helper -- GridCommandRouter lines 245-253
- [x] Phase 2: Short flag parsing (`-m` -> `mouse`) -- GridCommandRouter lines 47-51, 213-220
- [x] Phase 3: Border sync order source-first-target-last -- GridWindowMove lines 478-479
- [x] Phase 3: `beginMove`/`endMove` suppression bracket -- GridWindowMove lines 431, 480
- [x] Phase 3: Cooldown blocks ALL focus events for 1s -- GridReconciler lines 189-196
- [x] Phase 3: `findSpaceContaining` resolves correct space -- GridReconciler line 205
- [x] Test coverage: Plan specifies none; no tests required

Unplanned additions (all reasonable optimizations, no scope creep concerns):
- MSS cache, ConfigSnapshot batching, parallel TaskGroup, timing logs, tab raise removal

## Dead Code

**`t7` timing variable (GridWindowMove.swift line 464)**: `t7` is set immediately after `t6` with no intervening work (tab raise was removed). The timing log reports `tab_raise_ms` which will always be 0. This is vestigial but not unreachable code -- it is harmlessly measured and logged. Minor finding, not a FAIL.

**`resetAvailabilityCache()` (MSSClient.swift line 150)**: Defined but never called. The doc comment says "call on system wake to re-probe MSS" but `handleSystemWake` in GridReconciler does not call it. This means if MSS becomes unavailable after sleep/wake, the cache will return stale `true`. Conversely if MSS was unavailable at boot but gets injected later (unlikely per the comment), the cache returns stale `false`. This is a minor gap but does not affect cross-display move correctness -- MSS is used for `moveWindowToSpace` which is called via `WindowManipulator`, not `MSSClient.isAvailable()` directly.

## End-to-End Trace: Rapid Cross-Display Move

Scenario: User presses ctrl-shift-L twice quickly (move window right across displays, then back left).

### Move 1: Right (Display A -> Display B)

1. BFD sends `@window move right -e -m` via socket
2. `GridCommandRouter.dispatch` parses: domain=window, action=move, flags={extend, mouse}
3. `handleWindow` builds `GridMoveOpts(extend: true, warpMouse: true)`
4. `moveWindow()` fetches `wmState`, gets `activeSpaceID` from metadata
5. `lastMovedWindowID == 0` (first move), so uses `getFocusedWindow(spaceID)` -- correct
6. No adjacent cell in direction right -> `opts.extend` is true -> calls `moveWindowCrossDisplay`
7. Finds adjacent display B, gets target cell bounds and target spaceID
8. `windowManipulator.moveWindowToSpace` moves window via SkyLight/MSS
9. `gridState.removeWindow` from source space -- **Phase 1 fix**: space-level focus updated to next window in source cell
10. `gridState.prependWindow` to target cell, `setFocus` on target space
11. `gridReconciler.beginMove(targetWindowID:)` -- sets `suppressReconciliation = true`
12. Parallel layout apply via TaskGroup (source + target cells)
13. Tab raise SKIPPED (prevents spurious OS focus event on source display)
14. `focusWindowByID(windowID)` -- final OS-level focus
15. `CGWarpMouseCursorPosition` to target cell center on display B
16. Border sync: source space FIRST, target space LAST -- target wins global focus
17. `gridReconciler.endMove()` -- `suppressReconciliation = false`, `moveEndTime` set
18. `lastMovedWindowID = windowID`, `lastMoveTime` set

### Move 2: Left (Display B -> Display A) -- within 1 second

1. BFD sends `@window move left -e -m`
2. `moveWindow()` fetches `wmState` -- metadata may still say Display A is active (stale)
3. **Rapid-move detection**: `lastMovedWindowID != 0` and `now - lastMoveTime < 1.0`
4. `findSpaceContaining(lastMovedWindowID)` returns Display B's spaceID -- correct even though metadata is stale
5. `spaceID` corrected to Display B's space; `windowID` set to `lastMovedWindowID`
6. Gets space state for Display B's space -- has layout, finds source cell on Display B
7. No adjacent cell left on Display B -> extends cross-display to Display A
8. Same sequence as Move 1 but reversed direction

**Key state protections:**
- During Move 2, any delayed OS focus event from Move 1's `appActivated` hits the cooldown check (`isInMoveCooldown` returns true for ~1s after `endMove`). Event is logged and dropped.
- `findSpaceContaining` queries GridState (actor-isolated, synchronous updates) rather than wmState metadata (async, possibly stale)
- `beginMove` suppresses reconciler during the entire move operation
- Border sync order ensures target display always wins the global focus in SimpleBorderManager

### Potential Stale State Identified

**wmState snapshot**: `moveWindow()` fetches `wmState` once at the top (line 107) and passes it through to `moveWindowCrossDisplay`. The wmState is used for: display list, display bounds, current display UUID lookup. These are display-level properties that don't change during rapid window moves (displays don't move). The window-level metadata (`activeSpaceID`) in wmState could be stale, but the rapid-move path bypasses it via `findSpaceContaining`. **No issue.**

**`moveEndTime` before `beginMove`**: On the second rapid move, `isInMoveCooldown` checks `moveEndTime` from Move 1. Since Move 2 calls `beginMove` (setting `suppressReconciliation = true`), the cooldown check in `handleFocusChanged` is actually bypassed by the suppression check first (line 181). The cooldown matters for events arriving AFTER `endMove`. **No issue.**

## Correctness Verification

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | PASS | All 3 plan requirements implemented: (1) removeWindow focus fix, (2) mouse warp for move+swap, (3) border sync verification. Rapid-move detection added as discovered necessity. |
| Concurrency | PASS (note) | `GridState` is an actor (all mutations serialized). `GridWindowMove` and `GridReconciler` are classes with instance variables (`lastMovedWindowID`, `suppressReconciliation`, `moveTargetWindowID`) accessed from async contexts. In practice, BFD commands are serialized per-socket and EventRouter processes handlers sequentially. The lack of formal isolation is a pre-existing architectural pattern, not introduced by these changes. |
| Error Handling | PASS | All failure points throw typed errors (`GridWindowMoveError`). Guard-let patterns on weak references throw `.noLayout`. `findSpaceContaining` returning nil falls back to `getFocusedWindow`. Mouse warp silently skips on missing cell bounds (acceptable degradation). |
| Resource Mgmt | N/A | No resources acquired. TaskGroup completes before method returns. Deferred `Task` for same-display border sync is fire-and-forget but only calls `syncBordersForSpace` (idempotent). |
| Boundaries | PASS | Empty cell after removeWindow: focusedCell cleared. `windowID == 0`: guarded by throw. `lastMovedWindowID == 0`: rapid-move check skipped. `findSpaceContaining` returns nil: falls through to normal path. |
| Security | N/A | All input from BFD socket (local Unix socket, no untrusted input). |

## Defensive Programming

| Check | Status | Evidence |
|-------|--------|----------|
| No empty catch blocks | PASS | No try/catch added; errors propagate via throws |
| No swallowed exceptions | PASS | `try?` used only for layout config lookup in `applyPartialLayout` ConfigSnapshot (returns nil, handled by `guard let layoutDef`). Pre-existing pattern. |
| No assertions with side effects | PASS | No assertions used |
| External input validated | PASS | `-m` flag parsed via `cmd.flags.contains("mouse")`, defaults to false |
| Broad exception types | PASS | All throws use specific `GridWindowMoveError` cases |
| Silent failures checked | PASS | `beginMove`/`endMove` log suppressed events. Cooldown logs ignored events with window ID and age. `warpMouse` skip on missing bounds is intentional and non-critical. |

## Findings (non-blocking)

1. **`resetAvailabilityCache()` never called**
   - File: `/Users/r/repos/theGrid/grid-server/Sources/GridServer/MSSClient.swift:150`
   - The method exists to re-probe MSS after sleep/wake but is never invoked from `handleSystemWake`. Not a cross-display move issue but worth wiring up.

2. **Vestigial `tab_raise_ms` timing (always 0)**
   - File: `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Grid/GridWindowMove.swift:464`
   - `t7` is set immediately after `t6` with no intervening work. The timing log entry is harmless noise.

3. **`GridWindowMove` and `GridReconciler` are classes, not actors**
   - Files: `GridWindowMove.swift:52`, `GridReconciler.swift:12`
   - Instance variables (`lastMovedWindowID`, `suppressReconciliation`, `moveTargetWindowID`, `moveEndTime`) are accessed from async contexts without formal isolation. Pre-existing architectural pattern; practically safe due to serialized BFD dispatch and sequential EventRouter processing. Not introduced by these changes.
