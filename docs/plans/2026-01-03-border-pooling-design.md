# Border Pooling Design

**Date**: 2026-01-03
**Status**: Proposed
**Goal**: Eliminate expensive `SLSNewWindow` calls during cell changes by reusing border windows

## Problem

Profiling revealed that `SLSNewWindow` accounts for 34% of active CPU time during focus changes. The current `rebuildBorderPool()` destroys and recreates ALL border windows on every cell change, even though the `BorderWindow.retarget()` capability exists to repoint a border to a different window without destroying it.

### Profiling Data

| Operation | Avg | P95 | Max |
|-----------|-----|-----|-----|
| ping | 16.6ms | 19.9ms | 20.4ms |
| dump | 65.4ms | 112.0ms | 408.5ms |
| focus | 94.8ms | 124.8ms | 167.9ms |

CPU breakdown during load:
- 83% idle (waiting for events)
- 16% active work
  - 34% in `SLSNewWindow` (creating border windows)
  - 42% in `BorderRenderer.draw` (redrawing borders)

## Solution

Instead of destroying borders on cell change, release them to a free pool. When borders are needed, acquire from the pool first (using `retarget()`), only creating new borders when the pool is empty.

## Data Model

### Current State

```swift
private var activeBorder: BorderWindow?
private var inactiveBorders: [UInt32: BorderWindow] = [:]
```

### New State

```swift
private var activeBorder: BorderWindow?
private var inactiveBorders: [UInt32: BorderWindow] = [:]
private var freePool: [BorderWindow] = []  // NEW

// Cap for lazy cleanup. 10 is sufficient because:
// - Typical cell has 1-4 windows
// - Users rarely have more than 10 windows visible across all cells
// - Each BorderWindow is ~1KB (overlay window handle + style state)
private let maxFreePoolSize = 10
```

### Invariant

A `BorderWindow` is in exactly ONE of:
- `activeBorder`
- `inactiveBorders[windowID]`
- `freePool`
- Being destroyed (transitional)

## Core Operations

### Acquiring a Border

Returns a tuple indicating whether the border came from the pool (for metrics).

```swift
private func acquireBorder(for windowID: UInt32) -> (border: BorderWindow, fromPool: Bool)? {
    // 1. Try to get from free pool (avoids SLSNewWindow)
    if let border = freePool.popLast() {
        guard border.retarget(to: windowID) else {
            // Retarget failed - border is now invalid, destroy and retry
            // Note: retarget() failure leaves border in undefined state
            border.destroy()
            // Recursion bounded by maxFreePoolSize (max 10 calls)
            return acquireBorder(for: windowID)
        }
        return (border, fromPool: true)
    }

    // 2. Pool empty - create new (expensive)
    guard let border = createBorder(for: windowID) else {
        return nil
    }
    return (border, fromPool: false)
}
```

### Releasing a Border

```swift
private func releaseBorder(_ border: BorderWindow) {
    border.hide(reason: "released_to_pool")

    // Add to pool if under cap
    if freePool.count < maxFreePoolSize {
        freePool.append(border)
    } else {
        // Pool full - destroy excess
        border.destroy()
    }
}
```

### Modified rebuildBorderPool()

```swift
private func rebuildBorderPool(source: String) {
    // Release existing borders TO POOL (not destroy)
    if let border = activeBorder {
        releaseBorder(border)
        activeBorder = nil
    }
    for (_, border) in inactiveBorders {
        releaseBorder(border)
    }
    inactiveBorders.removeAll()

    // Get windows in active cell
    guard let cellID = activeCellID,
          let displayUUID = currentDisplayUUID,
          let assignments = cellAssignmentsPerDisplay[displayUUID] else {
        return
    }

    let windowsInCell = assignments.filter { $0.value == cellID }.map { $0.key }
    let config = BorderConfigManager.shared

    var acquiredFromPool = 0
    var newlyCreated = 0

    // Acquire borders for each window (from pool first)
    for windowID in windowsInCell {
        guard let (border, fromPool) = acquireBorder(for: windowID) else { continue }

        if fromPool {
            acquiredFromPool += 1
        } else {
            newlyCreated += 1
        }

        let isFocused = (windowID == focusedWindowID)
        let style = isFocused ? config.activeStyle : config.inactiveStyle
        updateBorderStyle(border, style: style, isActive: isFocused)

        if isFocused {
            activeBorder = border
        } else {
            inactiveBorders[windowID] = border
        }
    }

    JSONLogger.shared.log("bdr.rebuild", data: [
        "source": source,
        "cell": cellID,
        "count": windowsInCell.count,
        "fromPool": acquiredFromPool,
        "created": newlyCreated,
        "poolSize": freePool.count
    ])
}
```

