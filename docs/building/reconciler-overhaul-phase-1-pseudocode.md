# Pseudocode: Phase 1 - State Validator

## Files to Create/Modify

- `grid-server/Sources/GridServer/Grid/StateValidator.swift` -- new actor (primary deliverable)
- `grid-server/Sources/GridServer/Grid/GridState.swift` -- add `getSpaceIDs()` method
- `grid-server/Sources/GridServer/Grid/GridReconciler.swift` -- call validator in `handleSystemWake`
- `grid-server/Sources/GridServer/main.swift` -- instantiate validator, start periodic timer

---

## Design

### Approaches Considered

1. **StateValidator as standalone actor** -- owns its timer, holds weak refs to GridState and StateManager, called by GridReconciler on wake. Simple, minimal coupling.
2. **Validation logic embedded in GridReconciler** -- fewer files, but violates single responsibility. GridReconciler is already large (650 lines). Mixes event routing with state auditing.
3. **Validation logic embedded in GridState** -- GridState is an actor, could self-validate. But GridState has no access to wmState (StateManager) -- it would need a callback or reference, increasing coupling.

**Choice: Approach 1** -- standalone actor. Deep module: the interface is two methods (`validate()` and `start()`). All SLS calls, deduplication logic, and logging are hidden inside.

### Depth Check

- Interface methods: 2 (`start()`, `validate(wmState:)`)
- Hidden details: SLSGetWindowBounds call, CGError comparison, isMinimized guard, space ID set construction, deduplication tie-breaking logic, periodic timer lifecycle
- Common case complexity: caller says `await validator.validate(wmState: wmState)` -- single call, no configuration

---

## Pseudocode

### StateValidator.swift (new file)

```
actor StateValidator

  PROPERTIES:
    weak gridState: GridState?
    weak stateManager: StateManager?
    connectionID: Int32       -- for SLSGetWindowBounds calls
    timer: DispatchSourceTimer?
    validationInterval: Duration = 30 seconds

  INIT(gridState, stateManager, connectionID):
    store all three
    timer = nil

  // start() -- called once from main.swift after wiring
  func start():
    create repeating DispatchSourceTimer on background queue
    every validationInterval, fire a Task:
      get wmState from stateManager
      call validate(wmState: wmState)
    log "validate.timer.start" with interval data
    store timer, resume it

  // validate(wmState:) -- called on wake and periodically
  // Does NOT block the caller -- all mutations go through GridState actor
  func validate(wmState: WindowManagerState) async:
    log "validate.start"

    pruneDeadWindows(wmState: wmState)
    deduplicateWindows(wmState: wmState)
    pruneDeadSpaces(wmState: wmState)

    log "validate.end"

  // pruneDeadWindows -- remove windows that no longer exist in SkyLight
  private func pruneDeadWindows(wmState: WindowManagerState) async:
    get allTrackedIDs from gridState.getAllWindowIDs()

    for each windowID in allTrackedIDs:
      // Guard: skip minimized windows (SLSGetWindowBounds succeeds for them)
      if wmState.windows[String(windowID)]?.isMinimized == true:
        continue

      // Check liveness via SkyLight private API
      var bounds = CGRect.zero
      let err = SLSGetWindowBounds(connectionID, windowID, &bounds)

      if err != .success:
        // Window is dead (destroyed) -- remove from all spaces
        await gridState.removeWindowFromAllSpaces(windowID)
        log "validate.win.prune" with data: wid=windowID, reason="dead"

  // deduplicateWindows -- remove windows from all-but-one space when duplicated
  private func deduplicateWindows(wmState: WindowManagerState) async:
    // Collect all tracked windows and which spaces they appear in, per GridState
    var windowSpaces: [UInt32: [String]] = [:]   // wid -> list of spaceIDs in GridState

    for each spaceID in (await gridState.getSpaceIDs()):
      // Get all windows in this space by iterating getWindowAssignments
      let assignments = await gridState.getWindowAssignments(spaceID: spaceID)
      for each (_, windowIDs) in assignments:
        for each wid in windowIDs:
          windowSpaces[wid, default: []].append(spaceID)

    // For each window in more than one space, keep it in the "best" space
    for each (wid, spaceIDs) in windowSpaces where spaceIDs.count > 1:
      let keepSpaceID = pickBestSpace(wid: wid, spaceIDs: spaceIDs, wmState: wmState)

      for each spaceID in spaceIDs where spaceID != keepSpaceID:
        await gridState.removeWindow(wid, fromSpace: spaceID)
        log "validate.win.dedup" with data: wid=wid, removedFrom=spaceID, keptIn=keepSpaceID

  // pickBestSpace -- determine which space a duplicated window should live in
  // Priority: (1) space matching the window's actual OS space, (2) active display space, (3) most recent
  private func pickBestSpace(wid: UInt32, spaceIDs: [String], wmState: WindowManagerState) -> String:
    // Get the window's actual OS-reported spaces (from wmState)
    let osWindowSpaces: Set<UInt64>
    if let windowState = wmState.windows[String(wid)]:
      osWindowSpaces = Set(windowState.spaces)
    else:
      osWindowSpaces = Set()

    // Prefer a GridState space that matches a known OS space for this window
    for spaceID in spaceIDs:
      if let spaceIDInt = UInt64(spaceID), osWindowSpaces.contains(spaceIDInt):
        return spaceID

    // Fallback: prefer the active space on any display
    for display in wmState.displays:
      let activeSpaceID = String(display.currentSpaceID)
      if spaceIDs.contains(activeSpaceID):
        return activeSpaceID

    // Final fallback: return first (arbitrary but stable within a run)
    return spaceIDs[0]

  // pruneDeadSpaces -- remove spaces from GridState not present in wmState
  private func pruneDeadSpaces(wmState: WindowManagerState) async:
    let liveSpaceIDs: Set<String> = Set(wmState.spaces.keys)
    let trackedSpaceIDs: [String] = await gridState.getSpaceIDs()

    for spaceID in trackedSpaceIDs:
      if !liveSpaceIDs.contains(spaceID):
        await gridState.removeSpace(spaceID)
        log "validate.space.prune" with data: spaceID=spaceID
```

