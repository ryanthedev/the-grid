# GridWM Layout Feature - Deviations from Spec

This document tracks any deviations from the original specifications in the `phases/` folder.

---

## Phase 0: Shared Types

### 2025-11-25 - No Deviations

**Summary:** Phase 0 was implemented exactly as specified in `PHASE0_SHARED_TYPES.md`.

All types, constants, and methods match the spec:
- StackMode, TrackType (string enums)
- Direction, AssignmentStrategy (int with iota)
- TrackSize, Cell, Layout, Rect, Point, CellBounds, WindowPlacement, CalculatedLayout (structs)
- Rect.Center(), Rect.Contains(), Direction.String(), ParseDirection() (methods)

**Files created:**
- `grid-cli/internal/types/layout_types.go`
- `grid-cli/internal/types/layout_types_test.go`

**Verification:**
- `go build ./...` - PASS
- `go test ./internal/types/... -v` - 8 tests PASS

---

## Phase 1: Config Parser

### 2025-11-25 - Minor Addition

**Summary:** Phase 1 was implemented as specified in `PHASE1_CONFIG_PARSER.md` with one addition.

**Spec said:** Only `LoadConfig(path)` for loading configuration.

**What I did:** Added `LoadConfigFromBytes(data, format)` helper function.

**Reason:** Makes testing easier without needing to write temporary files. Tests can pass YAML/JSON strings directly.

**Files created:**
- `grid-cli/internal/config/types.go`
- `grid-cli/internal/config/parser.go`
- `grid-cli/internal/config/validate.go`
- `grid-cli/internal/config/config.go`
- `grid-cli/internal/config/config_test.go`

**All spec features implemented:**
- YAML and JSON loading
- Track size parsing: "1fr", "2.5fr", "300px", "auto", "minmax(200px, 1fr)"
- Areas-to-cells conversion
- Full validation (duplicate IDs, rectangular areas, bounds checking)
- ToLayout() conversion to types.Layout

**Verification:**
- `go build ./...` - PASS
- `go test ./internal/config/... -v` - 17 tests PASS

---

## Phase 2: Grid Engine

### 2025-11-25 - Minor Improvements

**Summary:** Phase 2 was implemented following the spec structure with minor improvements.

**Improvements made:**

1. **Bounds checking in CalculateCellBounds**
   - Spec: No explicit bounds checking
   - What I did: Added validation for cell column/row indices
   - Reason: Prevents index out of bounds panics for invalid cell definitions
   - Returns zero Rect for invalid cells instead of crashing

2. **Used standard library sort**
   - Spec: Manual bubble sort in SortCellsByPosition
   - What I did: Used `sort.Slice()` from standard library
   - Reason: Cleaner, more idiomatic Go, same O(n log n) complexity

3. **Simplified applyMinMaxConstraints signature**
   - Spec: `applyMinMaxConstraints(tracks, sizes, available)` with unused `available` param
   - What I did: `applyMinMaxConstraints(tracks, sizes)` without unused param
   - Reason: The available parameter wasn't used in the implementation

**All spec features implemented:**
- Track calculation for all types (fr, px, auto, minmax)
- Cell bounds with gap handling and multi-track spanning
- Window stacking (vertical, horizontal, tabs) with split ratios
- Helper functions: GetCellAtPoint, GetAdjacentCells, SortCellsByPosition
- NormalizeRatios, CalculateAllWindowPlacements

**Files created:**
- `grid-cli/internal/layout/grid.go`
- `grid-cli/internal/layout/cells.go`
- `grid-cli/internal/layout/windows.go`
- `grid-cli/internal/layout/grid_test.go`
- `grid-cli/internal/layout/cells_test.go`
- `grid-cli/internal/layout/windows_test.go`

**Verification:**
- `go build ./...` - PASS
- `go test ./internal/layout/... -v` - 40 tests PASS

---

## Phase 3: State Manager

### 2025-11-25 - Minor Improvements

**Summary:** Phase 3 was implemented following the spec structure with minor improvements.

**Improvements made:**

