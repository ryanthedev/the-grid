# Pseudocode: Phase 4 - Reconciler

## Design: GridReconciler

### Approaches Considered

1. **Single class, StateEventHandler** -- One `GridReconciler` class that conforms to `StateEventHandler`, registers with `EventRouter`, and handles all event types in a single `handle()` method. Holds references to `GridState`, `GridConfig`, `StateManager`, and `SimpleBorderManager`. Coordinates all reconciliation and border sync.

2. **Actor-based reconciler** -- An actor `GridReconciler` that receives events via its own methods (not `StateEventHandler`). A thin bridge class registers with `EventRouter` and forwards events to the actor. This provides automatic serialization of reconciliation logic.

3. **Multiple specialized handlers** -- Separate handlers for focus, windows, and borders. `FocusReconciler`, `WindowReconciler`, `BorderReconciler` each register with `EventRouter`. Coordinates via shared state in `GridState` actor.

### Comparison

| Criterion | A (Single class) | B (Actor) | C (Multiple handlers) |
|-----------|---|---|---|
| Interface simplicity | Simple: one class, one protocol | Extra bridge layer | Many classes to coordinate |
| Information hiding | High: all reconciliation logic hidden | High | Low: cross-handler coordination leaks |
| Caller ease of use | Register once, done | Register bridge, done | Register 3 handlers |
| Serialization | Must handle manually | Actor provides | Must coordinate between handlers |
| Border sync coupling | Direct calls, simple | Same via actor | Split across handlers |

### Choice: A (Single class)

Rationale: The reconciler is fundamentally about coordinating state changes across subsystems. Splitting it fragments the coordination logic. Actor serialization (option B) adds a bridge indirection without benefit since `GridState` is already an actor and `SimpleBorderManager` already dispatches to main queue. A class with `StateEventHandler` is the simplest approach that keeps all reconciliation logic in one place.

### Depth Check
- Interface methods: 3 public (`setup`, `handle`, `suppressReconciliation` flag)
- Hidden details: event-to-state mapping, border sync orchestration, dead window cleanup, focus tracking, space migration
- Common case complexity: simple (event arrives, update state, sync borders)

---

## Files to Create/Modify

### Create: `Grid/GridReconciler.swift`
### Modify: `BorderEvents.swift` (add comment clarifying reconciler takes over, keep no-op)
### Modify: `main.swift` (wire GridReconciler initialization)

## Pseudocode

### Grid/GridReconciler.swift

