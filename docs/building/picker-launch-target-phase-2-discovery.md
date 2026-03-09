# Discovery: Phase 2 - PickerManager onLaunch callback

## Files Found
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Picker/PickerManager.swift` - exists, 251 lines
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Picker/PickerModels.swift` - exists, 177 lines (contains PickerAction enum)
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Picker/ActionExecutor.swift` - exists, 151 lines

## Current State

**PickerManager** is a main-thread singleton class (not actor). Key flow:
1. `show()` creates/shows the picker window, starts async discovery
2. User selects an item -> `PickerWindow.onResult` fires -> `handleResult(_:)`
3. `handleResult` calls `hide()` first (clears UI), then `executeAction(for:)` for `.selected` items
4. `executeAction` parses `PickerAction` from item metadata via `PickerAction.from(metadata:)`, then calls `ActionExecutor.execute(action)`

**PickerAction** enum (in PickerModels.swift) has 5 cases:
- `.focusWindow(pid:windowID:)` - NOT a launch action (focuses existing window)
- `.openApp(bundleID:)` - LAUNCH action
- `.openChromeProfile(profileDir:)` - LAUNCH action
- `.exec(command:)` - NOT a launch action (unknown behavior)
- `.openDir(dirPath:)` - LAUNCH action

**Critical ordering in handleResult:**
- `hide()` is called BEFORE `executeAction(for:)` (line 149)
- The plan says clear `onLaunch = nil` in `hide()`
- This means `onLaunch` would be cleared BEFORE `executeAction` runs
- **FIX NEEDED:** Must call `onLaunch?(action)` BEFORE `hide()`, or capture the callback before `hide()` clears it

Looking more carefully at `handleResult`:
- Line 145-146: It already captures `pendingRPCContinuation` before `hide()` clears it
- Same pattern applies: capture `onLaunch` before `hide()`, then call it after action parsing

## Gaps

1. **Ordering issue:** Plan says "In `handleResult`, after `executeAction(for: item)`, extract the action and call `onLaunch?(action)`" but `hide()` runs first and would nil out `onLaunch`. Must capture `onLaunch` before `hide()` (same pattern as `pendingRPCContinuation`).
2. Plan says "In `hide()`, clear `onLaunch = nil`" -- this is fine as a cleanup mechanism, but the captured reference in `handleResult` ensures the callback still fires for the current selection.

## Prerequisites
- [x] PickerManager.swift exists
- [x] PickerAction enum exists with all 5 cases documented
- [x] `handleResult` flow understood
- [x] `hide()` ordering issue identified and solvable
- [x] Phase 1 (GridReconciler pending launch target) completed

## Recommendation
BUILD - with the ordering fix noted above (capture onLaunch before hide, same as pendingRPCContinuation pattern).
