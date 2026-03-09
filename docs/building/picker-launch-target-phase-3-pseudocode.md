# Pseudocode: Phase 3 - GridCommandRouter wiring

## Files to Modify
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` (modify `handlePick` method)

## Pseudocode

### GridCommandRouter.swift -- handlePick method

Replace the current handlePick (lines 548-554) with:

```
handlePick(cmd):
    // 1. Capture the user's current focus state BEFORE showing picker
    //    This must happen before show() because the picker steals focus
    spaceID = resolveActiveSpaceID()
    cellID = nil
    if spaceID is not nil:
        cellID = gridState.getFocusedCell(spaceID)

    // 2. Set up the onLaunch callback if we have valid capture
    //    The callback fires when the user selects a launch-type action
    //    It sets a pending target so the reconciler assigns the new window
    //    to the captured cell instead of least-populated
    if spaceID is not nil AND cellID is not nil AND cellID is not empty:
        on MainActor:
            PickerManager.shared.onLaunch = callback(action):
                // Only launch-type actions need pending target
                // PickerManager already filters to launch types before calling
                // so we just set the target unconditionally here
                switch action:
                    case openApp, openDir, openChromeProfile:
                        gridReconciler.setPendingLaunchTarget(
                            PendingLaunchTarget(
                                spaceID: spaceID,
                                cellID: cellID,
                                createdAt: current time
                            )
                        )
                    default:
                        // focusWindow and exec are filtered by PickerManager
                        // but guard here too for safety
                        break

    // 3. Show the picker (must be on MainActor since PickerManager is main-thread)
    on MainActor:
        PickerManager.shared.show()

    return success "picker shown"
```

## Design Notes

### Why capture before show()
The picker panel takes focus when shown. If we captured spaceID/cellID after show(), we would get the picker's context, not the user's pre-picker window focus. The plan explicitly requires this ordering.

### Callback captures spaceID and cellID by value
The `onLaunch` closure captures `spaceID` and `cellID` from the enclosing scope. These are value types (String) so they snapshot the user's focus at pick-invocation time, which is correct even if focus changes while the picker is visible.

### Why the switch in the callback is redundant but safe
PickerManager.handleResult already filters to only call onLaunch for `.openApp`, `.openDir`, `.openChromeProfile`. The switch in the callback is belt-and-suspenders. If PickerManager's filtering ever changes, this prevents setting a pending target for non-launch actions.

### For already-running apps
When the user picks an already-running app, `.openApp` fires, the callback sets a pending target, but then `NSWorkspace.open` just activates the existing app (no new window created). The pending target expires after 15 seconds with no harm. The OS activation triggers normal focusChanged handling in the reconciler.

### MainActor considerations
- `resolveActiveSpaceID()` is async (calls stateManager.getState())
- `gridState.getFocusedCell()` is async (GridState is an actor)
- Both can be called from handlePick's async context without MainActor
- `PickerManager.shared.onLaunch` assignment and `.show()` must be on MainActor
- The onLaunch callback itself runs on main thread (called from PickerManager.handleResult)
- `gridReconciler.setPendingLaunchTarget()` is a synchronous method on a class (not actor), safe to call from main thread

### Lifecycle safety
- `onLaunch` is cleared in `PickerManager.hide()` (Phase 2)
- `pendingLaunchTarget` is one-shot: cleared after first window claim (Phase 1)
- `pendingLaunchTarget` expires after 15 seconds (Phase 1)
- No retain cycles: the callback captures `self` (GridCommandRouter) weakly via `[weak self]`

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed -- single approach is sufficient (method body modification, not a new interface or module)
- [x] Ready for implementation
