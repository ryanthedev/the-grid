# Pseudocode: Phase 2 - PickerManager onLaunch callback

## Files to Modify
- `grid-server/Sources/GridServer/Picker/PickerManager.swift`

## Pseudocode

### PickerManager.swift

#### New property (add alongside other instance vars)

```
// Optional callback invoked when a launch-type action is selected
// Set by GridCommandRouter before show(), cleared in hide()
var onLaunch: ((PickerAction) -> Void)?
```

#### Modified: handleResult(_:)

```
handleResult(result):
  // Capture callbacks before hide() clears them
  capture pendingRPCContinuation (existing pattern)
  clear pendingRPCContinuation (existing)
  capture onLaunch callback into local variable

  hide()  // this nils out onLaunch on the instance

  if result is .selected(item):
    record history, save, log (existing)

    // Parse the action from item metadata
    let action = PickerAction.from(metadata: item.metadata)

    // If action is a launch type, notify the callback
    if action is launch type (.openApp, .openChromeProfile, .openDir):
      call captured onLaunch callback with action

    // Execute the action (existing - opens app, etc.)
    executeAction(for: item)

  // Resume RPC continuation (existing)
```

Key change: `executeAction(for:)` currently parses the action internally.
We need to parse the action in `handleResult` so we can both check its type
for the callback AND pass the item to `executeAction`. Two options:

**Option A:** Extract action parsing into handleResult, call onLaunch, then
pass to executeAction. This duplicates the PickerAction.from() call or
requires refactoring executeAction to accept a PickerAction directly.

**Option B (chosen):** Parse action once in handleResult. Call onLaunch for
launch types. Then call ActionExecutor.execute(action) directly (skip the
executeAction wrapper since we already have the parsed action). Log the
"no action" error in handleResult if parsing fails.

```
handleResult(result):
  let capturedContinuation = pendingRPCContinuation
  pendingRPCContinuation = nil
  let capturedOnLaunch = onLaunch

  hide()

  switch result:
  case .selected(item):
    history.recordSelection(item.id)
    history.save()
    log "pick.selected"

    // Parse action from metadata
    guard let action = PickerAction.from(metadata: item.metadata) else:
      log "pick.err.noaction"
      break

    // Notify launch callback for launch-type actions only
    if capturedOnLaunch is not nil:
      switch action:
      case .openApp, .openDir, .openChromeProfile:
        capturedOnLaunch(action)
      case .focusWindow, .exec:
        // Not launch actions -- skip callback
        break

    // Execute the action
    ActionExecutor.execute(action)

  case .cancelled:
    break

  // Resume RPC continuation
  if capturedContinuation is not nil:
    capturedContinuation.resume(returning: result)
```

#### Modified: hide()

```
hide():
  // ... existing guard, cancel discovery, orderOut, RPC continuation ...

  // Clear launch callback (safety net -- handleResult captures before hide)
  onLaunch = nil

  log "pick.hide"
```

#### Removed: executeAction(for:) private method

The `executeAction(for:)` wrapper is no longer needed since handleResult
now parses the action directly and calls `ActionExecutor.execute(action)`.
Remove the private method to avoid dead code.

## Design Notes

**Ordering fix:** The plan says to call onLaunch "after executeAction" but
hide() runs before executeAction and would nil out onLaunch. We follow the
existing `pendingRPCContinuation` capture pattern: save the callback to a
local before hide(), then use the local after hide(). This is safe because
everything runs on main thread (no concurrency race).

**onLaunch fires before ActionExecutor.execute:** This is correct -- the
callback sets the pending launch target on GridReconciler, which needs to
be in place BEFORE the app actually launches and creates a window. The
ActionExecutor.execute call triggers the launch asynchronously.

**executeAction removal:** Inlining the action parsing into handleResult
is cleaner than parsing twice. The private helper was a one-liner wrapper
that just parsed and dispatched.

**Thread safety:** PickerManager is a main-thread class with
dispatchPrecondition checks. The onLaunch callback runs on main thread.
If the callback needs async work (e.g., setting pending target on
GridReconciler actor), it spawns a Task internally -- that is the
caller's responsibility (Phase 3).

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed -- ordering issue identified and resolved
- [x] Ready for implementation
