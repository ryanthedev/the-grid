# Discovery: Phase 8 - BFD @ Command Router

## Files Found

### Target files (to create/modify)
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` -- DOES NOT EXIST, create
- `grid-server/Sources/GridServer/BFD/BFDManager.swift` -- EXISTS (188 lines)
- `grid-server/Sources/GridServer/main.swift` -- EXISTS, needs wiring

### Dependency files (Phase 1-7, all exist)
- `Grid/GridFocus.swift` -- class GridFocus, 3 public methods: `moveFocus(direction:opts:)`, `cycleFocus(forward:)`, `focusCell(spaceID:cellID:)`
- `Grid/GridCellOps.swift` -- class GridCellOps, 3 public methods: `sendWindow(direction:)`, `swapWindow(direction:)`, `setMode(targetMode:)`
- `Grid/GridWindowMove.swift` -- class GridWindowMove, 1 public method: `moveWindow(direction:opts:)`
- `Grid/GridApply.swift` -- class GridApply, 4 public methods: `applyLayout(spaceID:layoutID:strategy:)`, `reapplyLayout(spaceID:strategy:)`, `applyCellLayout(spaceID:cellID:)`, `refreshAllDisplays(displayFilter:)`
- `Grid/GridResize.swift` -- class GridResize, 4 public methods: `adjustFocusedSplit(spaceID:delta:)`, `resetSplits(spaceID:allCells:)`, `adjustCellBoundary(spaceID:direction:delta:)`, `resetCellRatios(spaceID:)`
- `Grid/GridState.swift` -- actor GridState, has `cycleLayout()`, `previousLayout()`, `getCurrentLayout()`, `getSpaceReadOnly()`
- `Grid/GridConfig.swift` -- `@MainActor class GridConfig`, has `getLayout(id:)`, `getLayoutIDs()`
- `Grid/GridTypes.swift` -- `GridDirection`, `GridStackMode` enums
- `Picker/PickerManager.swift` -- `PickerManager.shared.show()`

## Current State

### BFDManager.handleInternalCommand()
- Currently a simple `switch` on exact string matches: `"@pick"`, `"@test"`
- `@pick` dispatches to `PickerManager.shared.show()` on main queue
- `@test` dispatches to `TestPanel.shared.toggle()` on main queue
- Unknown commands logged as errors
- No parsing of arguments or flags

### Feature modules NOT wired in main.swift
- GridFocus, GridCellOps, GridWindowMove, GridApply, GridResize are defined but NOT instantiated or wired in `main.swift`
- Each has a `setup()` method taking weak references to dependencies
- Circular dependencies resolved via post-init `setApply()` calls (GridCellOps, GridWindowMove)

### Command vocabulary (from Go CLI)
| Domain | Actions | Go CLI equivalent |
|--------|---------|-------------------|
| focus | left/right/up/down, next, prev, cell | `focusLeftCmd`, `focusNextCmd`, `focusPrevCmd`, `focusCellCmd` |
| layout | apply, cycle, previous, refresh, current | `layoutApplyCmd`, `layoutRefreshCmd`, `layoutCurrentCmd` |
| cell | send, swap, mode | `cellSendCmd`, `windowSwapCmd`, `cellModeCmd` |
| window | move | `windowMoveLeftCmd` etc. |
| resize | grow, shrink, reset, cell | `resizeAdjustCmd`, `resizeResetCmd`, `resizeCellCmd` |
| mouse | center, warp | `mouseCenterCmd`, `mouseWarpCmd` |
| pick | show | `@pick` (already works) |
| state | show, reset | `stateShowCmd`, `stateResetCmd` |
| record | start, stop | `recordCmd` (Phase 11) |

## Gaps

1. **Feature modules not wired** -- GridFocus et al. exist but are not instantiated in `main.swift`. The router must create them or `main.swift` must be updated to create them and pass them to the router.
2. **`@pick` already handled** -- Currently hardcoded in BFDManager. Router should absorb this.
3. **`@test` command** -- Debug command, keep or drop? Keep for now, route through router.
4. **mouse domain** -- Mouse center/warp are simple CGWarpMouseCursorPosition calls. GridFocus already has `warpMouseToCell` (private). Need a small public method or inline in router.
5. **record domain** -- Phase 11, not yet implemented. Router should have a placeholder that returns an error.
6. **state domain** -- `state show` returns JSON, `state reset` clears state. These are simple GridState actor calls.
7. **Active space resolution** -- Most commands need the current active space ID. This is done via `GridFocus.findActiveSpaceID()`. The router needs to resolve this for commands that don't take an explicit space ID.

## Prerequisites
- [x] All feature modules exist (GridFocus, GridCellOps, GridWindowMove, GridApply, GridResize)
- [x] GridState actor with cycleLayout/previousLayout
- [x] GridConfig with getLayout/getLayoutIDs
- [x] BFDManager with handleInternalCommand
- [x] PickerManager.shared.show() working
- [ ] Feature modules need wiring in main.swift (will be done as part of this phase)

## Recommendation
**BUILD** -- Create GridCommandRouter.swift, modify BFDManager.handleInternalCommand, wire feature modules in main.swift.
