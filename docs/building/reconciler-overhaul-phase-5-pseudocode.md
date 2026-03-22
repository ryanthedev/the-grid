# Pseudocode: Phase 5 - Resilience

## Files to Create/Modify

- `grid-server/Sources/GridServer/Grid/GridReconciler.swift` -- wake gate, display connect/disconnect

## Design Notes

### Design: Wake Gate

**Approaches considered:**

A. `Bool` flag `isWakeValidating` -- commands check the flag and skip or return error
B. `Task<Void, Never>?` stored as `wakeValidationTask` -- commands `await` the task
C. `AsyncSemaphore` or custom gate actor -- heavyweight, external dependency

**Comparison:**

| Criterion | A (Bool flag) | B (Task await) | C (Semaphore) |
|-----------|--------------|----------------|---------------|
| Commands blocked, not dropped | No (skip/error loses the command) | Yes (await resumes naturally) | Yes |
| Complexity | Low | Low | High |
| Integration with existing patterns | Poor | Good (existing code uses Task/await) | Poor |
| Race safety | Weak (check-then-act gap) | Strong (Swift concurrency structured) | Strong |
| Caller boilerplate | Minimal | 1 await line | Minimal |

**Choice: B (Task await).** Commands `await` the in-flight validation task, then proceed normally. No commands are dropped. The Task reference is nil during normal operation (fast path: no suspend). Clearing the reference when the task finishes is automatic via the task completion callback.

**Interface:** `func awaitWakeCompletion() async` on GridReconciler. Callers: GridCommandRouter before executing any command.

**Depth check:**
- Interface: 1 method, called once per command
- Hidden: task storage, nil check, optional await
- Common case complexity: trivial (nil check, no suspend -- wake events are rare)

### Design: Display Connect/Disconnect Pruning

**Approach for disconnect:** When a display disconnects, identify its spaces from the last wmState snapshot, then remove all windows assigned to cells in those spaces. Do NOT remove the spaces from GridState -- macOS may keep the space IDs alive for disconnected displays, and `pruneDeadSpaces()` in StateValidator handles that correctly.

**Rationale:** Aggressive pruning (removing spaces) risks data loss if the display reconnects quickly. Conservative pruning (windows only) prevents zombies from accumulating in cells while leaving the layout intact for reconnect.

**Approach for reconnect:** Call `gridApply?.refreshAllDisplays(displayFilter: displayUUID)` -- this already handles the full flow: find active space, check layout, reapply positions, sync borders. No new logic needed.

### Design: Ghostty / Window Creation Bursts

**No new code needed.** `isTileable()` already filters zero-size windows (< 100px) before any assignment or border operation. The existing guard in `handleWindowCreated()` exits early for all burst windows. Event storms (for borders/state) do not occur. The log noise from `reconcile.win.create.bail` events is acceptable and useful for debugging.

---

## Pseudocode

### GridReconciler.swift

#### New property: wakeValidationTask

```
// Guards user commands during sleep/wake recovery.
// Non-nil only while handleSystemWake is in progress.
// Commands call awaitWakeCompletion() to wait for this to finish.
private var wakeValidationTask: Task<Void, Never>? = nil
```

#### New public method: awaitWakeCompletion()

```
// awaitWakeCompletion
//
// Called by GridCommandRouter before processing any command.
// If wake validation is in progress, suspends the caller until it finishes.
// Fast path (common case): wakeValidationTask is nil, returns immediately.
//
// Input: none
// Output: none (resumes when wake is complete)
// Side effects: none (read-only check of wakeValidationTask)

func awaitWakeCompletion() async
    if wakeValidationTask is not nil
        await wakeValidationTask
    end if
    // Validation complete (or was never running)
```

#### Modified: handleSystemWake()

```
// handleSystemWake
//
// Enhanced wake handler. Wraps the validation work in a tracked Task
// so that commands can wait for completion via awaitWakeCompletion().
//
// Previous behavior:
//   1. Migrate space IDs
//   2. Validate state (prune zombies, dedup, prune dead spaces)
//   3. Sync borders for current space
//
// New behavior: same steps, but stored in wakeValidationTask so commands
// can await completion. Task reference cleared on completion.

private func handleSystemWake() async
    guard stateManager and gridState are present else return

    jlog("reconcile.wake.start")

    // Capture wmState once for consistency across all steps
    wmState = await stateManager.getState()

    // Store the validation work as a tracked task
    // (self is captured weakly to avoid retain cycles)
    wakeValidationTask = Task {
        // Step 1: Migrate space IDs (macOS may reassign after sleep)
        Build displaySpaces map: displayUUID -> sorted spaceID list from wmState
        migrated = await gridState.migrateSpaceIDs(currentDisplaySpaces: displaySpaces)
        if migrated
            jlog("reconcile.wake.migrated")
        end if

        // Step 2: Full state validation after migration
        // Re-fetch wmState after migration so validator sees correct space IDs
        freshWmState = await stateManager.getState()
        await stateValidator?.validate(wmState: freshWmState)

        // Step 3: Sync borders for current space
        await syncBordersForCurrentSpace()

        jlog("reconcile.wake.done")

        // Clear the task reference so subsequent commands pass through immediately
        // Note: This runs inside the Task body; cleared after awaiting completes
        wakeValidationTask = nil
    }

    // Await the task here so handleSystemWake() itself doesn't return
    // until everything is done. This keeps the existing "wake is synchronous
    // from the event handler's perspective" guarantee.
    await wakeValidationTask
```

