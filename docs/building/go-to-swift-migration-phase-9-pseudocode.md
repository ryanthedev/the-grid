# Pseudocode: Phase 9 - RPC Handlers for Thin CLI

## Design: RPC Registration Approach

### Approaches Considered
1. **Route all through dispatch()** -- every RPC calls `commandRouter.dispatch("@focus left")` and wraps `CommandResult` as `Response`
2. **Call feature modules directly** -- every RPC extracts params and calls the right module method, returning structured JSON
3. **Hybrid** -- action RPCs use `dispatch()` for simplicity; query RPCs call modules directly for structured responses

### Comparison
| Criterion | A (dispatch) | B (direct) | C (hybrid) |
|-----------|-------------|-----------|------------|
| Interface simplicity | High (one pattern) | Low (per-RPC code) | Medium |
| Structured responses | Poor (only string) | Full | Full where needed |
| Code duplication | None | Duplicates router logic | Minimal |
| Caller ease of use | Poor for queries | Good | Good |

### Choice: C (Hybrid)
Action RPCs (`grid.focus`, `grid.cell.send`, etc.) delegate to `commandRouter.dispatch()` -- they only need success/error + message.
Query RPCs (`grid.state.show`, `grid.layout.list`, `grid.layout.current`, `grid.layout.get`, `grid.config.show`) call modules directly for structured JSON responses.
Mutation RPCs (`grid.layout.update`, `grid.layout.save`) are stubbed (require GridConfig write support not yet built).

### Depth Check
- Interface methods: 1 public method (`registerGridHandlers`)
- Hidden details: param extraction, dispatch routing, result conversion
- Common case complexity: simple (each RPC is a few lines of glue)

## Files to Create/Modify

1. **Modify `MessageHandler.swift`** -- add `registerGridHandlers(router:gridState:gridConfig:stateManager:)` method
2. **Modify `GridState.swift`** -- add `exportState()` returning `GridRuntimeStateData`
3. **Modify `main.swift`** -- call `messageHandler.registerGridHandlers(...)` after `commandRouter` is created

## Pseudocode

### MessageHandler.swift -- registerGridHandlers

```
func registerGridHandlers(router, gridState, gridConfig, stateManager):

    // ============================================================
    // Helper: convert dispatch result to RPC response
    // ============================================================

    // Build a "@domain action args --flags" string from RPC params
    // Call router.dispatch() with it
    // Convert CommandResult to Response (success -> result JSON, error -> ErrorInfo)

    helper dispatchAndRespond(request, commandString):
        Task:
            result = await router.dispatch(commandString)
            if result.success:
                respond with { "ok": true, "message": result.message }
            else:
                respond with ErrorInfo(code: -32000, message: result.message)

    // ============================================================
    // Helper: build command string from RPC params
    // ============================================================

    // For action RPCs, build the @ command string from JSON params:
    //   { "direction": "left", "wrap": true, "mouse": true }
    //   -> "@focus left --wrap --mouse"

    helper buildCommand(domain, action, params):
        parts = ["@" + domain]
        if action is not empty:
            append action
        if params has "direction":
            append params["direction"]
        if params has positional args (like layoutID, cellID):
            append those
        for each boolean flag in params (wrap, extend, mouse, cell, all):
            if flag is true: append "--" + flagName
        for each value flag (strategy, space, display, amount):
            append "--" + key + " " + value
        return joined parts

    // ============================================================
    // ACTION RPCs -- delegate to router.dispatch()
    // ============================================================

    // grid.focus -- { direction: "left"|"right"|"up"|"down", wrap?: bool, extend?: bool, mouse?: bool }
    register "grid.focus":
        extract direction from params (required)
        build command "@focus <direction> [--wrap] [--extend] [--mouse]"
        dispatchAndRespond

    // grid.focus.cycle -- { forward?: bool }
    register "grid.focus.cycle":
        action = if params.forward is false then "prev" else "next"
        build command "@focus <action>"
        dispatchAndRespond

    // grid.focus.cell -- { cell: string, space?: string }
    register "grid.focus.cell":
        extract cell from params (required)
        build command "@focus cell <cellID> [--space <spaceID>]"
        dispatchAndRespond

    // grid.layout.apply -- { layout: string, strategy?: string }
    register "grid.layout.apply":
        extract layout from params (required)
        build command "@layout apply <layoutID> [--strategy <s>]"
        dispatchAndRespond

    // grid.layout.refresh -- { display?: string }
    register "grid.layout.refresh":
        build command "@layout refresh [--display <uuid>]"
        dispatchAndRespond

    // grid.layout.cycle -- {}
    register "grid.layout.cycle":
        build command "@layout cycle"
        dispatchAndRespond

    // grid.cell.send -- { direction: string }
    register "grid.cell.send":
        extract direction from params (required)
        build command "@cell send <direction>"
        dispatchAndRespond

    // grid.cell.mode -- { mode?: string }
    register "grid.cell.mode":
        mode = params["mode"] or empty
        build command "@cell mode [<mode>]"
        dispatchAndRespond

    // grid.window.move -- { direction: string, wrap?: bool, extend?: bool }
    register "grid.window.move":
        extract direction from params (required)
        build command "@window move <direction> [--wrap] [--extend]"
        dispatchAndRespond

    // grid.window.swap -- { direction: string }
    register "grid.window.swap":
        extract direction from params (required)
        build command "@cell swap <direction>"
        dispatchAndRespond

    // grid.resize.adjust -- { delta: double, cell?: bool, direction?: string }
    register "grid.resize.adjust":
        extract delta from params (required, positive = grow, negative = shrink)
        if delta >= 0: action = "grow", amount = delta
        else: action = "shrink", amount = abs(delta)
        build command "@resize <action> <amount> [--cell] [--direction <dir>]"
        dispatchAndRespond

    // grid.resize.cell -- { direction: string, delta: double }
    register "grid.resize.cell":
        extract direction and delta
        if delta >= 0: action = "grow" else action = "shrink"
        build command "@resize <action> <abs(delta)> --cell --direction <dir>"
        dispatchAndRespond

    // grid.resize.reset -- { cell?: bool, all?: bool }
    register "grid.resize.reset":
        build command "@resize reset [--cell] [--all]"
        dispatchAndRespond

    // grid.state.reset -- {}
    register "grid.state.reset":
        build command "@state reset"
        dispatchAndRespond

    // ============================================================
    // QUERY RPCs -- call modules directly for structured responses
    // ============================================================

    // grid.layout.current -- {} -> { layout: string, space: string }
    register "grid.layout.current":
        Task:
            get wmState from stateManager
            find active space ID
            currentLayoutID = await gridState.getCurrentLayout(spaceID)
            respond with { layout: currentLayoutID, space: spaceID }

    // grid.layout.list -- {} -> { layouts: [string] }
    register "grid.layout.list":
        Task:
            layoutIDs = await MainActor.run { gridConfig.getLayoutIDs() }
            respond with { layouts: layoutIDs }

    // grid.layout.get -- { layout: string } -> { layout: <full layout def as JSON> }
    register "grid.layout.get":
        Task:
            extract layoutID from params (required)
            try layoutDef = await MainActor.run { gridConfig.getLayout(id: layoutID) }
            // Convert GridLayoutDef to dictionary representation
            respond with layout def as JSON

    // grid.layout.update -- { layout: string, ... } -> stub for now
    register "grid.layout.update":
        respond with ErrorInfo "not yet implemented"

    // grid.layout.save -- {} -> stub for now
    register "grid.layout.save":
        respond with ErrorInfo "not yet implemented"

    // grid.state.show -- {} -> { state: <full grid state JSON> }
    register "grid.state.show":
        Task:
            stateData = await gridState.exportState()
            // Encode GridRuntimeStateData to JSON dictionary
            // respond with the full state
            respond with { state: encoded state data }

    // grid.config.show -- {} -> { config: <summary of grid config> }
    register "grid.config.show":
        Task:
            summary = await MainActor.run { gridConfig.exportSummary() }
            respond with { config: summary }

    // grid.record.start -- stub until Phase 11
    register "grid.record.start":
        respond with ErrorInfo "recording not yet implemented"
```

