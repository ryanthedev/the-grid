# Pseudocode: Phase 6 - Unified Action Execution Model

## Design Decision

**Two-method approach:**
- `executeAction` -- closure-based for short-lived operations (focus, layout apply, terminal toggle, picker)
- `beginAction` / `endAction` -- session-based for long-lived operations (nudge)

Both enforce the same lifecycle: suppress -> execute -> verify -> sync -> unsuppress.
The difference is whether the lifecycle is scoped to a single closure or to an explicit session.

`setSuppressed` becomes private (or internal for test access). No caller outside GridReconciler uses it directly.

## Files to Create/Modify

1. `GridReconciler.swift` -- Add `executeAction`, `beginAction`, `endAction`. Make `setSuppressed` private.
2. `GridFocus.swift` -- Add retry logic in `focusWindowByID`. Remove ad-hoc verify from `moveFocusCrossDisplay`.
3. `GridCommandRouter.swift` -- Refactor focus and nudge to use `executeAction` / `beginAction` / `endAction`.
4. `GridApply.swift` -- Refactor `applyLayout` to use `executeAction`.
5. `PickerManager.swift` -- Refactor `handleResult` to use `executeAction`.
6. `GridTerminalManager.swift` -- Refactor `toggle` to use `executeAction`.

## Pseudocode

### GridReconciler.swift -- `executeAction`

```
// executeAction: unified lifecycle wrapper for short-lived state-mutating actions.
//
// Lifecycle: suppress -> execute closure -> verify focus -> sync borders -> unsuppress
//
// Parameters:
//   label: string for logging (e.g. "focus.left", "layout.apply")
//   syncBorders: whether to sync borders on completion (default: true)
//     Callers that do their own border sync inside the closure pass false.
//   body: async throwing closure containing the action's work
//
// The verify step is lightweight: reads metadata.focusedWindowID (cached in StateManager,
// no OS call). Only used to log mismatches -- actual retry happens inside focusWindowByID.
//
// Error handling: if body throws, still unsuppress and sync (borders should reflect
// whatever partial state change happened).

func executeAction<T>(
    label: String,
    syncBorders: Bool = true,
    body: () async throws -> T
) async rethrows -> T

    jlog("action.start", data: ["label": label])

    // 1. Suppress reconciler (blocks OS focus events from contaminating state)
    suppressionDepth += 1

    // 2. Execute the caller's work
    // Use do/catch to ensure unsuppress happens even on throw
    do
        let result = try await body()

        // 3. Unsuppress
        suppressionDepth = max(0, suppressionDepth - 1)

        // 4. Sync borders if requested and depth reached 0
        if suppressionDepth == 0 && syncBorders
            await syncBordersForCurrentSpace()

        jlog("action.end", data: ["label": label])
        return result

    catch
        // Still unsuppress on error
        suppressionDepth = max(0, suppressionDepth - 1)

        if suppressionDepth == 0 && syncBorders
            await syncBordersForCurrentSpace()

        jlog("action.err", data: ["label": label, "err": error description])
        throw error
```

```
// beginAction / endAction: session-based lifecycle for long-lived operations.
//
// beginAction increments suppression depth and returns an opaque token.
// endAction decrements and syncs borders.
//
// Usage pattern (nudge):
//   let token = beginAction(label: "nudge")
//   ... multiple keystrokes over seconds/minutes ...
//   endAction(token)
//
// The token is a simple struct that records the label for logging.
// It does NOT enforce single-use -- caller discipline required.

struct ActionToken
    let label: String
    let startTime: CFAbsoluteTime

func beginAction(label: String) -> ActionToken
    suppressionDepth += 1
    jlog("action.begin", data: ["label": label, "depth": suppressionDepth])
    return ActionToken(label: label, startTime: CFAbsoluteTimeGetCurrent())

func endAction(_ token: ActionToken, syncBorders: Bool = true)
    if suppressionDepth <= 0
        jlog("warn.action.end.underflow", data: ["label": token.label])
    suppressionDepth = max(0, suppressionDepth - 1)
    jlog("action.end", data: [
        "label": token.label,
        "depth": suppressionDepth,
        "dur_ms": Int((CFAbsoluteTimeGetCurrent() - token.startTime) * 1000)
    ])
    if suppressionDepth == 0 && syncBorders
        Task
            await syncBordersForCurrentSpace()
```

