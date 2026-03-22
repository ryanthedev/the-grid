# Discovery: Phase 6 - Unified Action Execution Model

## Files Found

All files referenced in the plan exist in the worktree:

| File | Exists | Role |
|------|--------|------|
| `GridReconciler.swift` | YES | Will host `executeAction` method. Already has `setSuppressed`, fence APIs, `syncBordersForCurrentSpace/ForSpace` |
| `GridCommandRouter.swift` | YES | Primary caller -- focus, nudge, pick, terminal dispatch |
| `GridFocus.swift` | YES | `focusWindowByID` (retry target), `moveFocusCrossDisplay` (has ad-hoc verify to subsume) |
| `GridApply.swift` | YES | `applyLayout` calls `setSuppressed` directly |
| `PickerManager.swift` | YES | Complex multi-path suppression in `handleResult` |
| `GridTerminalManager.swift` | YES | Actor with `setSuppressed` in `toggle()` |
| `GridWindowMove.swift` | YES | Uses fence API directly (not suppression) -- not a conversion target |
| `StateManager.swift` | YES | Has `overrideActiveSpace`, `metadata.focusedWindowID` |

## Current State

### Suppression Architecture
- `suppressionDepth` is a ref-counted integer on GridReconciler (not an actor)
- `setSuppressed(true)` increments, `setSuppressed(false)` decrements
- When depth reaches 0 with `syncOnResume: true`, triggers `syncBordersForCurrentSpace()`
- 6 distinct call sites across 4 files, each with different patterns

### All `setSuppressed` Call Sites (Exhaustive)

| Caller | File | Pattern | Sync Param | Scope |
|--------|------|---------|------------|-------|
| focus commands | GridCommandRouter:172 | defer-based | false/true | Short, wraps handleFocus |
| nudge enter/exit | GridCommandRouter:755,824 | manual | false/true | LONG-LIVED across session |
| nudge error | GridCommandRouter:791 | manual | false/false | Error cleanup (no sync needed) |
| applyLayout | GridApply:90 | defer-based | default(true)/default(true) | Short, border sync inside |
| picker handleResult | PickerManager:198 | manual multi-path | false at start, true at various exits | Complex: 5 unsuppress calls for different action types |
| terminal toggle | GridTerminalManager:125 | defer-based | false/true | Short, wraps toggle |

### Focus Verification Pattern (Ad-hoc, to be subsumed)
- `GridFocus.moveFocusCrossDisplay` (line 430-448): After `focusCellByID`, reads `metadata.focusedWindowID`, if different from requested, updates GridState to match OS reality. No retry -- just accepts what OS focused.
- `GridWindowMove` cross-display (line 494-497): Uses `overrideActiveSpace` but no verify-after-focus.

### Fence vs Suppression
- **Fences** are used by `GridWindowMove` for move operations (per-window, blocks OS focus events for specific windows)
- **Suppression** is used by all other callers (global, blocks ALL reconciler event handling)
- Phase 6 `executeAction` consolidates the suppression pattern only. Fences remain independent (Phase 2).

## Gaps

### Gap 1: `focusWindowByID` has no retry logic
The plan requires retry-on-mismatch in `focusWindowByID`. Currently, this is a fire-and-call to `WindowManipulator.focusWindow`. The cross-display verify in `moveFocusCrossDisplay` is separate and ad-hoc.

### Gap 2: Nudge mode does not fit simple wrapper pattern
Nudge is a long-lived session where suppression is held across multiple keystrokes. The `executeAction` wrapper (suppress -> execute -> verify -> sync -> unsuppress) assumes short-lived closures. Nudge needs special handling:
- **Option A:** Two executeAction variants: one for short-lived, one that returns a "session" token for long-lived.
- **Option B:** Nudge uses raw `executeAction` for enter/exit separately (enter starts suppression, exit ends it).
- **Option C:** Nudge stays as-is with direct `setSuppressed` since it's conceptually different (not a single action).

### Gap 3: PickerManager is not an actor
PickerManager runs on main thread (like SimpleBorderManager). Its suppression pattern is the most complex -- suppress before hide, unsuppress at different points. The `executeAction` wrapper would need to be callable from main-thread classes.

### Gap 4: GridApply does its own border sync inside
`applyLayout` already calls `syncBordersForSpace` explicitly (step 14). If `executeAction` also syncs on unsuppress, there would be a double sync. Need to either: pass `syncOnResume: false` from within, or have `executeAction` skip sync when the closure already handles it.

### Gap 5: `overrideActiveSpace` needed for cross-display operations
The plan says `overrideActiveSpace` should be called automatically for cross-display operations. But `executeAction` can't know whether an operation is cross-display without inspecting the closure's behavior. This is better handled by the callers (GridFocus, GridWindowMove) which already call it.

## Prerequisites
- [x] Required files exist
- [x] Dependencies available (suppressionDepth, syncBordersForSpace, etc.)
- [x] Phases 1-5 complete (validator, fencing, focus tracking, border-per-cell, resilience)
- [x] `syncBordersForSpace` is awaitable (Phase 4 withCheckedContinuation)

## Recommendation

**BUILD** with the following design decisions:

1. **`executeAction` has two overloads:** One for short-lived async closures (focus, layout apply, terminal toggle), one for scoped "session" begin/end (nudge).

2. **Nudge uses session-style:** `executeAction` returns immediately for nudge enter (holds suppression), nudge exit calls a corresponding release method. Alternatively, nudge just uses enter/exit calls that still go through a common pathway.

3. **PickerManager:** The complex multi-path suppression needs to be simplified. The wrapper should accept a closure that returns a "disposition" indicating whether to sync immediately or defer.

4. **Focus retry in `focusWindowByID`:** Add mismatch check after AX focus call. Read `metadata.focusedWindowID` (cached, no OS call). If mismatch, retry AX focus once. Log on mismatch. Accept reality after retry.

5. **Cross-display `overrideActiveSpace`:** Keep in callers (GridFocus, GridWindowMove) -- they know when they're crossing displays. Don't try to auto-detect in `executeAction`.

6. **Remove ad-hoc verify from `moveFocusCrossDisplay`:** The verify logic moves into `focusWindowByID`'s retry. The `overrideActiveSpace` call stays.
