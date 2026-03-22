# Discovery: Phase 2 - Command Fencing

## Files Found

| File | Exists | Lines | Relevance |
|------|--------|-------|-----------|
| `grid-server/Sources/GridServer/Grid/GridReconciler.swift` | YES | 661 | Primary: fence storage, checking, lifecycle; contains suppression/cooldown to replace |
| `grid-server/Sources/GridServer/Grid/GridWindowMove.swift` | YES | 701 | Primary: fence acquisition in moves; contains `beginMove`/`endMove` calls |
| `grid-server/Sources/GridServer/Grid/GridState.swift` | YES | 806 | Primary: `findSpaceContaining` needs deterministic ordering |
| `grid-server/Sources/GridServer/Grid/StateValidator.swift` | YES | 197 | Phase 1 output; no changes needed for Phase 2 |
| `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` | YES | ~821+ | Caller: uses `clearMoveCooldown`, `setSuppressed` |
| `grid-server/Sources/GridServer/Grid/GridApply.swift` | YES | ~91+ | Caller: uses `setSuppressed` |
| `grid-server/Sources/GridServer/Grid/GridTerminalManager.swift` | YES | ~126+ | Caller: uses `setSuppressed` |
| `grid-server/Sources/GridServer/Picker/PickerManager.swift` | YES | ~262+ | Caller: uses `setSuppressed`, `findSpaceContaining` |

## Current State

### Suppression Model (to be replaced for moves)
- `suppressionDepth: Int` -- ref-counted suppression. Multiple callers nest: GridApply, PickerManager, GridCommandRouter (focus), GridTerminalManager, and moves (via `beginMove`).
- `setSuppressed(_, syncOnResume:)` -- increment/decrement depth; on reaching 0 optionally triggers `syncBordersForCurrentSpace()`.
- `beginMove(targetWindowID:)` -- increments suppressionDepth, records targetWindowID.
- `endMove()` -- decrements suppressionDepth, records `moveEndTime` for cooldown.
- `moveCooldownSeconds = 1.0` -- after `endMove()`, ignores ALL focus events for 1 second.
- `moveTargetWindowID: UInt32` -- tracked but only used for logging during cooldown, not for per-window filtering.
- `clearMoveCooldown()` -- resets `moveTargetWindowID` to 0; called by GridCommandRouter before explicit focus commands.

### Focus Event Handling
- `handleFocusChanged` checks `suppressReconciliation` (depth > 0) first -- skips entirely.
- Then checks `isInMoveCooldown` -- skips ALL focus events (not just for the moved window).
- This means during the 1s cooldown after a cross-display move, switching focus to a completely different window is blocked. This is overly aggressive.

### Same-Display Move Border Sync
- `moveWindowToCell` (line 335-337): border sync is fire-and-forget via `Task { await gridReconciler.syncBordersForSpace(...) }`. This means the move returns before borders are synced, and no fence/suppression protects this window during the async border sync.

### Cross-Display Move Border Sync
- `moveWindowCrossDisplay` (line 501-503): border sync IS awaited, and `beginMove`/`endMove` bracket the entire operation including sync. This is the correct pattern.

### `findSpaceContaining` Non-Determinism
- Iterates `spaces` dictionary (unordered `[String: GridSpaceStateData]`). When a window exists in multiple spaces (before dedup runs), the result depends on dictionary hash ordering, which varies between runs.
- `displaySpaces: [String: [String]]` maps display UUIDs to ordered space ID lists. This can provide a deterministic ordering when combined with a "prefer current display" heuristic.

### `setSuppressed` Callers (NOT being replaced)
The plan says to replace `beginMove`/`endMove` and cooldown with fences. The `setSuppressed` API is used by other callers (GridApply, PickerManager, GridTerminalManager, GridCommandRouter) for bulk operation suppression that is separate from move fencing. These callers should continue to use `setSuppressed` as-is. Only the move-specific suppression (`beginMove`/`endMove`/cooldown) is replaced by fences.

## Gaps

### Gap 1: `setSuppressed` vs fences distinction
The plan says "remove `suppressionDepth`" but `setSuppressed` is used by 4 non-move callers. We need to keep `setSuppressed` for bulk operations (layout apply, picker, terminal, focus commands) and ONLY replace the move-specific `beginMove`/`endMove`/cooldown mechanism with fences.

**Resolution:** Keep `suppressionDepth` and `setSuppressed` for non-move callers. Replace `beginMove`, `endMove`, `clearMoveCooldown`, `moveTargetWindowID`, `moveEndTime`, `moveCooldownSeconds`, and `isInMoveCooldown` with the fence model. The `handleFocusChanged` method checks fences AFTER checking `suppressReconciliation` (which covers bulk ops).

### Gap 2: Same-display moves lack suppression entirely
Currently `moveWindowToCell` does NOT call `beginMove`/`endMove`. It just fires border sync as a detached Task. This means an OS focus event arriving between the AX placement and the async border sync could corrupt focus state. The fence model must cover same-display moves too.

### Gap 3: Fence scope for same-display moves
Same-display moves reposition windows in source AND target cells. The moved window gets AX focus. OS may fire focus events for the moved window OR for windows in affected cells that were repositioned. Per-window fencing on just the moved window should be sufficient -- OS focus events for other windows that are merely repositioned (not focused) are unlikely, and even if they arrive, they would correctly update state since those windows remain in their cells.

### Gap 4: `clearMoveCooldown` replacement
GridCommandRouter calls `clearMoveCooldown()` before explicit focus commands to prevent stale cooldown from blocking user-initiated focus. With fences, this becomes `releaseFencesForWindow(windowID)` or more simply: explicit focus commands should pass through fences since they represent new user intent. The fence check in `handleFocusChanged` only applies to OS-originated events, not user commands. Since user focus commands go through GridCommandRouter -> GridFocus (not through `handleFocusChanged`), this is already naturally handled -- no equivalent of `clearMoveCooldown` is needed.

## Assumption Verification: Per-Window Fencing Granularity

**Assumption:** Per-window fencing is sufficient (Confidence: MED)

**Analysis:** Examined move flows:
- Same-display: Only the moved window gets AX focus. Other windows in affected cells are repositioned but not focused. OS focus events for non-moved windows would be harmless state updates.
- Cross-display: The moved window gets AX focus. OS fires delayed `appActivated` for the moved window's app on the target display. The problematic events are specifically for the moved window.
- The current overly-broad suppression (block ALL events) is too aggressive. Per-window fencing on the moved window is the right granularity.

**Verdict:** Assumption CONFIRMED. Per-window fencing is sufficient. No need for per-cell fencing.

## Prerequisites

- [x] Phase 1 (StateValidator) completed and merged
- [x] All three target files exist and are readable
- [x] StateValidator wired into GridReconciler (line 32, 109-111, 477)
- [x] `setSuppressed` callers identified -- non-move callers will not be affected
- [x] `findSpaceContaining` non-determinism confirmed (dictionary iteration)
- [x] Same-display move fire-and-forget border sync confirmed (line 335-337)

## Recommendation

**BUILD**

All prerequisites are met. The implementation has three distinct work items:
1. Add fence model to GridReconciler (storage, acquire, release, timeout check, fence-aware focus handling)
2. Replace `beginMove`/`endMove`/cooldown in GridWindowMove with fence acquisition; await border sync in same-display moves
3. Make `findSpaceContaining` deterministic in GridState (prefer current display's spaces)
