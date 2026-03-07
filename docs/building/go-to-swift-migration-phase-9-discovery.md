# Discovery: Phase 9 - RPC Handlers for Thin CLI

## Files Found

- `grid-server/Sources/GridServer/MessageHandler.swift` -- existing RPC handler registration (1300+ lines, 35+ existing handlers)
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` -- 534 lines, full `@` command dispatch with `ParsedCommand` parsing
- `grid-server/Sources/GridServer/Grid/GridState.swift` -- actor with `Codable` state model, `reset()`, per-space accessors
- `grid-server/Sources/GridServer/Grid/GridConfig.swift` -- `getLayout()`, `getLayoutIDs()`, layout YAML types all `Codable`
- `grid-server/Sources/GridServer/Grid/GridFocus.swift` -- `moveFocus()`, `cycleFocus()`, `focusCell()`
- `grid-server/Sources/GridServer/Grid/GridCellOps.swift` -- `sendWindow()`, `swapWindow()`, `setMode()`
- `grid-server/Sources/GridServer/Grid/GridWindowMove.swift` -- `moveWindow()`
- `grid-server/Sources/GridServer/Grid/GridApply.swift` -- `applyLayout()`, `reapplyLayout()`, `refreshAllDisplays()`
- `grid-server/Sources/GridServer/Grid/GridResize.swift` -- `adjustFocusedSplit()`, `resetSplits()`, `adjustCellBoundary()`, `resetCellRatios()`
- `grid-server/Sources/GridServer/main.swift` -- creates `messageHandler` (line 71) and `commandRouter` (line 152) but does NOT wire them together

## Current State

### MessageHandler Pattern
- `MessageHandler` has a `register(method:handler:)` method taking `(Request, (Response) -> Void) -> Void`
- All existing handlers are registered in `registerBuiltInHandlers()` (called from `init`)
- Async work uses `Task { ... }` inside the closure, calling `completion()` when done
- Error responses use `Response(id: request.id, error: ErrorInfo(code:message:))`
- Success responses use `Response(id: request.id, result: AnyCodable([...]))`
- 35 existing handlers (ping, echo, dump, window.*, space.*, borders.*, pick.show, etc.)

### GridCommandRouter Pattern
- Already has all the domain dispatch logic (focus, layout, cell, window, resize, mouse, state)
- Returns `CommandResult(success:message:)` -- simple success/error with message string
- Has `dispatch(_ command: String) async -> CommandResult` taking a raw `@` command string
- Has access to all feature modules (gridFocus, gridCellOps, gridWindowMove, gridApply, gridResize, gridState, gridConfig)

### Wiring Gap
- `main.swift` creates both `messageHandler` and `commandRouter` but does NOT connect them
- `messageHandler` has no reference to `commandRouter` or any Grid feature modules
- No `registerGridHandlers()` function exists yet

## Gaps

1. **No wiring between MessageHandler and GridCommandRouter** -- need to either:
   - (a) Pass `commandRouter` reference to `MessageHandler` and add `registerGridHandlers()`
   - (b) Register handlers externally in `main.swift` after both are created
   - (c) Create a separate registration function that takes both
2. **State export missing** -- `GridState` has no `exportState()` method for `state.show` RPC. The `persistNow()` builds `GridRuntimeStateData` but that is private. Need a public accessor.
3. **Config export missing** -- `GridConfig` has `getLayout()` and `getLayoutIDs()` but no full config dump for `config.show`.
4. **Layout update/save RPCs** -- `grid.layout.update` and `grid.layout.save` imply runtime layout mutation. `GridConfig` currently loads from YAML files but has no `updateLayout()` or `saveLayout()` methods. These may need to be deferred or stubbed.
5. **Record RPC** -- `grid.record.start` requires `GridRecorder` from Phase 11 (not yet built). Will stub.
6. **Return types** -- `CommandResult` only has `success` + `message` string. Some RPCs need structured JSON responses (e.g., `layout.list` returns layout IDs, `layout.current` returns current layout name, `state.show` returns full state). The RPC handlers need to call feature modules directly rather than going through `dispatch()` for these query RPCs.

## Prerequisites

- [x] GridCommandRouter exists with full domain dispatch
- [x] All feature modules exist (Focus, CellOps, WindowMove, Apply, Resize)
- [x] GridState actor exists with per-space accessors
- [x] GridConfig exists with layout access
- [x] MessageHandler has established RPC registration pattern
- [ ] GridState needs public state export method
- [ ] GridConfig needs public config summary method
- [ ] Layout update/save requires new GridConfig methods (or defer)

## Recommendation

**BUILD** -- with the following approach:
1. Add a `registerGridHandlers(router:)` method to `MessageHandler` (or as an extension)
2. Call it from `main.swift` after both `messageHandler` and `commandRouter` are created
3. For action RPCs (focus, cell.send, etc.) -- delegate to `commandRouter.dispatch()` and convert `CommandResult` to `Response`
4. For query RPCs (state.show, layout.list, layout.current, config.show) -- call feature modules directly since they need structured JSON, not just success/error strings
5. Add `exportState()` to `GridState` and config summary to `GridConfig`
6. Stub `grid.layout.update`, `grid.layout.save`, and `grid.record.start` (Phase 11 dependency)
