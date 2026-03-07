# Discovery: Phase 5 - Focus Navigation

## Files Found

### Go Source (to port)
- `/Users/r/repos/theGrid/grid-cli/internal/focus/focus.go` (933 lines)
  - `CycleFocus()` — cycle next/prev window within a cell
  - `FocusWindow()` — RPC call to server (will become direct AX call)
  - `MoveFocus()` — move focus to adjacent cell, with wrap and cross-display
  - `moveFocusCrossDisplay()` — cross-display focus with visual position mapping
  - `FocusCell()` / `focusCellByID()` — focus a specific cell by ID, restores last-focused window
  - `FindAdjacentDisplay()` — find display in direction with 5px edge tolerance
  - `FindOppositeDisplay()` — wrap-around display selection
  - `FindWrapTarget()` — find cells on opposite edge for wrap within display
  - `PickClosestCell()` — closest cell by center distance, cell ID tiebreaker
  - `MatchVisualPosition()` — normalized coordinate mapping between displays
  - `FindClosestCellToPoint()` — closest cell to arbitrary point
  - `SelectCrossDisplayTargetCell()` — last-focused-cell or closest with visual mapping
  - `GetDisplayCells()` — calculate cell bounds for a display's active space
  - `filterByEdge()` — helper for wrap target selection
  - `overlapsVertically()` / `overlapsHorizontally()` — geometric helpers (already in GridLayout.swift)
  - `MoveFocusOpts` — options struct (WrapAround, Extend)

### Swift Dependencies (already built)
- `Grid/GridTypes.swift` — `GridDirection` enum (matches Go's `types.Direction`)
- `Grid/GridConfig.swift` — `@MainActor GridConfig`, `getLayout(id:)`, `getBaseSpacing()`
- `Grid/GridState.swift` — `actor GridState`, focus tracking (`setFocus`, `getFocusedCell`, `getFocusedWindow`, `getWindowCell`, `getCellWindows`, `getSpaceReadOnly`, `getWindowAssignments`, `getCurrentLayout`, `getColumnRatios`, `getRowRatios`)
- `Grid/GridLayout.swift` — `GridLayout.calculateLayoutWithRatios()`, `GridLayout.getAdjacentCells()`, CGRect extensions (`overlapsVertically`, `overlapsHorizontally`, `center`)
- `Grid/GridReconciler.swift` — `syncBordersForSpace()` (private), border sync happens via reconciler events
- `WindowManipulator.swift` — `focusWindow(pid:windowID:)` (direct AX, no RPC needed)
- `StateModels.swift` — `WindowManagerState`, `DisplayState` (has `uuid`, `currentSpaceID`, `frame`, `visibleFrame`), `SpaceState`, `WindowState`
- `StateManager.swift` — `getState()` returns `WindowManagerState`

### Target File (to create)
- `Grid/GridFocus.swift` — does not exist yet

## Current State

All dependencies from Phases 1-4 are built and available:
- `GridLayout.getAdjacentCells()` exists and returns `[GridDirection: [String]]`
- `GridLayout.calculateLayoutWithRatios()` exists and returns `GridCalculatedLayout` with `cellBounds: [String: CGRect]`
- CGRect extensions for `overlapsVertically`, `overlapsHorizontally`, `center` already exist in GridLayout.swift
- `WindowManipulator.focusWindow(pid:windowID:)` already does the AX focus (SkyLight PSN + event synthesis + AX raise)
- `GridState` actor has all the focus tracking methods needed
- `GridConfig` is `@MainActor` -- layout lookups need `await MainActor.run { ... }`

## Gaps

1. **Go uses RPC for focus; Swift calls AX directly.** `FocusWindow()` in Go does `c.CallMethod("window.focus")` then falls back to `c.CallMethod("window.raise")`. In Swift, we call `WindowManipulator.focusWindow(pid:windowID:)` directly. Need the WindowManipulator instance and window's PID (from StateManager).

2. **Go uses `client.Client` + `server.Snapshot`; Swift uses `StateManager` + `GridState` actors.** The Go `Snapshot` struct has `SpaceID`, `FocusedWindowID`, `AllDisplays`, `Windows`. In Swift, this information comes from `await stateManager.getState()` which returns `WindowManagerState`.

3. **Mouse warp not in Go focus.go.** The plan mentions `CGWarpMouseCursorPosition` but Go's focus.go doesn't do mouse warping. This is likely a separate concern (moved from elsewhere or new). Will include as an optional post-focus action.

4. **AX serial queue.** Plan says "Call WindowManipulator via dedicated AX serial queue (no RPC)." WindowManipulator doesn't currently have a serial queue -- its methods are synchronous AX calls. The serial queue concern is for Phase 6 (parallel placement). For focus, calls are one-at-a-time from hotkey dispatch, so no queue needed here.

5. **Border sync after cross-display focus.** Go explicitly calls `reconcile.SyncBordersForDisplay()` and `reconcile.SyncBorderFocus()`. In Swift, the reconciler subscribes to focus events and handles border sync automatically via `handleFocusChanged()`. No need for explicit border sync in GridFocus -- the reconciler handles it.

6. **`GetDisplayCells()` in Go computes layout for a display.** In Swift this is a composition of `GridState.getCurrentLayout()` + `GridConfig.getLayout()` + `GridLayout.calculateLayoutWithRatios()`. Will be a helper method in GridFocus.

## Prerequisites
- [x] GridTypes.swift exists with GridDirection
- [x] GridConfig.swift exists with getLayout(), getBaseSpacing()
- [x] GridState.swift exists with focus tracking methods
- [x] GridLayout.swift exists with calculateLayoutWithRatios(), getAdjacentCells()
- [x] GridReconciler.swift exists and handles focus events
- [x] WindowManipulator.swift exists with focusWindow()
- [x] StateManager.swift exists with getState()
- [x] StateModels.swift exists with DisplayState, WindowManagerState

## Recommendation
**BUILD** — All prerequisites are met. Create `Grid/GridFocus.swift` porting Go's focus.go logic, adapted to Swift's actor/async model. Key simplification: border sync is handled by the reconciler automatically (no explicit calls needed). Focus calls use WindowManipulator directly instead of RPC.
