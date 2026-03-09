# Discovery: Phase 1 - Server-side terminal toggle

## Files Found
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` -- target file, contains broken `case "terminal"` at line 174
- `grid-server/Sources/GridServer/MSSClient.swift` -- has `orderWindowOut`, `orderWindowToFront`, `moveWindowToSpace`, `setWindowLayer`, `focusWindow`
- `grid-server/Sources/GridServer/WindowManipulator.swift` -- has `focusWindow(pid:windowID:)`, exposes `mssClient` (internal access)
- `grid-server/Sources/GridServer/MacOSAPIs.swift` -- has `SLSWindowIsOrderedIn` wrapper at line 235
- `grid-server/Sources/GridServer/StateModels.swift` -- `WindowState.title`, `WindowState.pid`, `WindowState.spaces`, `ApplicationState.bundleIdentifier`
- `grid-server/Sources/GridServer/StateManager.swift` -- `getState() -> WindowManagerState`

## Current State
- `case "terminal"` at line 174 posts `NSDistributedNotification("com.thegrid.terminal.toggle")` but nothing listens for it
- The old GridTerminal binary (SwiftTerm-based) is gone; Ghostty is the terminal now
- All required primitives exist in `MSSClient` and `MacOSAPIs`:
  - `SLSWindowIsOrderedIn(cid, wid, &value)` -- checks visibility
  - `mssClient.orderWindowOut(wid)` -- hides window
  - `mssClient.orderWindowToFront(wid)` -- shows window
  - `mssClient.moveWindowToSpace(windowID:spaceID:)` -- moves to space
  - `mssClient.setWindowLayer(windowID:layer:)` -- sets layer (`.above`)
  - `windowManipulator.focusWindow(pid:windowID:)` -- full yabai-style focus with AX raise

## Data Model Notes
- `wmState.windows` is `[String: WindowState]` keyed by window ID string
- `wmState.applications` is `[String: ApplicationState]` keyed by PID string
- `WindowState.spaces` is `[UInt64]` (space IDs the window is on)
- `WindowState.title` is `String?`
- `ApplicationState.bundleIdentifier` is `String?`
- Active space: `wmState.metadata.activeSpaceID` (UInt64?) or via `gridFocus.findActiveSpaceID(wmState)` (returns String?)
- Connection ID: `wmState.metadata.connectionID` (Int32)

## Gaps
- No gaps. All APIs exist and are accessible from GridCommandRouter.
- `windowManipulator` and `stateManager` are already injected into the router.
- The router already uses `async` dispatch, so the poll loop in `launchTerminal` can use `Task.sleep`.

## Prerequisites
- [x] Target file exists (`GridCommandRouter.swift`)
- [x] All SkyLight/MSS APIs available
- [x] `WindowManipulator` and `StateManager` injected into router
- [x] `SLSWindowIsOrderedIn` wrapper exists in `MacOSAPIs.swift`
- [x] Window title and bundleID available in state models

## Recommendation
BUILD -- All primitives exist. Replace the broken notification-based toggle with direct window manipulation in GridCommandRouter.
