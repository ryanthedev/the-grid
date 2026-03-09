# Discovery: Phase 1 - GridTerminalManager Actor + Frame Persistence

## Files Found
- `grid-server/Sources/GridServer/WindowManipulator.swift` - class, wraps MSSClient + AX APIs
- `grid-server/Sources/GridServer/MSSClient.swift` - C bridge to MSS library
- `grid-server/Sources/GridServer/StateManager.swift` - actor, `getState()` returns `WindowManagerState`
- `grid-server/Sources/GridServer/StateModels.swift` - WindowState, ApplicationState, DisplayState, StateMetadata
- `grid-server/Sources/GridServer/Grid/GridState.swift` - actor with constructor init, uses `XDG.stateHome`
- `grid-server/Sources/GridServer/Grid/GridReconciler.swift` - `setSuppressed(Bool, syncOnResume: Bool)` pattern
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` - class, dispatches `@terminal` domain at line 173
- `grid-server/Sources/GridServer/Grid/GridRecorder.swift` - actor with constructor injection (reference pattern)
- `grid-server/Sources/GridServer/XDG.swift` - `XDG.stateHome` resolves `~/.local/state`
- `grid-server/Sources/GridServer/DisplayInfo.swift` - `NSScreen.displayID` extension
- `grid-server/Sources/GridServer/main.swift` - feature module construction at lines 153-180
- `grid-server/Sources/GridServer/Grid/GridTerminalManager.swift` - DOES NOT EXIST (to be created)

## Current State

The terminal toggle is broken. `GridCommandRouter` line 173-175 posts an `NSDistributedNotification("com.thegrid.terminal.toggle")` that nothing listens to. The old GridTerminal binary (SwiftTerm-based) exists in `grid-server/Sources/GridTerminal/` but is not invoked correctly.

## Key Discovery Findings

### 1. WindowManipulator (class, not actor)
- `mssClient` is `let` with internal access (accessible as `windowManipulator.mssClient`)
- `setWindowOpacity(windowID:, opacity:)` on MSSClient -- proven cross-process, returns Bool
- `setWindowLayer(windowID:, layer:)` on MSSClient -- `WindowLayer` enum with `.above`, `.normal`, `.below`
- `orderWindowToFront(_:)` on MSSClient -- returns Bool
- `focusWindow(_:)` on MSSClient -- returns Bool
- `setWindowPosition(element:, point:)` on WindowManipulator -- AX-based, needs AXUIElement
- `getAXElement(pid:, windowID:)` on WindowManipulator -- returns AXUIElement?
- `focusWindow(pid:, windowID:)` on WindowManipulator -- full focus with yabai-style raise
- No MSSClient `moveWindow` method -- position changes go through AX API

### 2. StateManager (actor)
- `StateManager.shared` singleton pattern
- `getState() -> WindowManagerState` -- returns full state snapshot
- `WindowManagerState.windows` keyed by String(windowID) -- each has `pid`, `title`, `frame`, `displayUUID`
- `WindowManagerState.applications` keyed by String(pid) -- each has `bundleIdentifier`
- `WindowManagerState.metadata.activeDisplayUUID` -- tracks focused display
- `WindowManagerState.displays` -- array of `DisplayState` with `uuid`, `visibleFrame`
- To find Ghostty window: iterate `state.windows`, look up `state.applications[String(w.pid)]?.bundleIdentifier == "com.mitchellh.ghostty"`, then check `title?.contains("grid:scratch")`

### 3. Actor Pattern (GridRecorder as reference)
- Constructor injection (not setup() like plain classes)
- `let` dependencies (not `weak var` like classes -- actors can't do weak the same way)
- `init(gridState:, gridConfig:, stateManager:)` pattern
- Can hold `Process?` as state (GridRecorder does this for screen recording)

### 4. Reconciler Suppression
- `gridReconciler.setSuppressed(true, syncOnResume: false)` to suppress
- `gridReconciler.setSuppressed(false, syncOnResume: true)` to resume with border sync
- Used with `defer` in focus commands (line 154-155 of GridCommandRouter)
- GridReconciler is a plain class (not actor), so these calls are synchronous

### 5. Display UUID Access
- `wmState.metadata.activeDisplayUUID` gives current focused display UUID
- `WindowState.displayUUID` gives geometrically computed display UUID per window
- `DisplayState.visibleFrame` gives usable screen area for centering calculations
- NSScreen extension: `screen.displayID` gives `CGDirectDisplayID?`

### 6. Process Launching
- main.swift uses `Process()` with `executableURL` and `arguments` for pkill
- `try? killTask.run()` pattern with `waitUntilExit()`
- For Ghostty launch, plan calls for `open -na Ghostty.app --args ...`

### 7. XDG State Path
- `XDG.stateHome` resolves to `~/.local/state` (or `$XDG_STATE_HOME`)
- File path for frames: `"\(XDG.stateHome)/thegrid/terminal-frames.json"`
- GridState uses same pattern: `"\(XDG.stateHome)/thegrid/state.json"`

### 8. Moving Window Off-Screen
- No MSSClient method for moving windows. Must use AX API.
- `WindowManipulator.getAXElement(pid:, windowID:)` to get the element
- `WindowManipulator.setWindowPosition(element:, point:)` to move to (-10000, -10000)
- On show, same method to restore position
- `WindowManipulator.setWindowFrame(element:, frame:)` to set both position and size

### 9. GridCommandRouter Dispatch
- `dispatch(_ command: String) -> CommandResult` is the single entry point
- `case "terminal":` at line 173 -- currently posts notification, returns `.ok("terminal toggled")`
- Phase 2 will replace this with `await terminalManager.toggle()`
- GridTerminalManager needs to return `CommandResult` or be void (router wraps)

### 10. Feature Module Patterns
- Plain classes (GridFocus, GridResize): empty init + `setup()` with weak refs
- Actors (GridRecorder, GridState): constructor injection with `let` dependencies
- GridTerminalManager is an actor -- follow GridRecorder pattern

## Gaps

1. **WindowManipulator is not an actor** -- calling its methods from an actor requires careful handling. The AX methods are synchronous. The `mssClient` methods are also synchronous (dispatch to internal queue). This is fine -- actors can call synchronous methods on non-actor classes.

2. **GridReconciler reference** -- The plan says to inject reconciler for suppression. GridReconciler is a plain class, not Sendable. The actor will need to store it and call `setSuppressed` from within the actor. Since `setSuppressed` is synchronous and GridReconciler is a class, this should work but may need `@unchecked Sendable` or `nonisolated` access.

3. **Window frame on hide** -- When we move the window to (-10000, -10000), StateManager's poll will update the frame to that position. On show, we need our own saved frame (per-display), not StateManager's frame. This is correctly handled by the plan's per-display frame persistence.

4. **AX element lookup for Ghostty** -- WindowManipulator has a Ghostty-specific fallback at line 74-76: if only one AX window exists, it uses it (handles Ghostty's phantom window IDs). This is helpful for our use case.

## Prerequisites
- [x] Target file does not exist (confirmed)
- [x] WindowManipulator API available (setWindowOpacity, setWindowPosition, etc.)
- [x] StateManager.getState() available for window lookup
- [x] Actor pattern reference exists (GridRecorder)
- [x] Reconciler suppression API available
- [x] XDG state path resolution available
- [x] Display UUID accessible from state metadata and window state
- [x] Process launching pattern exists in codebase

## Recommendation
**BUILD** -- All prerequisites are met. No plan adjustments needed. The discovery confirms every API and pattern referenced in the plan exists and works as expected.
