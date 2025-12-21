# Simplified Border Management Design

## Problem

The current `SimpleBorderManager` crashes due to race conditions when destroying/recreating borders on every focus change. The destroy/recreate pattern is excessive and creates concurrent access to border objects.

## Root Cause

From crash analysis:
- `updateAllBorders()` destroys and recreates ALL borders on every focus change
- Multiple async calls to `updateAllBorders()` can run concurrently
- Thread A holds reference to border in snapshot, Thread B destroys it
- Results in `swift_deallocClassInstance` crash (use-after-free)

## Design Goals

1. **Minimize destroy/recreate cycles** - only when window set changes
2. **Role-based borders** - active + inactive pool, not per-window
3. **Focus as single source of truth** - all state flows from focus
4. **Remove redundant event handlers** - let upstream handle cascading events
5. **Thread safety** - prevent reentrancy and concurrent access

## Data Model

### Before (window-centric)
```swift
private var windowBorders: [UInt32: BorderWindow] = [:]
private var windowStyleTypes: [UInt32: String] = [:]
```

### After (role-centric)
```swift
@MainActor
class SimpleBorderManager {
    private let connectionID: Int32

    // Reentrancy guard
    private var isUpdating: Bool = false

    // Border pool - role-based
    private var activeBorder: BorderWindow?
    private var inactiveBorders: [UInt32: BorderWindow] = [:]  // windowID → border

    // State
    private var activeCellID: String?
    private var currentDisplayUUID: String?
    private var focusedWindowID: UInt32?

    // Cell assignments (from CLI)
    private var cellAssignmentsPerDisplay: [String: [UInt32: String]] = [:]
    private var cellBoundsPerDisplay: [String: [String: CGRect]] = [:]
}
```

### Properties to Remove
- `windowBorders` - replaced by `activeBorder` + `inactiveBorders`
- `windowStyleTypes` - no longer needed, role determines style

## Event Model

### Primary Events (BorderManager handles directly)

| Event | Action | Destroy/Recreate? |
|-------|--------|-------------------|
| Focus changed (different cell) | Destroy old pool, create new pool | Yes |
| Focus changed (same cell) | Reassign active/inactive borders | No |
| Cell assignments received | Rebuild border pool | Yes |
| Config changed | Update styles only | No |
| Window moved | Update border position | No |
| Window destroyed | Remove from pool, destroy border | Partial |
| Display disconnected | Clear display state, destroy borders if current | Partial |

### Upstream Events (BorderManager does NOT handle)

These events trigger focus changes or layout applies upstream. BorderManager reacts to the resulting focus/assignment change.

| Event | Upstream Handling | BorderManager Sees |
|-------|-------------------|-------------------|
| Window minimized | StateManager shifts focus | Focus changed |
| Window deminimized | May trigger layout apply | Focus changed or cell assignments |
| App hidden | StateManager shifts focus | Focus changed |
| App unhidden | May trigger layout apply | Focus changed or cell assignments |
| Space changed | Auto-layout applies | Cell assignments |

### Methods to Remove from SimpleBorderManager
- `handleWindowMinimized`
- `handleWindowDeminimized`
- `handleAppHidden`
- `handleAppUnhidden`
- `handleSpaceChanged`

### Methods to Keep
- `handleDisplayDisconnected` - needed to clean up stale display state

## Thread Safety

### @MainActor with Public/Private Split

Public methods dispatch to main thread, private implementation methods are isolated:

```swift
@MainActor
class SimpleBorderManager {
    // Reentrancy guard - prevents config callback races
    private var isUpdating: Bool = false

    // MARK: - Public API (can be called from any thread)

    func handleFocusChanged(windowID: UInt32) {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        handleFocusChangedImpl(windowID: windowID)
    }

    func setCellAssignments(displayUUID: String, assignments: [UInt32: String]) {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        setCellAssignmentsImpl(displayUUID: displayUUID, assignments: assignments)
    }

    // MARK: - Private Implementation

    private func handleFocusChangedImpl(windowID: UInt32) {
        // ... implementation
    }
}
```

### Why Reentrancy Guard?

