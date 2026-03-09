# Discovery: Phase 2 - Wire GridTerminalManager into Server

## Files Found

| File | Exists | Relevant Lines |
|------|--------|----------------|
| `grid-server/Sources/GridServer/main.swift` | Yes | 153-188: Feature module construction + router init + RPC registration |
| `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` | Yes | 31-78: Class + constructor, 173-175: terminal case (NSDistributedNotification) |
| `grid-server/Sources/GridServer/MessageHandler.swift` | Yes | 1349-1796: `registerGridHandlers()` with `dispatchAndRespond` pattern |
| `grid-server/Sources/GridServer/Grid/GridTerminalManager.swift` | Yes | Phase 1 output, actor with `init(windowManipulator:stateManager:gridReconciler:)` and `toggle() async -> CommandResult` |

## Current State

### main.swift (lines 153-188)
- Feature modules constructed at lines 154-158 (GridFocus, GridCellOps, GridWindowMove, GridApply, GridResize)
- `WindowManipulator` created at line 159
- `GridRecorder` created at lines 161-165
- `GridCommandRouter` constructed at lines 167-180 with 12 parameters
- `registerGridHandlers()` called at lines 183-188, passing `router`, `gridState`, `gridConfig`, `stateManager`
- `gridReconciler` is available in scope (created earlier in the file)

### GridCommandRouter.swift (lines 31-78, 173-175)
- Class (not actor) with 12 stored properties, 12 constructor parameters
- Terminal case at lines 173-175 posts `NSDistributedNotification("com.thegrid.terminal.toggle")` -- this is the dead code to replace
- No `terminalManager` property or parameter exists yet
- The `dispatch()` method at line 137 uses `parsed.domain` to switch on command domains

### MessageHandler.swift (lines 1349-1796)
- `registerGridHandlers()` takes 4 params: `router`, `gridState`, `gridConfig`, `stateManager`
- Inner helper `dispatchAndRespond()` wraps `router.dispatch(commandString)` in a Task and builds Response
- Inner helper `buildCommand()` constructs `@domain action` strings from RPC params
- Simple no-param RPCs (e.g., `grid.layout.cycle` at line 1504) just build a command string and call `dispatchAndRespond`
- Last handler: `grid.record.start` at line 1735
- `jlog("grid.rpc.registered")` at line 1795 marks end of function

### GridTerminalManager.swift
- Actor with constructor: `init(windowManipulator: WindowManipulator, stateManager: StateManager, gridReconciler: GridReconciler)`
- Single public method: `toggle() async -> CommandResult`
- Returns `CommandResult` (same type used by GridCommandRouter)

## Gaps

| Gap | Impact | Resolution |
|-----|--------|------------|
| GridCommandRouter has 12 params already | Adding `terminalManager` makes 13 -- above the 7-param guideline but consistent with existing pattern | Accept: router is a wiring hub, not a typical class. All other feature modules are already injected the same way. |
| `toggle()` returns `CommandResult` | Perfect fit -- the dispatch switch already returns `CommandResult` | No gap |
| Terminal case has no reconciler suppression | Plan says to suppress reconciler during toggle. But `GridTerminalManager.toggle()` already calls `gridReconciler.setSuppressed()` internally. The router case does NOT need to add suppression (unlike focus which does it at router level). | No additional work needed at router level |

## Prerequisites

- [x] GridTerminalManager.swift exists with correct constructor and toggle() method
- [x] main.swift has all dependencies available (windowManipulator, stateManager, gridReconciler)
- [x] GridCommandRouter pattern is clear (add property, constructor param, switch case)
- [x] MessageHandler RPC pattern is clear (register method, build command, dispatchAndRespond)
- [x] CommandResult type shared between router and terminal manager

## Recommendation
BUILD

Three targeted edits across three files:
1. `main.swift` -- construct GridTerminalManager, add to router constructor call
2. `GridCommandRouter.swift` -- add property + constructor param + replace terminal case body
3. `MessageHandler.swift` -- add `grid.terminal` RPC registration
