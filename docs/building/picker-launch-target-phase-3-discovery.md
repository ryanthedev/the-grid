# Discovery: Phase 3 - GridCommandRouter wiring

## Files Found
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` -- exists, 660 lines
- `grid-server/Sources/GridServer/Grid/GridReconciler.swift` -- exists, has Phase 1 implementation (PendingLaunchTarget, setPendingLaunchTarget, handlePendingLaunchWindow)
- `grid-server/Sources/GridServer/Picker/PickerManager.swift` -- exists, has Phase 2 implementation (onLaunch callback, capturedOnLaunch in handleResult, cleared in hide)
- `grid-server/Sources/GridServer/Picker/PickerModels.swift` -- exists, PickerAction enum at line 136
- `grid-server/Sources/GridServer/Grid/GridState.swift` -- exists, actor, has `getFocusedCell(spaceID:) -> String?` at line 641

## Current State

### handlePick (lines 548-554)
Currently trivial: wraps `PickerManager.shared.show()` in `MainActor.run`, returns `.ok("picker shown")`. No spaceID/cellID capture, no onLaunch callback setup.

### resolveActiveSpaceID (lines 249-252)
Already exists as a private method. Gets wmState from stateManager, calls `gridFocus.findActiveSpaceID(wmState)`. Returns `String?`.

### GridState.getFocusedCell (line 641)
Actor method returning `String?`. Returns `space.focusedCell` or nil if empty.

### PendingLaunchTarget (GridReconciler line 12-16)
Already defined as struct with spaceID, cellID, createdAt fields. `setPendingLaunchTarget` at line 79.

### PickerAction enum (PickerModels line 136)
Cases: `.focusWindow(pid:windowID:)`, `.openApp(bundleID:)`, `.openChromeProfile(profileDir:)`, `.exec(command:)`, `.openDir(dirPath:)`. Launch types are `.openApp`, `.openDir`, `.openChromeProfile`.

### PickerManager.onLaunch (PickerManager line 34)
`var onLaunch: ((PickerAction) -> Void)?` -- already implemented. Captured before hide() in handleResult, called for launch-type actions only. Cleared in hide().

### PickerManager is NOT @MainActor
But documented as "All methods must be called on the main thread". Current handlePick already wraps in `MainActor.run`.

### GridCommandRouter has gridReconciler reference
Already stored as `private let gridReconciler: GridReconciler` (line 43), injected via init.

## Gaps

1. **handlePick does not capture spaceID/cellID** -- needs to resolve active space and focused cell before showing picker
2. **handlePick does not set onLaunch callback** -- needs to wire the callback that calls `gridReconciler.setPendingLaunchTarget`
3. **Phase 4 not yet done** -- `gridReconciler.setApply(gridApply)` and `gridReconciler.setFocus(gridFocus)` not wired in init. Phase 3 only sets the pending target; the reconciler already has `setApply`/`setFocus` methods from Phase 1 but they are not called yet. This is fine -- Phase 3 and Phase 4 are independent.

## Prerequisites
- [x] PendingLaunchTarget struct exists (Phase 1 complete)
- [x] setPendingLaunchTarget method exists (Phase 1 complete)
- [x] PickerManager.onLaunch property exists (Phase 2 complete)
- [x] PickerManager.handleResult calls onLaunch for launch types (Phase 2 complete)
- [x] resolveActiveSpaceID helper exists in GridCommandRouter
- [x] GridState.getFocusedCell exists
- [x] gridReconciler reference available in GridCommandRouter

## Recommendation
BUILD -- All prerequisites from Phase 1 and Phase 2 are in place. The change is small and localized to one method (`handlePick`) in one file (`GridCommandRouter.swift`).
