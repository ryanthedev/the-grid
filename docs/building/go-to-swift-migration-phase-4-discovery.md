# Discovery: Phase 4 - Reconciler

## Files Found

### Phase 1-3b Dependencies (all exist, all complete)
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Grid/GridTypes.swift` -- enums and value types
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Grid/GridConfig.swift` -- config loading, `getLayout(id:)`, `appRules`
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Grid/GridState.swift` -- actor, all CRUD for spaces/cells/focus/ratios
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Grid/GridLayout.swift` -- pure layout calculation functions
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Grid/GridAssignment.swift` -- `GridAssignment.assignWindows()`, classification

### Event System
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/EventRouter.swift` -- `EventRouter` actor, `StateEventHandler` protocol, `StateEvent` enum
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/StateManager.swift` -- `StateManager` actor, routes events, holds `WindowManagerState`
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/StateModels.swift` -- `WindowManagerState`, `WindowState`, `DisplayState`, `SpaceState`

### Border System
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Borders/BorderEvents.swift` -- currently a no-op handler
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Borders/SimpleBorderManager.swift` -- full border management

### Target File
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Grid/GridReconciler.swift` -- DOES NOT EXIST (to be created)

### Go Source (port reference)
- `/Users/r/repos/theGrid/grid-cli/internal/reconcile/reconcile.go` -- 420 lines, poll-based sync + border functions

## Current State

### Go Reconciler (what we're porting from)
The Go `reconcile.go` is a **poll-based** system called on every CLI command:
1. `Sync()` -- removes dead windows from cells, syncs focus to OS state
2. `SyncBorders()` -- sends cell assignments + bounds to server for border rendering
3. `SyncBorderFocus()` -- notifies server of focused window
4. `SyncBordersForDisplay()` / `SyncBordersWithFocus()` -- cross-display variants
5. `CalculateCellBounds()` -- computes cell pixel bounds from layout

**Key architectural difference:** Go CLI polls snapshot on every command. The Swift reconciler will be **event-driven** -- subscribing to `EventRouter` events and reacting incrementally.

### EventRouter System (existing)
- `EventRouter` is an actor with `register(_ handler: StateEventHandler)`
- Events routed: `windowCreated`, `windowDestroyed`, `focusChanged(FocusState)`, `spaceCreated`, `spaceDestroyed`, `systemWoke`, etc.
- `FocusState` carries: `windowID`, `spaceID`, `displayUUID`, `previousWindowID`, `previousSpaceID`, `previousDisplayUUID`, `trigger`
- Handlers implement `func handle(_ event: StateEvent, context: EventContext) async throws`

### BorderEvents (current no-op)
- `BorderEvents` is a `class: StateEventHandler` that registers with `EventRouter`
- `handle()` currently does nothing -- comment says "Border sync is driven exclusively by CLI commands"
- Has weak reference to `SimpleBorderManager`

### SimpleBorderManager API (what we call directly)
- `setCellAssignments(_:forDisplay:focusedWindowID:cellStackModes:windowOrder:displayFrame:)` -- full border state update
- `updateFocus(newFocusedWindow:displayUUID:)` -- focus change within existing assignments
- `handleWindowDestroyed(windowID:)` -- remove border for destroyed window
- `handleWindowMoved(windowID:newFrame:)` -- update border position
- `handleDisplayDisconnected(displayUUID:)` -- clean up display state
- All methods dispatch to main queue internally

### StateManager Query API (what reconciler reads from)
- `getState() -> WindowManagerState` -- snapshot of all windows, displays, spaces
- `WindowManagerState.windows: [String: WindowState]` -- keyed by window ID string
- `WindowManagerState.displays: [DisplayState]` -- array of displays
- `WindowManagerState.spaces: [String: SpaceState]` -- keyed by space ID string
- `WindowState` has: `id`, `frame`, `pid`, `appName`, `isMinimized`, `isHidden`, `level`, `spaces`, `displayUUID`, `role`, `subrole`, etc.
- `DisplayState` has: `uuid`, `currentSpaceID`, `frame`, `visibleFrame`
- `SpaceState` has: `id`, `displayUUID`, `windows`, `isActive`

### GridState API (what reconciler mutates)
- `removeWindow(windowID:fromSpace:)` / `removeWindowFromAllSpaces(_:)` -- remove dead windows
- `assignWindow(_:toCellID:inSpace:)` -- add window to cell
- `setFocus(spaceID:cellID:windowIndex:)` -- update focus tracking
- `getWindowCell(windowID:inSpace:)` -- find cell for a window
- `getWindowAssignments(spaceID:)` -- get all cell->windowIDs for a space
- `getCurrentLayout(spaceID:)` -- get current layout ID
- `migrateSpaceIDs(currentDisplaySpaces:)` -- sleep/wake migration

## Gaps

1. **No space change event in `StateEvent`**: The plan says "On spaceChanged: switch active space, apply auto-layout" but there is no `spaceChanged` case in `StateEvent`. Instead, space changes arrive via `focusChanged(FocusState)` where `trigger == .spaceSwitched` and `previousSpaceID != spaceID`. The reconciler needs to detect space changes from `FocusState`.

2. **BorderEvents vs GridReconciler ownership**: The plan says "Change BorderEvents.handle() from no-op to active". However, it makes more architectural sense for `GridReconciler` to handle events directly and call `SimpleBorderManager` as needed -- rather than activating `BorderEvents` as a separate handler. `BorderEvents` can be left as-is or removed; the reconciler subsumes its responsibility.

3. **No `WindowManipulator` calls in reconciler**: The reconciler does not need to call `WindowManipulator` directly. It manages state (GridState) and borders (SimpleBorderManager). Actual window positioning is done by `GridApply` (Phase 6). The reconciler's job is to keep state consistent when external events occur.

4. **Auto-assign on windowCreated**: Requires knowing the current space's active layout and computing assignment. This needs `GridConfig.getLayout()` + `GridAssignment.assignWindows()` or simpler heuristic (assign to least-populated cell). Full auto-assignment may be deferred to Phase 6 (layout apply); the reconciler can do a simpler version.

## Prerequisites
- [x] GridTypes.swift exists (Phase 1)
- [x] GridConfig.swift exists with `getLayout(id:)`, `appRules` (Phase 1)
- [x] GridState.swift exists as actor with full CRUD (Phase 2)
- [x] GridLayout.swift exists with `calculateLayout()`, `calculateCellBounds()` (Phase 3)
- [x] GridAssignment.swift exists with `assignWindows()`, `classifyWindow()` (Phase 3b)
- [x] EventRouter.swift exists with `StateEventHandler` protocol
- [x] SimpleBorderManager.swift exists with full API
- [x] BorderEvents.swift exists (currently no-op)
- [x] StateManager.swift provides `getState()` for window/display queries
- [x] WindowManipulator.swift exists (not needed by reconciler directly)

## Recommendation
**BUILD**

Create `Grid/GridReconciler.swift` as a class conforming to `StateEventHandler`. It subscribes to `EventRouter`, reacts to window/focus/space events, updates `GridState`, and calls `SimpleBorderManager` directly for border sync. The `BorderEvents.handle()` no-op can remain as-is since the reconciler takes over that responsibility.