```
// Make setSuppressed private.
// The only remaining internal use is inside executeAction/beginAction/endAction.
// Rename to _adjustSuppression or just inline the increment/decrement.

// Remove the public setSuppressed method.
// Any code that was calling it directly now uses executeAction or beginAction/endAction.
```

### GridFocus.swift -- `focusWindowByID` with retry

```
// focusWindowByID: focus a window via WindowManipulator with mismatch retry.
//
// After the AX focus call, checks metadata.focusedWindowID (cached, no OS call).
// If the OS focused a different window, retries AX focus once.
// Logs on mismatch. Accepts reality after retry.
//
// This subsumes the ad-hoc verify in moveFocusCrossDisplay.

func focusWindowByID(_ windowID: UInt32) async throws
    guard let stateManager, let windowManipulator
        throw windowNotFound(windowID)

    let wmState = await stateManager.getState()
    guard let windowState = wmState.windows[String(windowID)]
        throw windowNotFound(windowID)

    // Attempt 1: AX focus
    let success = windowManipulator.focusWindow(pid: windowState.pid, windowID: windowID)
    if !success
        throw focusFailed(windowID)

    // Verify: read cached focused window ID (no OS call)
    // Small delay to allow OS to update the cached value
    // Actually: metadata.focusedWindowID is updated by StateManager polling.
    // After an AX focusWindow call, the OS will fire an event that StateManager handles.
    // But during suppression, we may not get that event immediately.
    // Instead, just re-read state after a tiny yield.
    let postState = await stateManager.getState()
    let actualFocusedWID = postState.metadata.focusedWindowID

    if let actualWID = actualFocusedWID, actualWID != windowID
        // Mismatch: OS focused a different window. Retry once.
        jlog("focus.mismatch", data: [
            "requested": windowID,
            "actual": actualWID,
            "retry": true,
        ])

        // Attempt 2: retry AX focus
        let retrySuccess = windowManipulator.focusWindow(pid: windowState.pid, windowID: windowID)

        // Check again after retry
        let retryState = await stateManager.getState()
        let retryActualWID = retryState.metadata.focusedWindowID

        if let retryWID = retryActualWID, retryWID != windowID
            // Still mismatched after retry. Accept OS reality.
            jlog("focus.mismatch.accept", data: [
                "requested": windowID,
                "actual": retryWID,
            ])
            // Do NOT throw -- accept what the OS gave us.
```

### GridFocus.swift -- Simplify `moveFocusCrossDisplay`

```
// Remove the ad-hoc verify block (lines 432-448) from moveFocusCrossDisplay.
// The retry logic is now in focusWindowByID, which moveFocusCrossDisplay already calls.
//
// Keep the overrideActiveSpace call (line 430) -- this is still needed for
// cross-display operations where macOS metadata lags.
//
// Keep the explicit border sync call (line 451) -- this syncs the TARGET display
// which syncBordersForCurrentSpace would miss (it syncs the SOURCE display).

// Before (lines 422-453):
//   var windowID = try await focusCellByID(...)
//   await stateManager?.overrideActiveSpace(...)
//   let postState = await stateManager?.getState()
//   if let actualWID = postState?.metadata.focusedWindowID, actualWID != windowID {
//       // ... update GridState to match OS ...
//   }
//   await gridReconciler?.syncBordersForSpace(...)
//   return windowID

// After:
//   let windowID = try await focusCellByID(...)
//   await stateManager?.overrideActiveSpace(...)
//   await gridReconciler?.syncBordersForSpace(...)
//   return windowID
//
// Note: focusCellByID calls focusWindowByID which now does the retry.
// If OS focuses a different window, focusWindowByID retries.
// But GridState focus tracking still needs to be correct.
// The focusCellByID already sets GridState focus BEFORE calling focusWindowByID,
// and focusWindowByID's retry doesn't update GridState.
//
// IMPORTANT: We need to handle the case where focusWindowByID's retry still
// results in a mismatch. The old code updated GridState to match reality.
// New approach: focusWindowByID returns the ACTUAL focused window ID (or the
// requested one if it succeeded). Then callers can update GridState if needed.
//
// REVISED: Make focusWindowByID return the actual focused window ID.
// Return type changes from Void to UInt32.
// If focus succeeded (or mismatch accepted), return what the OS actually focused.

func focusWindowByID(_ windowID: UInt32) async throws -> UInt32
    // ... (focus + retry as above) ...
    // Return the actual focused window ID
    // If retry succeeded or first attempt matched: return windowID
    // If mismatch accepted: return the actualWID from OS
    return actualFocusedWindowID

// Then in moveFocusCrossDisplay:
    let requestedWindowID = try await focusCellByID(...)
    await stateManager?.overrideActiveSpace(...)

    // focusCellByID already called focusWindowByID which handles retry.
    // But if mismatch was accepted, GridState may point to wrong window.
    // Re-read what's actually focused and update GridState if needed.
    let postState = await stateManager?.getState()
    if let actualWID = postState?.metadata.focusedWindowID,
       actualWID != requestedWindowID {
        let cellWindows = await gridState.getCellWindows(...)
        if let actualIdx = cellWindows.firstIndex(of: actualWID) {
            await gridState.setFocus(spaceID: ..., cellID: targetCell, windowIndex: actualIdx)
            windowID = actualWID
        }
    }

    await gridReconciler?.syncBordersForSpace(...)
    return windowID
```