Config change callbacks can fire during border operations:
1. Focus change calls `rebuildBorderPool()`
2. Inside rebuild, we destroy borders
3. Config change callback fires (e.g., from file watcher)
4. Callback tries to update borders
5. Without guard: two operations racing on same state

The `isUpdating` flag prevents this by ignoring nested calls.

## Core Operations

### 1. Focus Changed

```swift
private func handleFocusChangedImpl(windowID: UInt32) {
    let (newDisplayUUID, newCellID) = findAssignment(for: windowID)

    guard let cellID = newCellID, let displayUUID = newDisplayUUID else {
        // Window not assigned to any cell - clear all borders
        destroyAllBorders()
        focusedWindowID = nil
        activeCellID = nil
        currentDisplayUUID = nil
        return
    }

    let previousCellID = activeCellID
    let previousFocusedWindow = focusedWindowID

    // Update state
    focusedWindowID = windowID
    activeCellID = cellID
    currentDisplayUUID = displayUUID

    if cellID != previousCellID {
        // DIFFERENT CELL: rebuild entire pool
        rebuildBorderPool()
        logEvent("bdr.cell_change", ["cell": cellID, "wid": windowID])
    } else if windowID != previousFocusedWindow {
        // SAME CELL, DIFFERENT WINDOW: reassign roles
        reassignBorders(previousFocused: previousFocusedWindow)
        logEvent("bdr.focus_change", ["cell": cellID, "wid": windowID])
    }
    // else: same window refocused, no action needed
}
```

### 2. Reassign Borders (same cell focus change)

```swift
private func reassignBorders(previousFocused: UInt32?) {
    guard let newFocused = focusedWindowID else { return }
    let config = BorderConfigManager.shared

    // Step 1: Demote previous active border to inactive
    if let prevWindow = previousFocused, let border = activeBorder {
        updateBorderStyle(border, style: config.inactiveStyle)
        inactiveBorders[prevWindow] = border
        activeBorder = nil
        logEvent("bdr.demote", ["wid": prevWindow])
    }

    // Step 2: Promote border for newly focused window
    if let border = inactiveBorders.removeValue(forKey: newFocused) {
        // Border exists in inactive pool - promote it
        updateBorderStyle(border, style: config.activeStyle)
        activeBorder = border
        logEvent("bdr.promote", ["wid": newFocused])
    } else {
        // No border for this window (edge case: window appeared and auto-focused
        // before CLI sent assignments, then assignments arrived)
        if let border = createBorder(for: newFocused) {
            updateBorderStyle(border, style: config.activeStyle)
            activeBorder = border
            logEvent("warn.bdr.missing", ["wid": newFocused])
        }
    }
}
```

### 3. Rebuild Border Pool (cell change / layout apply)

```swift
private func rebuildBorderPool() {
    // Destroy all existing borders
    destroyAllBorders()

    // Get windows in active cell
    guard let cellID = activeCellID,
          let displayUUID = currentDisplayUUID,
          let assignments = cellAssignmentsPerDisplay[displayUUID] else {
        return
    }

    let windowsInCell = assignments.filter { $0.value == cellID }.map { $0.key }
    let config = BorderConfigManager.shared

    // Create borders for each window
    for windowID in windowsInCell {
        guard let border = createBorder(for: windowID) else { continue }

        let isFocused = (windowID == focusedWindowID)
        let style = isFocused ? config.activeStyle : config.inactiveStyle
        updateBorderStyle(border, style: style)

        if isFocused {
            activeBorder = border
        } else {
            inactiveBorders[windowID] = border
        }

        logEvent("bdr.create", ["wid": windowID, "role": isFocused ? "active" : "inactive"])
    }

    logEvent("bdr.rebuild", [
        "cell": cellID,
        "count": windowsInCell.count,
        "focused": focusedWindowID ?? 0
    ])
}
```

### 4. Destroy All Borders

```swift
private func destroyAllBorders() {
    if let border = activeBorder {
        border.destroy()
        activeBorder = nil
    }

    for (_, border) in inactiveBorders {
        border.destroy()
    }
    inactiveBorders.removeAll()
}
```

### 5. Cell Assignments Received