1. **Return copies from query functions**
   - Spec: Returns slices directly
   - What I did: `GetCellWindows`, `GetCellSplitRatios`, `GetWindowAssignments` return copies
   - Reason: Prevents external modification of internal state

2. **Consolidated test file**
   - Spec: Suggested 3 separate test files
   - What I did: Single `state_test.go` with all tests organized by section
   - Reason: Tests are closely related and not too large; easier to navigate

3. **Initialize nested maps in LoadStateFrom**
   - Spec: Only initializes top-level Spaces map
   - What I did: Also initializes Cells map for each space
   - Reason: Prevents nil pointer panics when accessing cells after loading

**All spec features implemented:**
- RuntimeState, SpaceState, CellState types
- Window assignment with auto-equalizing split ratios
- Layout cycling (next/previous)
- Focus tracking
- Atomic file persistence with temp file + rename
- All query helpers

**Files created:**
- `grid-cli/internal/state/state.go`
- `grid-cli/internal/state/persistence.go`
- `grid-cli/internal/state/queries.go`
- `grid-cli/internal/state/state_test.go`

**Verification:**
- `go build ./...` - PASS
- `go test ./internal/state/... -v` - 31 tests PASS

---

## Phase 4: Window Assignment

### 2025-11-25 - Minor Improvements

**Summary:** Phase 4 was implemented following the spec structure with minor improvements.

**Improvements made:**

1. **Added `matchesAppRule()` helper function**
   - Spec: Inline matching of AppName/BundleID
   - What I did: Extracted to a helper function
   - Reason: Reduces code duplication in shouldFloat() and getPreferredCell()

2. **Added `PreviousLayout()` function**
   - Spec: Only CycleLayout() (forward cycling)
   - What I did: Added PreviousLayout() for backward cycling
   - Reason: Symmetry with CycleLayout(), useful for keybinding both directions

3. **Consolidated test file**
   - Spec: Suggested separate test files
   - What I did: Single `assignment_test.go` with all tests
   - Reason: Tests are focused on assignment logic; apply/reconcile are hard to unit test without mock server

**All spec features implemented:**
- Window-to-cell assignment strategies (AutoFlow, Pinned, Preserve)
- Floating window detection via app rules
- Excluded window detection (minimized, hidden, high level)
- ApplyLayout orchestration (13-step process)
- Layout cycling
- State reconciliation (ReconcileState, CheckForNewWindows, GetStaleWindows)

**Files created:**
- `grid-cli/internal/layout/assignment.go`
- `grid-cli/internal/layout/apply.go`
- `grid-cli/internal/layout/reconcile.go`
- `grid-cli/internal/layout/assignment_test.go`

**Verification:**
- `go build ./...` - PASS
- `go test ./internal/layout/... -v` - 59 tests PASS (40 from Phase 2 + 19 new)

---

## Phase 5: CLI Commands

### 2025-11-25 - Stub Implementation for Dependencies

**Summary:** Phase 5 was implemented with stub commands for focus/resize that depend on Phases 6 & 7.

**Deviations:**

1. **Focus and resize commands are stubs**
   - Spec: All commands fully functional
   - What I did: Focus and resize commands return "not yet implemented" errors
   - Reason: These depend on Phase 6 (Focus Navigation) and Phase 7 (Split Ratios)

2. **Combined into existing main.go**
   - Spec: Suggests separate files (layout.go, config.go, etc.)
   - What I did: Added all commands to existing main.go
   - Reason: Follows existing monolithic pattern in the codebase

3. **Import aliases for new packages**
   - Spec: Standard imports
   - What I did: Used aliases (`gridConfig`, `gridLayout`, `gridState`, `gridTypes`)
   - Reason: Avoids conflicts with existing variables/commands named `config`, `layout`, etc.

**All spec commands implemented:**
- `grid layout list/show/apply/cycle/current` - Full implementation
- `grid config show/validate/init` - Full implementation
- `grid state show/reset` - Full implementation
- `grid focus left/right/up/down/next/prev/cell` - Stubs
- `grid resize grow/shrink/reset` - Stubs