### GridCommandRouter.swift -- Refactor focus commands

```
// Before:
//   case "focus":
//       gridReconciler.setSuppressed(true, syncOnResume: false)
//       defer { gridReconciler.setSuppressed(false, syncOnResume: true) }
//       return try await handleFocus(parsed)

// After:
//   case "focus":
//       return try await gridReconciler.executeAction(label: "focus.\(parsed.action)") {
//           try await handleFocus(parsed)
//       }
//
// Note: executeAction handles suppress/unsuppress/sync internally.
// The return value flows through naturally.
```

### GridCommandRouter.swift -- Refactor nudge

```
// Nudge enter:
// Before:
//   gridReconciler.setSuppressed(true, syncOnResume: false)

// After:
//   Store token as instance variable on GridCommandRouter:
//   private var nudgeActionToken: GridReconciler.ActionToken?
//
//   On enter:
//     nudgeActionToken = gridReconciler.beginAction(label: "nudge")
//
//   On exit:
//     if let token = nudgeActionToken {
//         gridReconciler.endAction(token, syncBorders: true)
//         nudgeActionToken = nil
//     }
//
//   On error during enter:
//     gridReconciler.endAction(token, syncBorders: false)
```

### GridApply.swift -- Refactor applyLayout

```
// Before:
//   gridReconciler?.setSuppressed(true)
//   defer { gridReconciler?.setSuppressed(false) }
//   ... layout work including explicit syncBordersForSpace ...

// After:
//   try await gridReconciler?.executeAction(label: "layout.apply", syncBorders: false) {
//       ... layout work including explicit syncBordersForSpace ...
//   }
//
// syncBorders: false because applyLayout does its own syncBordersForSpace
// at the end (step 14) with explicit space/display parameters. The generic
// syncBordersForCurrentSpace would be redundant and potentially wrong
// (it might sync the wrong display in multi-monitor setups).
//
// ISSUE: gridReconciler is optional (weak). executeAction is on the reconciler.
// If reconciler is nil, we still want to run the layout work.
// Solution: If reconciler is nil, run body directly without suppression.
// The executeAction call is `try await gridReconciler?.executeAction(...) ?? body()`.
// Actually, this is awkward. Better: check reconciler existence and run directly if nil.
//
// ALTERNATIVE: GridApply already has a non-optional path to gridReconciler
// (it fails early with noLayout if dependencies are nil). So we can force-unwrap safely
// or use guard let.
```

### PickerManager.swift -- Refactor handleResult