```swift
private func setCellAssignmentsImpl(displayUUID: String, assignments: [UInt32: String]) {
    cellAssignmentsPerDisplay[displayUUID] = assignments

    // If this affects the current display, rebuild pool
    if displayUUID == currentDisplayUUID {
        // Re-derive active cell from focused window
        if let focused = focusedWindowID, let cellID = assignments[focused] {
            activeCellID = cellID
        }
        rebuildBorderPool()
    } else if currentDisplayUUID == nil {
        // Edge case: new window appeared and focused before any assignments
        // Now assignments arrived - check if focused window is now assigned
        if let focused = focusedWindowID ?? queryCurrentFocusedWindow(),
           let cellID = assignments[focused] {
            focusedWindowID = focused
            activeCellID = cellID
            currentDisplayUUID = displayUUID
            rebuildBorderPool()
        }
    }
}
```

### 6. Window Moved

```swift
func handleWindowMoved(windowID: UInt32, frame: CGRect) {
    // Find which border tracks this window
    if focusedWindowID == windowID, let border = activeBorder {
        border.update(targetFrame: frame)
    } else if let border = inactiveBorders[windowID] {
        border.update(targetFrame: frame)
    }
    // else: window not in active cell, ignore
}
```

### 7. Window Destroyed

```swift
func handleWindowDestroyed(windowID: UInt32) {
    // Remove from inactive pool
    if let border = inactiveBorders.removeValue(forKey: windowID) {
        border.destroy()
        logEvent("bdr.destroy", ["wid": windowID, "role": "inactive"])
        return
    }

    // If it was the active border, destroy it
    // Focus will shift and trigger handleFocusChanged
    if focusedWindowID == windowID, let border = activeBorder {
        border.destroy()
        activeBorder = nil
        focusedWindowID = nil
        logEvent("bdr.destroy", ["wid": windowID, "role": "active"])
    }
}
```

### 8. Config Changed (style update only)

```swift
func handleConfigChanged() {
    let config = BorderConfigManager.shared

    // Update active border style
    if let border = activeBorder {
        updateBorderStyle(border, style: config.activeStyle)
    }

    // Update inactive border styles
    for (_, border) in inactiveBorders {
        updateBorderStyle(border, style: config.inactiveStyle)
    }

    logEvent("bdr.config_change", [:])
}
```

### 9. Display Disconnected

```swift
func handleDisplayDisconnected(displayUUID: String) {
    // Remove cached assignments for this display
    cellAssignmentsPerDisplay.removeValue(forKey: displayUUID)
    cellBoundsPerDisplay.removeValue(forKey: displayUUID)

    // If this was the active display, clear state and borders
    if currentDisplayUUID == displayUUID {
        destroyAllBorders()
        currentDisplayUUID = nil
        activeCellID = nil
        // Keep focusedWindowID - focus will shift and trigger new state
    }

    logEvent("bdr.display_disconnect", ["uuid": displayUUID])
}
```

## Helper Methods

### Create Border

```swift
private func createBorder(for windowID: UInt32) -> BorderWindow? {
    let border = BorderWindow(connectionID: connectionID, targetWindowID: windowID)
    guard border.create() else {
        logEvent("err.bdr.create", ["wid": windowID])
        return nil
    }

    // Get initial position
    var frame = CGRect.zero
    guard SLSGetWindowBounds(connectionID, windowID, &frame) == .success else {
        border.destroy()
        logEvent("err.bdr.bounds", ["wid": windowID])
        return nil
    }

    border.update(targetFrame: frame)
    return border
}
```

### Update Border Style

```swift
private func updateBorderStyle(_ border: BorderWindow, style: BorderStyle?) {
    border.updateStyle(style: style, styleType: style != nil ? "updated" : "hidden")
}
```

### Find Assignment

```swift
private func findAssignment(for windowID: UInt32) -> (displayUUID: String?, cellID: String?) {
    for (displayUUID, assignments) in cellAssignmentsPerDisplay {
        if let cellID = assignments[windowID] {
            return (displayUUID, cellID)
        }
    }
    return (nil, nil)
}
```

### Query Current Focused Window

```swift
private func queryCurrentFocusedWindow() -> UInt32? {
    // Query SkyLight for currently focused window
    // Used as fallback when focus state is unknown
    var focusedWindow: UInt32 = 0
    guard SLSGetFocusedWindow(connectionID, &focusedWindow) == .success else {
        return nil
    }
    return focusedWindow > 0 ? focusedWindow : nil
}
```

