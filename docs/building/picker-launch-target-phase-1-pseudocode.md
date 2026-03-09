# Pseudocode: Phase 1 - GridReconciler pending launch target + layout/focus deps

## Files to Create/Modify
- `grid-server/Sources/GridServer/Grid/GridReconciler.swift` (modify)

## Pseudocode

### GridReconciler.swift

#### New struct: PendingLaunchTarget (add near top of file, before class)

```
struct PendingLaunchTarget
    spaceID: String
    cellID: String
    createdAt: CFAbsoluteTime
```

#### New properties (add after existing dependency declarations, around line 18)

```
// Weak references to GridApply and GridFocus for picker-launched window handling
private weak var gridApply: GridApply?
private weak var gridFocus: GridFocus?

// One-shot target: next tileable window created on target space claims this cell
private var pendingLaunchTarget: PendingLaunchTarget?

// Timeout for pending launch target (app may take time to launch)
private let pendingLaunchTimeout: CFAbsoluteTime = 15.0
```

#### New public API methods (add after existing public API section, after clearMoveCooldown)

```
func setPendingLaunchTarget(_ target: PendingLaunchTarget?)
    set pendingLaunchTarget to target
    if target is not nil
        log "reconcile.pending.set" with spaceID and cellID

func setApply(_ apply: GridApply)
    set self.gridApply to apply

func setFocus(_ focus: GridFocus)
    set self.gridFocus to focus
```

#### Modified handle() method

The critical change: intercept `.windowCreated` BEFORE the suppression guard. The restructured flow:

```
func handle(event, context)
    // Focus events handle suppression/cooldown internally (unchanged)
    if event is .focusChanged(focusState)
        handleFocusChanged(focusState)
        return

    // CRITICAL: Check pending launch target for windowCreated BEFORE suppression
    // Picker-launched windows must be claimed even during move suppression
    if event is .windowCreated(windowID, pid)
        if pendingLaunchTarget is not nil
            handlePendingLaunchWindow(windowID, pid)
            return
        // No pending target: fall through to suppression check below

    // Skip other events when suppressed (existing behavior)
    if suppressReconciliation
        return

    // Switch on remaining events (existing behavior)
    switch event
        case .windowCreated(windowID, pid)
            // Reached here only if no pending target and not suppressed
            handleWindowCreated(windowID, pid)
        case .windowDestroyed, .systemWoke, .windowMoved, etc.
            // All unchanged
        default: break
```

#### New method: handlePendingLaunchWindow

```
private func handlePendingLaunchWindow(windowID, pid)
    guard let target = pendingLaunchTarget else
        // No target (race condition safety) -- fall through
        handleWindowCreated(windowID, pid)
        return

    // Always clear target first (one-shot: prevents retry on failure)
    pendingLaunchTarget = nil

    // Check timeout
    let elapsed = CFAbsoluteTimeGetCurrent() - target.createdAt
    if elapsed > pendingLaunchTimeout
        log "reconcile.pending.expired" with elapsed
        // Fall through to default assignment
        handleWindowCreated(windowID, pid)
        return

    // Get window state from StateManager
    guard stateManager exists else return
    let wmState = stateManager.getState()
    guard windowState exists for windowID in wmState else
        handleWindowCreated(windowID, pid)
        return

    // Validate: must be tileable
    if not isTileable(windowState)
        handleWindowCreated(windowID, pid)
        return

    // Validate: must be standard category
    let appName = windowState.appName or ""
    let category = classifyWindow(windowState, appName)
    if category is not .standard
        handleWindowCreated(windowID, pid)
        return

    // Validate: window appeared on the target space
    let actualSpaceID = findCurrentSpaceID(from: wmState)
    if actualSpaceID is nil or actualSpaceID != target.spaceID
        log "reconcile.pending.space.mismatch" with expected and actual
        // Wrong space: fall through to default (handleWindowCreated uses actual space)
        handleWindowCreated(windowID, pid)
        return

    // Validate: target space has an active layout
    guard gridState exists else return
    let layoutID = gridState.getCurrentLayout(spaceID: target.spaceID)
    if layoutID is empty
        handleWindowCreated(windowID, pid)
        return

    // All checks passed: assign to target cell
    gridState.prependWindow(windowID, toCellID: target.cellID, inSpace: target.spaceID)
    gridState.setFocus(spaceID: target.spaceID, cellID: target.cellID, windowIndex: 0)

    // Apply layout to position all windows in the cell
    try? gridApply.applyCellLayout(spaceID: target.spaceID, cellID: target.cellID)

    // Focus the new window via accessibility
    try? gridFocus.focusWindowByID(windowID)

    // Sync borders to reflect new assignment
    syncBordersForCurrentSpace()

    log "reconcile.win.create.picker" with windowID and cellID
```

## Design Notes

### Design-It-Twice: Approaches Considered

1. **Inline check in handle() + separate handler method** (chosen) - Adds a pre-suppression intercept in `handle()` that delegates to a new `handlePendingLaunchWindow` method. Clean separation between the routing decision and the handling logic.

2. **Flag-based suppression bypass** - Add a `bypassSuppression` flag that `setPendingLaunchTarget` sets, checked alongside `suppressReconciliation`. Rejected: introduces a second suppression dimension that interacts poorly with existing logic and is harder to reason about.

3. **Separate event type** - Have the callback emit a new `.pickerWindowCreated` event instead of relying on the standard `.windowCreated`. Rejected: requires changes to EventRouter and StateEvent enum across the codebase, and the OS still fires a normal `.windowCreated` which would also need suppression.

### Comparison

| Criterion | Inline+handler | Flag bypass | New event type |
|-----------|---------------|-------------|----------------|
| Interface simplicity | Simple: 3 new public methods | Simple but leaky | Requires EventRouter changes |
| Information hiding | Pending target logic fully encapsulated in reconciler | Bypass flag leaks suppression detail | Distributes knowledge across modules |
| Caller ease of use | setPendingLaunchTarget + setApply/setFocus | Same + must understand flag | Must emit new event type |
| Risk of breaking existing flow | Low: only windowCreated path modified | Medium: suppression flag interactions | High: event routing changes |

### Choice: Inline+handler
Rationale: Minimal surface area change. The pending target is an internal concern of GridReconciler. Callers only see `setPendingLaunchTarget`, `setApply`, `setFocus`. The handle() restructuring is surgical -- only `.windowCreated` gets special treatment.

### Depth Check
- New public interface methods: 3 (`setPendingLaunchTarget`, `setApply`, `setFocus`)
- Hidden details: timeout logic, space validation, tileable/standard checks, one-shot clearing, fallthrough to default assignment on any failure
- Common case complexity: Simple -- caller sets target, next qualifying window gets assigned there

### Key Design Decisions

1. **One-shot with early clear**: `pendingLaunchTarget` is cleared at the top of `handlePendingLaunchWindow`, before any validation. This prevents a failed validation from leaving a stale target that captures an unrelated window later. If validation fails, we fall through to default `handleWindowCreated`.

2. **Fall-through on every failure path**: Every validation failure (expired, not tileable, wrong space, not standard) clears the target AND falls through to `handleWindowCreated`. The window still gets assigned somewhere -- just not to the picker target cell.

3. **Weak refs for GridApply/GridFocus**: Follows the established `GridWindowMove` pattern for circular dependency resolution. These are set after construction by `GridCommandRouter`.

4. **try? for applyCellLayout and focusWindowByID**: These can throw but failure here is non-fatal. The window is already assigned to the correct cell. Layout/focus are best-effort improvements.

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (design-it-twice with 3 approaches)
- [x] Ready for implementation