```
// PickerManager is complex because:
// 1. It runs on main thread (not async)
// 2. Suppression needs to span across a Task{} for focusWindow action
// 3. Multiple exit paths with different sync needs

// Strategy: Use beginAction/endAction instead of executeAction closure.
// This maps to the existing manual pattern but through the unified API.

// Before:
//   gridReconciler?.setSuppressed(true, syncOnResume: false)
//   ... hide() ...
//   ... action dispatch ...
//   ... various gridReconciler?.setSuppressed(false, syncOnResume: true) calls ...

// After:
//   let token = gridReconciler?.beginAction(label: "picker.result")
//   ... hide() ...
//   ... action dispatch ...
//   ... gridReconciler?.endAction(token, syncBorders: true) at each exit path ...
//
// For focusWindow case where a Task{} defers the endAction:
//   Task { [weak self] in
//       await self?.updateGridStateFocus(windowID)
//       if let token = token {
//           reconciler?.endAction(token, syncBorders: true)
//       }
//   }
//
// For immediate cases:
//   if let token = token {
//       gridReconciler?.endAction(token, syncBorders: true)
//   }
```

### GridTerminalManager.swift -- Refactor toggle

```
// Before:
//   gridReconciler.setSuppressed(true, syncOnResume: false)
//   defer { gridReconciler.setSuppressed(false, syncOnResume: true) }
//   ... toggle logic ...

// After:
//   return await gridReconciler.executeAction(label: "terminal.toggle") {
//       ... toggle logic (minus suppress/unsuppress) ...
//       return result
//   }
//
// Note: GridTerminalManager is an actor. gridReconciler is a non-isolated class.
// Calling gridReconciler.executeAction from inside the actor should work because
// executeAction is an async method -- the actor can call it without isolation issues.
// The closure runs in the actor's context since it captures self.
//
// ISSUE: GridTerminalManager has non-optional gridReconciler (constructor-injected).
// executeAction is straightforward here.
```

## Design Notes

### Design: `executeAction` on GridReconciler

**Approaches Considered:**
1. **Single generic wrapper** -- one method with options struct for all variants
2. **Two methods** -- `executeAction` (closure) + `beginAction`/`endAction` (session)
3. **Keep setSuppressed public + add convenience** -- doesn't meet plan requirement

**Choice: Approach 2 (Two methods)**

| Criterion | A | B (chosen) | C |
|-----------|---|---|---|
| Interface simplicity | Moderate | Good | Mixed |
| Enforces lifecycle | Yes | Yes | No |
| Handles nudge | Awkward | Clean | Clean |
| Meets "no direct setSuppressed" | Yes | Yes | **No** |

**Rationale:** The plan explicitly requires eliminating all direct `setSuppressed` calls. Approach B cleanly models both the short-lived (most actions) and long-lived (nudge) patterns without forcing awkward constructs.

### Error Handling in `executeAction`

The error reduction hierarchy from aposd-simplifying-complexity:

| Error Condition | Technique | Reasoning |
|-----------------|-----------|-----------|
| Body closure throws | Mask + propagate | Unsuppress and sync even on error, then rethrow. Caller handles error. |
| Suppression underflow | Define out | Start from depth 0 is a bug. Log warning but clamp to 0. |
| Border sync fails | Mask | Sync is best-effort. Log and continue. |
| Focus mismatch in focusWindowByID | Mask after retry | Retry once, accept OS reality. Caller doesn't know about mismatch. |

### Information Hiding

What `executeAction` hides from callers:
- Suppression depth management (increment/decrement/underflow protection)
- Border sync triggering and timing
- Logging of action start/end with duration
- The decision of when to sync vs not sync based on depth

What callers still control:
- Whether to sync borders (parameter)
- What work happens inside the closure
- Error handling of their own domain errors

### Focus Retry Design

The retry in `focusWindowByID` is deliberately simple:
- One retry attempt (not configurable)
- Reads cached `metadata.focusedWindowID` (no OS call)
- Accepts OS reality after retry (no exceptions for permanent mismatch)
- Logs at error level for diagnostics

This follows the "fast path adds negligible latency" constraint. The common case (focus succeeds) adds only a cached value read. The rare case (mismatch) adds one retry + two logs.

### `setSuppressed` Visibility

After refactoring, `setSuppressed` becomes `private`. The method body is inlined into `executeAction`/`beginAction`/`endAction`. This enforces the lifecycle at the API level -- callers cannot bypass it.

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (aposd-designing-deep-modules: two approaches compared, B chosen)
- [x] Error reduction hierarchy applied (aposd-simplifying-complexity)
- [x] Ready for implementation