### GridState.swift -- exportState()

```
// Add public method to GridState actor

func exportState() -> GridRuntimeStateData:
    return GridRuntimeStateData(
        version: GridState.stateVersion,
        spaces: spaces,
        displaySpaces: displaySpaces,
        lastUpdated: lastUpdated
    )
```

### GridConfig.swift -- exportSummary()

```
// Add public method to GridConfig (MainActor)

func exportSummary() -> [String: Any]:
    return {
        "layouts": layouts.map { ["id": $0.id, "name": $0.name] },
        "spaces": spaces dictionary keys,
        "appRules": appRules count,
        "settings": {
            "baseSpacing": settings.baseSpacing,
            "basePadding": settings.basePadding description,
            ... other relevant settings
        }
    }
```

### GridLayoutDef -- toDict() helper

```
// Add to GridTypes.swift or as extension

extension GridLayoutDef:
    func toDict() -> [String: Any]:
        return {
            "id": id,
            "name": name,
            "grid": { "columns": grid column descriptions, "rows": grid row descriptions },
            "cells": cells.map { cell dict with id, column, row, spans },
            "cellModes": cellModes,
            "padding": padding description,
            "windowSpacing": windowSpacing description
        }
```

### main.swift -- wiring

```
// After commandRouter is created (around line 170):

messageHandler.registerGridHandlers(
    router: commandRouter,
    gridState: gridState,
    gridConfig: gridConfig,
    stateManager: StateManager.shared
)
```

## Design Notes

1. **Hybrid dispatch approach**: Action RPCs build a command string and delegate to `GridCommandRouter.dispatch()`, which already has all the error handling and domain routing. Query RPCs call modules directly because they need structured JSON responses that `CommandResult.message` cannot carry.

2. **No new types needed**: The existing `register(method:handler:)` pattern, `AnyCodable`, `Response`, and `ErrorInfo` are sufficient. `CommandResult` is the bridge for action RPCs.

3. **Stubs for Phase 11 dependency**: `grid.record.start` is stubbed. `grid.layout.update` and `grid.layout.save` are stubbed because GridConfig does not support runtime mutation of layout definitions (it loads from YAML).

4. **State export via Codable**: `GridRuntimeStateData` is already `Codable`. For the `state.show` RPC, we encode it to JSON via `JSONEncoder`, then deserialize to `[String: Any]` for `AnyCodable` wrapping. Alternatively, we can return the raw JSON string.

5. **Thread safety**: All `gridState` calls are actor-isolated (automatic). `gridConfig` calls must be on `MainActor` (already the pattern throughout the codebase).

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (hybrid dispatch approach chosen with comparison)
- [x] Ready for implementation
