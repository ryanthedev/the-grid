# Discovery: Phase 1 - GridReconciler pending launch target + layout/focus deps

## Files Found
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Grid/GridReconciler.swift` - exists, 477 lines
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Grid/GridState.swift` - exists, has `prependWindow`, `setFocus`, `assignWindow`
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Grid/GridApply.swift` - exists, has `applyCellLayout(spaceID:cellID:)` at line 250
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Grid/GridFocus.swift` - exists, has `focusWindowByID(_:)` at line 286
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Grid/GridWindowMove.swift` - exists, has the `setApply` pattern to follow
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Grid/GridAssignment.swift` - exists, has free functions `isTileable(window:)` and `classifyWindow(window:appName:)`

## Current State

GridReconciler is an event-driven reconciler that:
- Implements `StateEventHandler` protocol
- Has weak refs to `gridState`, `gridConfig`, `stateManager`, `simpleBorderManager`
- Has suppression flag (`suppressReconciliation`) for bulk operations
- Has move cooldown tracking (`moveTargetWindowID`, `moveEndTime`)
- `handle()` method at line 89: focus events bypass suppression, all other events (including `.windowCreated`) are gated by `if suppressReconciliation { return }` at line 97
- `handleWindowCreated` at line 144: finds current space, checks layout exists, validates tileable + standard, finds least-populated cell, calls `gridState.assignWindow`, syncs borders

No `PendingLaunchTarget` exists yet. No references to `GridApply` or `GridFocus` exist in GridReconciler.

The `setApply` pattern is established in `GridWindowMove` (line 89): a simple setter that resolves circular init dependencies. `GridCommandRouter` wires it at line 124.

`isTileable` and `classifyWindow` are free functions in `GridAssignment.swift`, already used in `handleWindowCreated` -- reusable without changes.

`prependWindow` on GridState (line 360) inserts at index 0, sets `lastFocusedIdx = 0`, `lastFocusedWid`, and equalizes split ratios. This is exactly the behavior needed.

## Gaps

1. **No gaps.** All APIs referenced in the plan exist with expected signatures.
2. The plan's `handle()` modification site is clear: the `.windowCreated` case at line 105 is inside the `switch` block AFTER the suppression guard at line 97. The plan requires checking pending target BEFORE that guard. This means restructuring: pull `.windowCreated` out of the switch and handle it before the `if suppressReconciliation` check.

## Prerequisites
- [x] Target file exists (GridReconciler.swift)
- [x] `prependWindow` exists on GridState with correct signature
- [x] `setFocus(spaceID:cellID:windowIndex:)` exists on GridState
- [x] `applyCellLayout(spaceID:cellID:)` exists on GridApply
- [x] `focusWindowByID(_:)` exists on GridFocus
- [x] `isTileable` and `classifyWindow` free functions available
- [x] `setApply` pattern exists in GridWindowMove to follow
- [x] No conflicting changes in GridReconciler

## Recommendation
BUILD - All prerequisites met, APIs exist, modification points are clear.
