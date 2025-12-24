# Geometric Space Derivation

## Problem

macOS reports incorrect `spaces` array for windows. Example:
- Spotify (wid 132) reports `spaces: [64]`
- But geometrically it's on DeskPad display (UUID: 89ED320F)
- DeskPad's `currentSpaceID` is 41

This causes focus navigation to target the wrong display/space.

## Solution

Replace the macOS-reported `spaces` array with a geometrically-derived value:

```
window.displayUUID → lookup display → display.currentSpaceID → window.spaces
```

## Implementation

### New Helper Method

Add to `StateManager.swift`:

```swift
/// Derive window's space from its geometric displayUUID
/// Falls back to original macOS-reported spaces if geometric detection fails
/// IMPORTANT: Must be called AFTER computeDisplayUUID() sets window.displayUUID
private func deriveSpaceFromDisplay(for window: inout WindowState, originalSpaces: [UInt64]) {
    // Don't derive for sticky windows - they should be on all spaces
    if let isSticky = mssClient.isWindowSticky(window.id), isSticky {
        window.spaces = getAllUserSpaceIDs()
        return
    }

    if let displayUUID = window.displayUUID,
       let display = state.displays.first(where: { $0.uuid == displayUUID }),
       let spaceID = display.currentSpaceID {
        window.spaces = [spaceID]
    } else {
        // Fallback: keep original macOS-reported spaces
        window.spaces = originalSpaces
        if originalSpaces.isEmpty {
            jlog("dbg.spaces", msg: "both geometric and macOS space detection failed", data: [
                "wid": window.id,
                "displayUUID": window.displayUUID ?? "nil"
            ])
        }
    }
}
```

### Call Sites (6 total)

Update all locations where `displayUUID` is computed. Pattern:

```swift
let originalSpaces = window.spaces
window.displayUUID = computeDisplayUUID(for: window)
deriveSpaceFromDisplay(for: &window, originalSpaces: originalSpaces)
```

#### 1. `refreshWindows()` - line ~879

Initial window enumeration during server startup.

```swift
let originalSpaces = windowState.spaces
windowState.displayUUID = computeDisplayUUID(for: windowState)
deriveSpaceFromDisplay(for: &windowState, originalSpaces: originalSpaces)
```

#### 2. `updateWindowFromPoll()` - line ~1058

Polling updates existing window frame/properties.

```swift
let originalSpaces = window.spaces
window.displayUUID = computeDisplayUUID(for: window)
deriveSpaceFromDisplay(for: &window, originalSpaces: originalSpaces)
```

#### 3. `addWindowFromPoll()` - line ~1112

Polling discovers a new window.

```swift
let originalSpaces = window.spaces
window.displayUUID = computeDisplayUUID(for: window)
deriveSpaceFromDisplay(for: &window, originalSpaces: originalSpaces)
```

#### 4. `handleWindowCreated()` - line ~1161

AX observer reports new window created.

```swift
let originalSpaces = window.spaces
window.displayUUID = computeDisplayUUID(for: window)
deriveSpaceFromDisplay(for: &window, originalSpaces: originalSpaces)
```

#### 5. `handleWindowMoved()` - line ~1220

AX observer reports window moved.

```swift
let originalSpaces = window.spaces
window.displayUUID = computeDisplayUUID(for: window)
deriveSpaceFromDisplay(for: &window, originalSpaces: originalSpaces)
```

#### 6. `handleWindowResized()` - line ~1238

AX observer reports window resized.

```swift
let originalSpaces = window.spaces
window.displayUUID = computeDisplayUUID(for: window)
deriveSpaceFromDisplay(for: &window, originalSpaces: originalSpaces)
```

### Edge Cases

| Scenario | Behavior |
|----------|----------|
| Sticky window ("All Desktops") | Keep all user space IDs, don't derive |
| Window center outside all displays | Keep original macOS `spaces` |
| Minimized window | Keep existing displayUUID/spaces (don't recompute) |
| Display disconnected | Windows on that display keep last-known spaces |
| Window spans multiple displays | Use center point to pick one display |
| Both detection methods fail | Keep empty `[]`, log warning |

### Debug Logging

Update existing `dbg.displayUUID_result` log to include derived space:

```swift
jlog("dbg.displayUUID_result", data: [
    "wid": windowState.id,
    "app": windowState.appName ?? "?",
    "displayUUID": windowState.displayUUID ?? "nil",
    "derivedSpace": windowState.spaces.first ?? 0,
    "originalSpaces": originalSpaces
])
```

### Post-Implementation Review

After verifying the geometric derivation works correctly:
1. Consider removing redundant `updateWindowSpaces()` calls at lines 1064, 1115, 1166, 1225
2. Or modify `updateWindowSpaces()` to log discrepancies between API-reported and geometrically-derived spaces
3. Remove debug logging added during investigation

## Testing

1. **Basic verification:**
   - Run `make run` from worktree
   - Check Spotify: `thegrid dump | jq '.windows["132"].spaces'` should return `[41]`

2. **Focus navigation:**
   - Test focus up/down between displays
   - Should now navigate to correct displays

3. **Window movement:**
   - Move a window between displays
   - Spaces should update correctly

4. **Sticky windows:**
   - Verify windows set to "All Desktops" have all user space IDs
   - Should NOT be affected by geometric derivation

5. **Edge cases:**
   - Window at display boundary - verify stable behavior
   - Connect/disconnect display while windows open
   - Minimized window spaces don't change on display reconfig

## Files Modified

- `grid-server/Sources/GridServer/StateManager.swift`

## Dependency Note

`deriveSpaceFromDisplay()` depends on `computeDisplayUUID()` having already set `window.displayUUID`. Always call them in sequence:

1. `computeDisplayUUID()` first
2. `deriveSpaceFromDisplay()` second