```
class GridReconciler: StateEventHandler

    // Dependencies (set via setup)
    private weak reference to GridState actor
    private weak reference to GridConfig
    private weak reference to StateManager actor
    private weak reference to SimpleBorderManager

    // Suppression flag for bulk operations (layout apply)
    private var suppressReconciliation: Bool = false

    // Public method to set suppression (called by GridApply in Phase 6)
    func setSuppressed(_ suppressed: Bool)
        set suppressReconciliation to suppressed
        if unsuppressed, trigger a full border sync for current space

    // Setup: store references, register with EventRouter
    func setup(gridState, gridConfig, stateManager, simpleBorderManager)
        store all references
        register self with EventRouter.shared

    // MARK: - StateEventHandler

    func handle(_ event: StateEvent, context: EventContext) async throws
        if suppressReconciliation, return early (unless event is focusChanged -- always track focus)

        switch event

        case .windowDestroyed(windowID):
            await handleWindowDestroyed(windowID)

        case .windowCreated(windowID, pid):
            await handleWindowCreated(windowID, pid)

        case .focusChanged(focusState):
            await handleFocusChanged(focusState)

        case .systemWoke:
            await handleSystemWake()

        case .windowMoved(windowID, frame):
            handleWindowMoved(windowID, frame)

        case .windowMinimized(windowID):
            await handleWindowMinimized(windowID)

        case .windowDeminimized(windowID):
            await handleWindowDeminimized(windowID)

        case .displayDisconnected(displayUUID):
            handleDisplayDisconnected(displayUUID)

        default:
            // Ignore other events (app lifecycle, title changes, etc.)
            break

    // MARK: - Event Handlers

    private func handleWindowDestroyed(windowID) async
        // 1. Remove window from GridState (all spaces)
        await gridState.removeWindowFromAllSpaces(windowID)

        // 2. Tell border manager to clean up borders for this window
        simpleBorderManager.handleWindowDestroyed(windowID: windowID)

        // 3. Sync borders for current space (assignments changed)
        await syncBordersForCurrentSpace()

        log "reconcile.win.destroy"

    private func handleWindowCreated(windowID, pid) async
        // Get current state to find which space we're on
        guard let stateManager else return
        let wmState = await stateManager.getState()

        // Find the current space ID from active spaces
        let currentSpaceID = findCurrentSpaceID(from: wmState)
        guard let spaceID = currentSpaceID else return

        // Check if there's an active layout for this space
        guard let gridState else return
        let layoutID = await gridState.getCurrentLayout(spaceID: spaceID)
        if layoutID is empty, return (no layout active, nothing to reconcile)

        // Get the window state from StateManager
        let windowState = wmState.windows[String(windowID)]
        guard windowState exists else return

        // Check if window is tileable
        guard isTileable(window: windowState) else return

        // Check window classification
        let appName = windowState.appName ?? ""
        let category = classifyWindow(window: windowState, appName: appName)
        if category is not .standard, return (floating/popup windows not auto-assigned)

        // Auto-assign: find least-populated cell
        let assignments = await gridState.getWindowAssignments(spaceID: spaceID)
        let leastPopulatedCell = findLeastPopulatedCell(assignments)

        if leastPopulatedCell is not empty
            await gridState.assignWindow(windowID, toCellID: leastPopulatedCell, inSpace: spaceID)

            // Sync borders after assignment
            await syncBordersForCurrentSpace()

        log "reconcile.win.create"

    private func handleFocusChanged(focusState: FocusState) async
        // Always track focus, even when suppressed (so state is correct after unsuppression)
        let spaceID = String(focusState.spaceID)
        let windowID = focusState.windowID

        guard let gridState, let windowID else return

        // Detect space change
        let spaceChanged = focusState.previousSpaceID != nil
            && focusState.previousSpaceID != focusState.spaceID

        if spaceChanged
            await handleSpaceChanged(
                newSpaceID: spaceID,
                displayUUID: focusState.displayUUID
            )

        // Update GridState focus to match OS focus
        let cellID = await gridState.getWindowCell(windowID: windowID, inSpace: spaceID)
        if cellID is not nil
            // Find window index in cell
            let cellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)
            let windowIndex = cellWindows.firstIndex(of: windowID) ?? 0
            await gridState.setFocus(spaceID: spaceID, cellID: cellID, windowIndex: windowIndex)

        // Update border focus (always, even when suppressed)
        if not suppressReconciliation
            simpleBorderManager.updateFocus(
                newFocusedWindow: windowID,
                displayUUID: focusState.displayUUID
            )

        // If display changed, sync borders for both old and new display
        if focusState.previousDisplayUUID != nil
            && focusState.previousDisplayUUID != focusState.displayUUID
            // Cross-display focus change: sync borders for new display
            await syncBordersForSpace(spaceID, displayUUID: focusState.displayUUID)

    private func handleSpaceChanged(newSpaceID, displayUUID) async
        // When user switches spaces, the new space may or may not have a layout
        guard let gridState, let gridConfig else return

        let layoutID = await gridState.getCurrentLayout(spaceID: newSpaceID)
        if layoutID is not empty
            // Space has a layout -- sync borders for it
            await syncBordersForSpace(newSpaceID, displayUUID: displayUUID)
        else
            // No layout on this space -- clear borders
            // (SimpleBorderManager handles this via empty assignments)
            pass

        log "reconcile.space.change"

    private func handleSystemWake() async
        // Migrate space IDs (macOS may reassign them after sleep)
        guard let stateManager, let gridState else return
        let wmState = await stateManager.getState()

        // Build display -> space ID list map
        var displaySpaces: [String: [String]] = [:]
        for display in wmState.displays
            var spaceIDs: [String] = []
            for (spaceKey, space) in wmState.spaces
                if space.displayUUID == display.uuid
                    spaceIDs.append(spaceKey)
            // Sort by space ID for positional matching
            displaySpaces[display.uuid] = spaceIDs.sorted()

        let migrated = await gridState.migrateSpaceIDs(currentDisplaySpaces: displaySpaces)
        if migrated
            log "reconcile.wake.migrated"

        // After migration, sync borders for current space
        await syncBordersForCurrentSpace()

    private func handleWindowMoved(windowID, frame)
        // Forward to border manager for position tracking
        simpleBorderManager.handleWindowMoved(windowID: windowID, newFrame: frame)

    private func handleWindowMinimized(windowID) async
        // Minimized window should be removed from cell assignment
        // (same as destroyed from tiling perspective)
        guard let gridState else return

        // Find which space this window is on and remove it
        let currentSpaceID = await findCurrentSpaceIDAsync()
        if let spaceID = currentSpaceID
            await gridState.removeWindow(windowID, fromSpace: spaceID)
            await syncBordersForCurrentSpace()

        log "reconcile.win.min"

    private func handleWindowDeminimized(windowID) async
        // Treat like a new window creation for tiling purposes
        guard let stateManager else return
        let wmState = await stateManager.getState()
        guard let windowState = wmState.windows[String(windowID)] else return

        let pid = windowState.pid
        await handleWindowCreated(windowID, pid)

        log "reconcile.win.unmin"

    private func handleDisplayDisconnected(displayUUID)
        simpleBorderManager.handleDisplayDisconnected(displayUUID: displayUUID)

    // MARK: - Border Sync

    private func syncBordersForCurrentSpace() async
        // Get current space and display from StateManager
        guard let stateManager, let gridState, let gridConfig else return

        let wmState = await stateManager.getState()
        let currentSpaceID = findCurrentSpaceID(from: wmState)
        let currentDisplayUUID = findCurrentDisplayUUID(from: wmState)
        guard let spaceID = currentSpaceID,
              let displayUUID = currentDisplayUUID else return

        await syncBordersForSpace(spaceID, displayUUID: displayUUID)

    private func syncBordersForSpace(_ spaceID: String, displayUUID: String) async
        guard let gridState, let gridConfig else return

        // 1. Get layout for this space
        let layoutID = await gridState.getCurrentLayout(spaceID: spaceID)
        guard layoutID is not empty else
            // No layout -- clear borders by sending empty assignments
            simpleBorderManager.setCellAssignments([:], forDisplay: displayUUID)
            return

        // 2. Get layout definition
        guard let layoutDef = try? gridConfig.getLayout(id: layoutID) else return

        // 3. Get display bounds for layout calculation
        guard let stateManager else return
        let wmState = await stateManager.getState()
        let displayBounds = findDisplayBounds(displayUUID: displayUUID, from: wmState)
        guard let bounds = displayBounds else return

        // 4. Calculate cell bounds
        let columnRatios = await gridState.getColumnRatios(spaceID: spaceID)
        let rowRatios = await gridState.getRowRatios(spaceID: spaceID)
        let calculated = GridLayout.calculateLayoutWithRatios(
            layout: layoutDef, screenRect: bounds, gap: gridConfig.settings.gap,
            columnRatios: columnRatios, rowRatios: rowRatios
        )
        guard calculated is not nil else return

        // 5. Build window-to-cell assignments map (windowID -> cellID)
        let spaceAssignments = await gridState.getWindowAssignments(spaceID: spaceID)
        var windowToCellMap: [UInt32: String] = [:]
        var cellStackModes: [String: String] = [:]
        var windowOrder: [String: [UInt32]] = [:]

        for (cellID, windowIDs) in spaceAssignments
            for wid in windowIDs
                windowToCellMap[wid] = cellID
            windowOrder[cellID] = windowIDs

            // Get stack mode for cell
            let mode = await gridState.getCellStackMode(spaceID: spaceID, cellID: cellID)
            cellStackModes[cellID] = mode?.rawValue ?? "tabs"

        // 6. Get focused window
        let focusedWID = await gridState.getFocusedWindow(spaceID: spaceID)

        // 7. Send to SimpleBorderManager (atomic update with focus)
        simpleBorderManager.setCellAssignments(
            windowToCellMap,
            forDisplay: displayUUID,
            focusedWindowID: focusedWID != 0 ? focusedWID : nil,
            cellStackModes: cellStackModes,
            windowOrder: windowOrder,
            displayFrame: bounds
        )

    // MARK: - Helpers

    private func findCurrentSpaceID(from wmState: WindowManagerState) -> String?
        // Find the active space
        for (spaceKey, space) in wmState.spaces
            if space.isActive
                return spaceKey
        return nil

    private func findCurrentDisplayUUID(from wmState: WindowManagerState) -> String?
        // Find display with the active space
        for (spaceKey, space) in wmState.spaces
            if space.isActive
                return space.displayUUID
        return nil

    private func findDisplayBounds(displayUUID, from wmState) -> CGRect?
        for display in wmState.displays
            if display.uuid == displayUUID
                return display.visibleFrame ?? display.frame
        return nil

    private func findLeastPopulatedCell(_ assignments: [String: [UInt32]]) -> String
        return assignments sorted alphabetically, min by window count, or empty string

    private func findCurrentSpaceIDAsync() async -> String?
        guard let stateManager else return nil
        let wmState = await stateManager.getState()
        return findCurrentSpaceID(from: wmState)
```