**Note on wake timing uncertainty:** macOS may fire the `systemWoke` event before display/space metadata is fully updated in wmState. The existing `migrateSpaceIDs()` call handles the space ID shift. The validator's `pruneDeadSpaces()` uses wmState.spaces as authoritative -- if wmState is slightly stale post-wake, it may not yet reflect the final live set. This is acceptable: the periodic 30s timer will catch any remaining orphans. The wake handler is best-effort, not guaranteed-complete.

#### Modified: handle() -- add displayConnected case

```
// In the switch statement in handle(), add:

case .displayConnected(let displayUUID):
    await handleDisplayConnected(displayUUID)
```

#### New private method: handleDisplayConnected()

```
// handleDisplayConnected
//
// Triggered when a display is reconnected (e.g., external monitor plugged back in).
// GridState retains the layout and window assignments from before disconnect.
// This handler re-syncs borders and reapplies layouts for the reconnected display.
//
// Input: displayUUID -- UUID of reconnected display
// Output: none
// Side effects: triggers refreshAllDisplays filtered to reconnected display

private func handleDisplayConnected(_ displayUUID: String) async
    jlog("reconcile.display.connect", data: ["display": displayUUID])

    // Short delay allows macOS to stabilize space/window state after reconnect
    // before we query it. Without this, wmState may not yet reflect new spaces.
    // 500ms is enough for display negotiation; short enough to feel instant.
    try? await Task.sleep(for: .milliseconds(500))

    // Reapply layouts and sync borders for the reconnected display.
    // refreshAllDisplays handles: find active space, check layout,
    // reapply window positions, sync borders. Filter limits to just this display.
    let errors = await gridApply?.refreshAllDisplays(displayFilter: displayUUID) ?? []

    if !errors.isEmpty
        jlog("warn.reconcile.display.connect.errors",
             data: ["display": displayUUID, "errorCount": errors.count])
    end if
```

#### Modified: handleDisplayDisconnected()

```
// handleDisplayDisconnected
//
// Enhanced disconnect handler. Previous behavior only cleaned up borders.
// New behavior also prunes GridState window assignments for spaces on the
// disconnected display, preventing zombies from accumulating.
//
// Why windows but not spaces: macOS may keep space IDs alive for
// disconnected displays. pruneDeadSpaces() (StateValidator) handles
// space cleanup when the IDs are actually gone. Removing windows eagerly
// prevents zombie assignments in cells while preserving layout config.
//
// Input: displayUUID -- UUID of disconnected display
// Output: none
// Side effects: border cleanup (existing), GridState window pruning (new)

private func handleDisplayDisconnected(_ displayUUID: String) async
    jlog("reconcile.display.disconnect", data: ["display": displayUUID])

    // Existing: clean up border state for this display
    simpleBorderManager?.handleDisplayDisconnected(displayUUID: displayUUID)

    // New: prune GridState window assignments for spaces on this display
    guard gridState and stateManager are present else return
    wmState = await stateManager.getState()

    // Find all space IDs that belong to this display in the current wmState
    let affectedSpaceIDs = find spaces in wmState.spaces where space.displayUUID == displayUUID
    // Also check wmState.displays for currentSpaceID if spaces map is incomplete
    // (belt-and-suspenders: some spaces may not appear in wmState.spaces directly)

    if affectedSpaceIDs is empty
        jlog("reconcile.display.disconnect.no_spaces", data: ["display": displayUUID])
        return
    end if

    // For each affected space, remove all window assignments.
    // Windows will reappear via windowCreated events when the display reconnects
    // and the user's apps are still running.
    for spaceID in affectedSpaceIDs
        windowIDs = await gridState.getWindowAssignments(spaceID: spaceID).values.flattened
        for windowID in windowIDs
            await gridState.removeWindow(windowID, fromSpace: spaceID)
            jlog("reconcile.display.disconnect.prune",
                 data: ["wid": windowID, "space": spaceID, "display": displayUUID])
        end for
    end for
```

**Note on space pruning decision:** We remove windows but keep space records (layout ID, column/row ratios, stack modes). This means when the display reconnects and `refreshAllDisplays()` runs, it finds the existing layout and applies it to whatever windows are currently on that space. This is the correct behavior -- the user's layout preferences survive disconnect/reconnect.

### GridCommandRouter.swift

#### Modified: route() or the command dispatch method

```
// Before executing any grid command, await wake completion.
// This is the gate that ensures commands see post-migration, post-validation state.
//
// Location: at the top of the method that dispatches parsed commands
// (the method that switches on domain+action and calls into gridFocus, gridWindowMove, etc.)

func routeCommand(_ command: ParsedCommand) async -> CommandResult
    // Wait for any in-progress wake validation to finish.
    // Fast path during normal operation: returns immediately (task is nil).
    await gridReconciler.awaitWakeCompletion()

    // ... existing command dispatch logic follows unchanged ...
```

**Note:** `awaitWakeCompletion()` is called once per command, not per IPC request (some requests may not go through GridCommandRouter). The MessageHandler dispatches via `GridCommandRouter`, so this covers all BFD hotkey and CLI commands.

---

## What Is NOT Changing

These items from the plan scope are confirmed already handled by prior phases:

- **Ghostty window burst handling:** `isTileable()` filters zero-size (< 100px) windows before any assignment. No debounce needed. Confirmed HIGH-confidence assumption holds.
- **App crash recovery:** StateValidator (Phase 1) prunes zombie windows within 30s via SLSGetWindowBounds. Already implemented and running.
- **Core reconciler/fencing:** Phase 2 -- out of scope.
- **Border model:** Phase 4 -- out of scope.

---

## PRE-GATE Status

- [x] Discovery complete
- [x] Pseudocode complete
- [x] Assumption verified (Ghostty zero-size filter confirmed working)
- [x] Design reviewed (wake gate, display handlers)
- [ ] Ready for implementation