**Files modified:**
- `grid-cli/cmd/grid/main.go` - Added 15 new commands

**Verification:**
- `go build ./...` - PASS
- `go test ./...` - All tests PASS

---

## Phase 6: Focus Navigation

### 2025-11-25 - Minor Improvements

**Summary:** Phase 6 was implemented following the spec structure with minor improvements.

**Improvements made:**

1. **Smarter wrap-around edge detection**
   - Spec: Simple wrap to opposite cell
   - What I did: Edge detection using 10% threshold of grid range
   - Reason: Handles grids where cells don't perfectly align on edges

2. **Additional helper functions**
   - Spec: Basic navigation functions
   - What I did: Added `NextWindowInCell`, `PrevWindowInCell`, `FirstWindowInCell`, `HasMultipleWindows`
   - Reason: Convenience functions that simplify common operations

3. **Duplicated helper functions in focus package**
   - Spec: Import from layout/apply.go
   - What I did: Duplicated `getCurrentSpaceID`, `getDisplayBoundsForSpace`, `toFloat64`
   - Reason: Package independence - focus package doesn't depend on layout package for these utilities

**All spec features implemented:**
- Directional navigation with weighted distance (primary + perpendicular*2)
- Wrap-around navigation to opposite edge
- Window cycling within cells
- Focus tracking in state (FocusedCell, FocusedWindow)
- Server integration (window.focus with window.raise fallback)

**Files created:**
- `grid-cli/internal/focus/focus.go` - Main orchestration
- `grid-cli/internal/focus/navigation.go` - Direction algorithms
- `grid-cli/internal/focus/within_cell.go` - Window cycling
- `grid-cli/internal/focus/focus_test.go` - Tests (27 tests)

**CLI commands updated:**
- `grid focus left|right|up|down` - Move to adjacent cell (was stub)
- `grid focus next|prev` - Cycle within cell (was stub)
- `grid focus cell <id>` - Jump to cell (was stub)

**Verification:**
- `go build ./...` - PASS
- `go test ./internal/focus/... -v` - 27 tests PASS
- `go test ./...` - All tests PASS

---

## Phase 7: Split Ratios

### 2025-11-25 - Minor Improvements

**Summary:** Phase 7 was implemented following the spec structure with minor improvements.

**Improvements made:**

1. **Reused existing functions**
   - Spec: Create new `InitializeSplitRatios` and `NormalizeSplitRatios` functions
   - What I did: Delegated to existing `equalRatios()` and `NormalizeRatios()` in windows.go
   - Reason: Avoids code duplication, maintains consistency

2. **Added `--all` flag to reset command**
   - Spec: Only `ResetSplits` for focused cell
   - What I did: Added `ResetAllSplits` + CLI `--all` flag
   - Reason: Convenience for resetting entire layout at once

3. **Improved error handling in resize**
   - Spec: Basic error messages
   - What I did: Added ratio initialization check before adjusting
   - Reason: Handles case where splits aren't initialized yet

**All spec features implemented:**
- Equal ratio initialization
- Ratio normalization (sum to 1.0)
- Split adjustment with minimum ratio (10%) enforcement
- Recalculation after window removal/addition/reorder
- Boundary position calculation
- CLI commands: `grid resize grow|shrink [amount]`, `grid resize reset [--all]`

**Files created:**
- `grid-cli/internal/layout/splits.go` - Pure ratio functions
- `grid-cli/internal/layout/resize.go` - Orchestration
- `grid-cli/internal/layout/splits_test.go` - Tests (17 tests)

**CLI commands updated:**
- `grid resize grow [amount]` - Grow focused window (was stub)
- `grid resize shrink [amount]` - Shrink focused window (was stub)
- `grid resize reset [--all]` - Reset to equal splits (was stub)

**Verification:**
- `go build ./...` - PASS
- `go test ./internal/layout/... -v` - 76 tests PASS (59 from previous + 17 new)
- `go test ./...` - All tests PASS

---

## All Phases Complete!

The GridWM layout feature is now fully implemented across all 7 phases.