## Logging

### Event Codes

| Code | Meaning |
|------|---------|
| `bdr.cell_change` | Focus moved to different cell, rebuilt pool |
| `bdr.focus_change` | Focus moved within cell, reassigned borders |
| `bdr.rebuild` | Border pool rebuilt (cell change, assignments) |
| `bdr.create` | Single border created |
| `bdr.destroy` | Single border destroyed |
| `bdr.promote` | Border promoted from inactive to active |
| `bdr.demote` | Border demoted from active to inactive |
| `bdr.config_change` | Config changed, styles updated |
| `bdr.display_disconnect` | Display disconnected, cleaned up state |
| `warn.bdr.missing` | Border not found in pool during reassign (edge case) |
| `err.bdr.create` | Failed to create border window |
| `err.bdr.bounds` | Failed to get window bounds |

### Log Format

```json
{"t":1702840000,"ev":"bdr.cell_change","cell":"A","wid":12345}
{"t":1702840001,"ev":"bdr.focus_change","cell":"A","wid":12346}
{"t":1702840002,"ev":"bdr.rebuild","cell":"A","count":3,"focused":12346}
{"t":1702840003,"ev":"bdr.promote","wid":12346}
{"t":1702840004,"ev":"bdr.demote","wid":12345}
```

## BorderEvents Changes

Update `BorderEvents.swift` to only route relevant events:

### Keep
- `handleWindowFocused` → `SimpleBorderManager.handleFocusChanged`
- `handleWindowMoved` → `SimpleBorderManager.handleWindowMoved`
- `handleWindowDestroyed` → `SimpleBorderManager.handleWindowDestroyed`
- `handleDisplayDisconnected` → `SimpleBorderManager.handleDisplayDisconnected`

### Remove
- `handleWindowCreated` (already no-op)
- `handleWindowMinimized` (focus change handles)
- `handleWindowDeminimized` (focus change handles)
- `handleAppHidden` (focus change handles)
- `handleAppUnhidden` (focus change handles)
- `handleSpaceChanged` (layout apply handles)

## Edge Cases Handled

### 1. New Window Auto-Focus Before Assignments
**Scenario:** User launches app, window appears and auto-focuses before CLI sends assignments.
**Solution:** `setCellAssignmentsImpl` checks if focused window is now assigned and rebuilds.

### 2. Config Change During Border Operation
**Scenario:** Config file changes while borders are being rebuilt.
**Solution:** `isUpdating` flag prevents reentrancy.

### 3. Display Disconnect
**Scenario:** External monitor unplugged while borders displayed.
**Solution:** `handleDisplayDisconnected` cleans up stale state.

### 4. Rapid Focus Changes
**Scenario:** User rapidly switches between windows in same cell.
**Solution:** `reassignBorders` just swaps roles without destroy/recreate.

## Migration Notes

1. Remove old `windowBorders` and `windowStyleTypes` properties
2. Add `isUpdating` reentrancy guard
3. Add `activeBorder` and `inactiveBorders` properties
4. Remove handler methods: `handleWindowMinimized`, `handleWindowDeminimized`, `handleAppHidden`, `handleAppUnhidden`, `handleSpaceChanged`
5. Keep `handleDisplayDisconnected` (simplified)
6. Update BorderEvents to stop routing removed events
7. Update logging to use new event codes
8. Change `handleConfigChanged` to update styles only (no rebuild)
9. Add `@MainActor` to SimpleBorderManager
10. No backwards compatibility needed - clean break

## Summary

| Aspect | Before | After |
|--------|--------|-------|
| Border model | Per-window | Role-based (active + inactive pool) |
| Focus change (same cell) | Destroy/recreate all | Reassign roles (promote/demote) |
| Focus change (diff cell) | Destroy/recreate all | Destroy/recreate (correct) |
| Config change | Destroy/recreate all | Update styles only |
| Event handlers | 10+ methods | 5 methods |
| Thread safety | None (race condition) | @MainActor + reentrancy guard |
| Logging | Verbose, per-operation | Semantic events |