---

### GridState.swift -- add getSpaceIDs()

```
// MARK: - Space Enumeration (for StateValidator)

func getSpaceIDs() -> [String]:
  return Array(spaces.keys)
```

Location: add after `getSpaceReadOnly()` in the "Space Access" section (around line 244).

---

### GridReconciler.swift -- call validator in handleSystemWake

```
// Add property at top of class:
private weak var stateValidator: StateValidator?

// Add setter (same pattern as setApply/setFocus):
func setValidator(_ validator: StateValidator):
  self.stateValidator = validator

// Modify handleSystemWake():
private func handleSystemWake() async:
  // ... existing migration logic unchanged ...
  let migrated = await gridState.migrateSpaceIDs(currentDisplaySpaces: displaySpaces)
  if migrated:
    log "reconcile.wake.migrated"

  // NEW: run state validation after migration
  await stateValidator?.validate(wmState: wmState)

  // existing: sync borders for current space
  await syncBordersForCurrentSpace()
```

Note: `wmState` is already fetched earlier in `handleSystemWake` for migration. Re-use the same variable rather than fetching again.

---

### main.swift -- instantiate and start validator

```
// After gridState and gridReconciler are created, inside the Task that wires reconciler:

// Instantiate StateValidator
let stateValidator = StateValidator(
  gridState: gridState,
  stateManager: StateManager.shared,
  connectionID: connectionID
)

// Wire into reconciler for on-wake calls
gridReconciler.setValidator(stateValidator)

// Start periodic timer
stateValidator.start()

log "validate.init"
```

Location: add at the end of the existing `Task { await StateManager.shared.start(...) ... gridReconciler.setup(...) }` block.

---

## Design Notes

**Information hiding:** `StateValidator` hides all three validation passes (dead, duplicate, dead-space) behind a single `validate(wmState:)` call. Callers (GridReconciler, timer) know nothing about SLS, CGError, or deduplication tie-breaking.

**Actor isolation:** `StateValidator` is an actor. Its timer fires a non-isolated `Task` that `await`s `validate()` -- this is the correct pattern for actor-isolated async work from a timer callback.

**Async without blocking main thread:** All mutations (`removeWindowFromAllSpaces`, `removeWindow`, `removeSpace`) are awaited inside `validate()`, which is itself `async`. The timer callback uses `Task {}` (detached-style unstructured task) so it does not block the DispatchSource callback. GridReconciler calls it with `await` inside `handleSystemWake` which is already async.

**Minimized window guard:** Checked first before SLSGetWindowBounds to avoid a false prune. Uses wmState data (not a second SLS call) which is O(1) dictionary lookup.

**Deduplication tie-breaking order:**
1. Window's actual OS space (from wmState.windows[wid].spaces) -- most accurate
2. Active space on any display -- pragmatic fallback
3. First in list -- deterministic final fallback

**Space pruning scope:** Only removes spaces from GridState. Does not affect wmState, borders, or displaySpaces mapping -- those are managed by other phases.

**Timer ownership:** StateValidator owns its `DispatchSourceTimer`. It is stored as a property so ARC keeps it alive. The timer is created on a background DispatchQueue (not main thread).

**Logging convention:** All events use `validate.*` prefix per plan constraint:
- `validate.start` / `validate.end`
- `validate.win.prune` (data: wid, reason)
- `validate.win.dedup` (data: wid, removedFrom, keptIn)
- `validate.space.prune` (data: spaceID)
- `validate.timer.start` (data: intervalSeconds)

---

## PRE-GATE Status

- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (standalone actor, deep module interface, 2 public methods)
- [ ] Ready for implementation