## BorderWindow Changes

Modify `retarget(to:)` to return `Bool` for success/failure.

**Important:** On failure, the border is left in an undefined state (`targetWindowID` may be
updated but bounds/space not). Callers MUST destroy the border on failure - do not attempt reuse.

```swift
/// Re-target this border to track a different window.
/// - Returns: true on success, false on failure (border must be destroyed)
func retarget(to newTargetID: UInt32) -> Bool {
    let currentWindowID = windowID
    guard currentWindowID != 0 else { return false }
    guard newTargetID != targetWindowID else { return true }  // Already targeting

    let oldTarget = targetWindowID
    targetWindowID = newTargetID  // Updated before validation - see note above

    // Get new target's frame
    var frame = CGRect.zero
    guard SLSGetWindowBounds(connectionID, newTargetID, &frame) == .success else {
        JSONLogger.shared.log("err.bdr.retarget", data: [
            "wid": currentWindowID,
            "oldTarget": oldTarget,
            "newTarget": newTargetID,
            "reason": "no_bounds"
        ])
        return false
    }

    update(targetFrame: frame)
    moveToTargetSpace()

    if isVisible {
        _ = SLSOrderWindow(connectionID, currentWindowID, -1, newTargetID)
    }

    JSONLogger.shared.log("bdr.retarget", data: [
        "wid": currentWindowID,
        "oldTarget": oldTarget,
        "newTarget": newTargetID
    ])
    return true
}
```

## Cleanup

### destroyAllBorders()

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

    // Destroy free pool (NEW)
    for border in freePool {
        border.destroy()
    }
    freePool.removeAll()
}
```

### Display Disconnect

`handleDisplayDisconnectedImpl()` already calls `destroyAllBorders()`, so the free pool is cleaned up automatically.

## Error Handling

### Retarget Failures

When `retarget(to:)` fails (target window destroyed), `acquireBorder()` destroys the invalid border and retries. This recursion is bounded because eventually it will create a fresh border.

### Pool Corruption Guard

Debug assertion to catch invariant violations. Call at the end of `rebuildBorderPool()`
and `reassignBorders()` in debug builds.

```swift
private func validatePoolInvariants() {
    #if DEBUG
    let activeSet = activeBorder.map { [$0] } ?? []
    let inactiveSet = Array(inactiveBorders.values)
    let all = activeSet + inactiveSet + freePool
    assert(Set(all.map { ObjectIdentifier($0) }).count == all.count,
           "Border appears in multiple collections")
    #endif
}
```

Add to end of pool-modifying methods:
```swift
// At end of rebuildBorderPool() and reassignBorders():
validatePoolInvariants()
```

## Testing

### Unit Tests

1. **Pool reuse** - Verify `acquireBorder` returns pooled border instead of creating new
2. **Pool cap** - Verify excess borders are destroyed when pool exceeds `maxFreePoolSize`
3. **Retarget failure recovery** - Verify failed retarget destroys border and creates fresh one

### Performance Verification

Run load test before/after, compare:
- Focus latency p95 (target: <80ms, currently ~125ms)
- `SLSNewWindow` calls in profile (target: near zero during steady-state)

## Files to Modify

| File | Changes |
|------|---------|
| `SimpleBorderManager.swift` | Add `freePool`, `acquireBorder()`, `releaseBorder()`, modify `rebuildBorderPool()` |
| `BorderWindow.swift` | Change `retarget()` return type to `Bool` |

## Expected Impact

| Metric | Before | After (Expected) |
|--------|--------|------------------|
| Focus p95 | 125ms | <80ms |
| `SLSNewWindow` % of CPU | 34% | <5% (only on pool miss) |
| Memory | ~same | +10 BorderWindow objects max in pool |

## Rollback

If issues arise, revert to destroy/recreate by changing `releaseBorder()` to always call `destroy()` instead of pooling.