### Wiring in main.swift

```
// After creating GridState, GridConfig, StateManager, SimpleBorderManager:

let gridReconciler = GridReconciler()
gridReconciler.setup(
    gridState: gridState,
    gridConfig: gridConfig,
    stateManager: stateManager,
    simpleBorderManager: simpleBorderManager
)

// Store reference to keep alive
```

### BorderEvents.swift (minimal change)

```
// Update comment in handle() to note:
// "Border sync is now driven by GridReconciler. This handler remains
// as a no-op for backward compatibility during migration."
// No functional change needed.
```

## Design Notes

1. **Event-driven vs poll-based**: The Go reconciler polls on every CLI command. The Swift reconciler reacts to events as they happen. This is fundamentally different -- the reconciler fires continuously, not just when the user invokes a command. This means it must be lightweight and avoid expensive operations on every event.

2. **Focus always tracked**: Even when `suppressReconciliation` is true (during bulk layout apply), focus changes are still tracked in `GridState`. This ensures that after unsuppression, the state accurately reflects the OS focus. Only border sync is suppressed.

3. **Border sync is the expensive operation**: Calculating cell bounds and sending assignments to `SimpleBorderManager` involves layout computation. This is the main thing to avoid during suppression. Focus tracking is cheap.

4. **SimpleBorderManager handles thread safety**: All `SimpleBorderManager` methods dispatch to main queue internally. The reconciler does not need to manage main queue dispatch for border calls.

5. **Space change detection**: There is no explicit `spaceChanged` event. Space changes are detected from `focusChanged` events where `previousSpaceID != spaceID`. The reconciler checks for this and handles it as a space change.

6. **Auto-assign on windowCreated is conservative**: New windows are assigned to the least-populated cell only if there's an active layout. This matches the Go behavior of auto-flow assignment. More sophisticated assignment (pinned, position-based) is handled by explicit `layout apply` (Phase 6).

7. **Minimized windows**: Treating minimization as removal from tiling (similar to destroy) and deminimization as creation. This keeps the tiling state clean.

8. **No ClearBorders function needed**: The Go CLI had `ClearBorders` as an explicit RPC. In the Swift reconciler, clearing borders is done by sending empty assignments to `SimpleBorderManager.setCellAssignments([:], forDisplay:)`.

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (deep module analysis done)
- [x] Ready for implementation
