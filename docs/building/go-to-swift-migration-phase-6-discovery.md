# Discovery: Phase 6 - Cell Operations + Window Move + Layout Apply

## Files Found

### Go Source Files (to port)
- `grid-cli/internal/cell/send.go` (114 lines) -- SendWindow, pickClosestCell
- `grid-cli/internal/cell/swap.go` (165 lines) -- SwapWindow, calculateSwapTarget, getEffectiveStackMode
- `grid-cli/internal/cell/mode.go` (116 lines) -- SetMode, NextMode, GetEffectiveMode, ParseStackMode
- `grid-cli/internal/window/move.go` (566 lines) -- MoveWindow, moveWindowToCell, moveWindowCrossDisplay
- `grid-cli/internal/layout/apply.go` (747 lines) -- ApplyLayout, ReapplyLayout, ApplyCellLayout, ApplyPlacements, RefreshAllDisplays, sendBorderConfig, sendCellAssignments, reconcileSpace

### Existing Swift Dependencies (Phases 1-5)
- `Grid/GridTypes.swift` -- GridDirection, GridStackMode, GridTrackSize, etc.
- `Grid/GridConfig.swift` -- @MainActor, getLayout(), getBaseSpacing(), getSettingsPadding(), getSettingsWindowSpacing(), getDisplayOffset(), getWindowExclusions(), getLayoutIDs(), getSpaceConfig(), appRules
- `Grid/GridState.swift` -- actor, full API: getSpace(), assignWindow(), prependWindow(), removeWindow(), setFocus(), getFocusedWindow(), getFocusedCell(), getCellStackMode(), setCellStackMode(), getWindowCell(), getCellWindows(), getWindowAssignments(), setWindowAssignments(), getColumnRatios(), getRowRatios(), setCurrentLayout(), cycleLayout(), hasState()
- `Grid/GridLayout.swift` -- enum with static functions: calculateLayout(), calculateLayoutWithRatios(), getAdjacentCells(), calculateAllWindowPlacements(), adjustRatiosForWindowCount()
- `Grid/GridAssignment.swift` -- assignWindows(windows:layout:cellBounds:appRules:previousAssignments:strategy:bundleIDLookup:), classifyWindow(), isTileable()
- `Grid/GridReconciler.swift` -- setSuppressed(), syncBordersForCurrentSpace() (private), syncBordersForSpace() (private)
- `Grid/GridFocus.swift` -- moveFocus(), cycleFocus(), focusCell(); private helpers: findActiveSpaceID(), getDisplayBoundsForSpace(), findCurrentDisplayUUID(), findAdjacentDisplay(), findOppositeDisplay(), matchVisualPosition(), findClosestCellToPoint(), pickClosestCell(), findWrapTarget(), focusWindowByID(), getDisplayCells()
- `WindowManipulator.swift` -- setWindowFrame(context:frame:), focusWindow(pid:windowID:), moveWindowToSpace(), moveWindowToDisplay(), ManipulationContext.from(windowID:)
- `Borders/SimpleBorderManager.swift` -- setCellAssignments(), updateFocus()

### Files to Create
- `Grid/GridCellOps.swift` -- NEW
- `Grid/GridWindowMove.swift` -- NEW
- `Grid/GridApply.swift` -- NEW

## Current State

Phases 1-5 are complete. All foundation types, config, state, layout computation, assignment, reconciler, and focus navigation are built and working. The Swift infrastructure provides:

1. **GridState actor** with full cell manipulation API (assign, prepend, remove, focus tracking, split ratios)
2. **GridLayout enum** with pure computation functions (layout calc, window placements, adjacent cells)
3. **GridAssignment** with window classification and assignment strategies
4. **GridReconciler** with suppression flag already wired (`setSuppressed()`)
5. **GridFocus** with cross-display navigation (private helpers for display lookup, visual position mapping)
6. **WindowManipulator** with AX frame setting and space movement
7. **SimpleBorderManager** with `setCellAssignments()` for border sync

## Gaps

### 1. Cross-display helpers are private to GridFocus
`findAdjacentDisplay`, `findOppositeDisplay`, `matchVisualPosition`, `findClosestCellToPoint`, `getDisplayCells`, `findWrapTarget`, `pickClosestCell`, `findActiveSpaceID`, `getDisplayBoundsForSpace`, `findCurrentDisplayUUID` -- all private to GridFocus. GridWindowMove needs similar cross-display logic for window moves.

**Resolution:** Extract shared display/cell helpers from GridFocus into internal (non-private) methods, OR duplicate the needed subset in GridWindowMove. Given the plan says "uses same adjacency logic as focus movement," extraction is cleaner. Alternative: make GridWindowMove delegate to GridFocus for the cross-display lookup portion and only handle the move state mutation itself.

**Chosen approach:** Make the relevant GridFocus helpers `internal` (drop `private`). The helpers are stateless pure functions (or simple StateManager queries). This is the minimal-change approach.

### 2. Go ApplyPlacements uses goroutines + cloned client connections
In Go, `ApplyPlacements` spawns goroutines that each clone the socket client. In Swift, we call `WindowManipulator.setWindowFrame(context:frame:)` which uses AX directly. AX calls must be serialized (per plan: dedicated AX serial queue). But we can use `TaskGroup` with AX calls serialized through a DispatchQueue.

**Resolution:** Use `withTaskGroup` for parallel work (looking up ManipulationContext), but serialize AX `setWindowFrame` calls through a serial DispatchQueue (or just do them sequentially since AX is fast per-window).

### 3. Go RefreshAllDisplays calls server.FetchForSpace() per display
The Go version makes an RPC call to fetch window state per space. In Swift, StateManager already has all window state in memory -- no fetch needed. We iterate `StateManager.displays` and build the equivalent state inline.

### 4. Border sync after apply
Go sends border config and cell assignments via RPC. In Swift, we call `SimpleBorderManager.setCellAssignments()` directly. The reconciler already has `syncBordersForSpace()` but it's private.

**Resolution:** GridApply will build the border assignments and call SimpleBorderManager directly, similar to how the reconciler does it. Or we can make `syncBordersForSpace` internal on the reconciler. Since GridApply's border sync is identical to reconciler's, making it `internal` is cleaner.

### 5. Go's tab-mode window raise after move
When moving a window out of a tabbed cell, Go raises the next visible window. In Swift, this maps to `WindowManipulator.focusWindow()` on the remaining window. Need to port this behavior.

### 6. GridConfig is @MainActor
All `GridConfig` access must be `await MainActor.run { ... }`. This is already handled by GridFocus and GridReconciler patterns -- follow the same approach.

## Prerequisites
- [x] GridTypes exists with GridDirection, GridStackMode, etc.
- [x] GridConfig exists with layout access, settings, display offsets
- [x] GridState actor exists with full cell manipulation API
- [x] GridLayout exists with calculation and placement functions
- [x] GridAssignment exists with window classification and assignment
- [x] GridReconciler exists with suppression flag
- [x] GridFocus exists with cross-display helpers (need visibility change)
- [x] WindowManipulator exists with AX frame setting
- [x] SimpleBorderManager exists with assignment API

## Recommendation
**BUILD** -- All prerequisites are met. Need minor visibility changes to GridFocus helpers and GridReconciler's syncBordersForSpace.
