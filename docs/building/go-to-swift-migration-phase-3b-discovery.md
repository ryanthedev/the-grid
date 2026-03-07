# Discovery: Phase 3b - Window Assignment + Classification

## Files Found

### Go Source (to port)
- `grid-cli/internal/layout/assignment.go` (499 lines) -- all 4 assignment strategies, window classification, helper functions
- `grid-cli/internal/server/snapshot.go` -- `IsTileable()`, `FilterTileable()`, `IsExcluded()`, `MinTileableDimension`

### Existing Swift (dependencies)
- `Grid/GridTypes.swift` -- `GridAssignmentStrategy` enum (`.autoFlow`, `.pinned`, `.preserve`, `.position`), `GridCellDef`, `GridLayoutDef`
- `Grid/GridConfig.swift` -- `GridAppRule` (app, preferredCell, float, preferredStackMode), `GridWindowExclusion` (roles, subroles, apps), `GridConfig.getAppRule()`, `GridConfig.getWindowExclusions()`
- `Grid/GridState.swift` -- `GridSpaceStateData` with `cells: [String: GridCellStateData]`, where `GridCellStateData.windows: [UInt32]`
- `Grid/GridLayout.swift` -- `GridCalculatedLayout` (has `cellBounds: [String: CGRect]`), `GridLayout.sortCellsByPosition()` already exists
- `StateModels.swift` -- `WindowState` struct (server's native window representation with all AX properties: role, subrole, hasCloseButton, hasFullscreenButton, hasMinimizeButton, hasZoomButton, isModal, isMinimized, isHidden, level, frame, appName, pid, zOrder, displayUUID, spaces)

### Target File (to create)
- `Grid/GridAssignment.swift` -- does NOT exist yet

## Current State

### Type Mapping: Go -> Swift

| Go Type | Swift Type | Notes |
|---------|-----------|-------|
| `layout.Window` | `WindowState` | Server already has all fields. WindowState has `level` as `Int32` (Go uses `int`), `zOrder` as `Int32` (Go uses `int`). |
| `layout.WindowCategory` | New enum needed | Go has `WindowPopup`, `WindowFloating`, `WindowStandard` |
| `layout.AssignmentResult` | New struct needed | `assignments: [String: [UInt32]]`, `floating: [UInt32]`, `excluded: [UInt32]` |
| `config.AppRule` | `GridAppRule` | Already exists with matching fields |
| `config.WindowExclusion` | `GridWindowExclusion` | Already exists with `mergedWithDefaults()` |
| `types.Rect.Overlap()` | `CGRect` extension needed | Overlap area calculation for position-based assignment |
| `SortCellsByPosition()` | `GridLayout.sortCellsByPosition()` | Already exists in GridLayout.swift |

### Key Observations

1. **WindowState vs Go's Window type:** The server's `WindowState` already has ALL the fields Go's `layout.Window` has. No adapter needed -- GridAssignment can work directly with `WindowState`.

2. **BundleID resolution:** Go resolves bundleID by looking up PID in applications map. The server's `WindowState` does not store bundleID directly, but `ApplicationState` has it. The assignment module will need bundleID for app rule matching. Two options: (a) pass bundleID lookup into the function, or (b) enrich WindowState with bundleID before calling assignment. The server's `StateManager` already has `applications` keyed by PID string.

3. **`terminalApps` allowlist:** Go has a hardcoded map of app names that should be allowed to tile even without a fullscreen button (Alacritty, iTerm2, etc.). This needs to be ported as-is.

4. **`MinTileableDimension`:** Go uses 100px. This filters out toolbars/tab bars.

5. **`sortCellsByPosition`:** Already exists in `GridLayout.swift` -- can reuse directly.

6. **CGRect.overlap:** Not yet defined. Need a small extension for area-of-overlap calculation used by `assignByPosition`.

## Gaps

1. **No `WindowCategory` enum in Swift** -- needs to be created
2. **No `AssignmentResult` struct** -- needs to be created
3. **No `CGRect.overlap()` extension** -- needed for position-based assignment
4. **BundleID access pattern** -- need to decide how assignment gets bundleID for app rule matching
5. **No `GridAssignment.swift` file** -- the entire file is new

## Prerequisites
- [x] `GridTypes.swift` exists with `GridAssignmentStrategy` enum
- [x] `GridConfig.swift` exists with `GridAppRule` and `GridWindowExclusion`
- [x] `GridState.swift` exists with cell state data structures
- [x] `GridLayout.swift` exists with `sortCellsByPosition()` and `GridCalculatedLayout`
- [x] `StateModels.swift` exists with `WindowState` containing all AX properties
- [x] No blocking dependencies

## Recommendation
**BUILD** -- All prerequisites are met. The file is new, all dependent types exist. The Go source is well-structured and maps cleanly to Swift.
