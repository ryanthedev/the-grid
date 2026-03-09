# Discovery: Phase 3 - Layout Computation

## Files Found
- `/Users/r/repos/theGrid/grid-cli/internal/layout/grid.go` (199 lines) - track calculation, layout computation
- `/Users/r/repos/theGrid/grid-cli/internal/layout/cells.go` (165 lines) - cell bounds, adjacency, sorting
- `/Users/r/repos/theGrid/grid-cli/internal/layout/windows.go` (322 lines) - window stacking, padding, placements
- `/Users/r/repos/theGrid/grid-cli/internal/layout/splits.go` (245 lines) - split ratio adjustment
- `/Users/r/repos/theGrid/grid-cli/internal/types/layout_types.go` (227 lines) - Go type definitions
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Grid/GridTypes.swift` (322 lines) - Phase 1 Swift types
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Grid/GridConfig.swift` (891 lines) - Phase 1 config
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Grid/GridState.swift` (757 lines) - Phase 2 state actor

## Target File
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Grid/GridLayout.swift` - DOES NOT EXIST (needs creation)

## Current State

### Phase 1 (GridTypes.swift) provides all needed types:
- `GridTrackSize` with `.fr`, `.px`, `.auto`, `.minmax` types -> maps to Go's `TrackSize`
- `GridPadding` / `GridPaddingValue` / `GridResolvedPadding` -> maps to Go's `Padding` / `PaddingValue` / `ResolvedPadding`
- `GridCellDef` with `columnStart/End`, `rowStart/End` (1-indexed) -> maps to Go's `Cell`
- `GridLayoutDef` with `columns`, `rows`, `cells`, `cellModes`, `padding`, `windowSpacing` -> maps to Go's `Layout`
- `GridDirection` -> maps to Go's `Direction`
- `GridStackMode` -> maps to Go's `StackMode`

### Phase 1 (GridConfig.swift) provides:
- `GridConfig.getLayout(id:)` -> returns `GridLayoutDef`
- `GridConfig.getDisplayOffset(uuid:name:)` -> returns `GridDisplayOffset`
- `GridConfig.getBaseSpacing()` -> returns `Double`
- `GridConfig.getSettingsPadding()` -> returns `GridPadding?`
- `GridConfig.getSettingsWindowSpacing()` -> returns `GridPaddingValue?`

### Phase 2 (GridState.swift) provides:
- `GridState.getColumnRatios(spaceID:)` / `getRowRatios(spaceID:)` for ratio overrides
- `GridState.getCellSplitRatios(spaceID:cellID:)` for window split ratios
- `GridState.getWindowAssignments(spaceID:)` for cell->windows map
- Private `equalRatios()`, `normalizeRatios()`, `adjustRatiosForCount()` in actor

### Type Mappings (Go -> Swift):
| Go Type | Swift Type | Notes |
|---------|-----------|-------|
| `types.Rect` | `CGRect` | Use CoreGraphics; X/Y/Width/Height semantics match |
| `types.Point` | `CGPoint` | Use CoreGraphics |
| `types.TrackSize` | `GridTrackSize` | Already exists |
| `types.Cell` | `GridCellDef` | Already exists |
| `types.Layout` | `GridLayoutDef` | Already exists |
| `types.StackMode` | `GridStackMode` | Already exists |
| `types.Direction` | `GridDirection` | Already exists |
| `types.Padding` | `GridPadding` | Already exists |
| `types.PaddingValue` | `GridPaddingValue` | Already exists |
| `types.ResolvedPadding` | `GridResolvedPadding` | Already exists |
| `types.CalculatedLayout` | `GridCalculatedLayout` | NEW - needs definition |
| `types.WindowPlacement` | `GridWindowPlacement` | NEW - needs definition |

## Gaps

1. **Missing result types:** `CalculatedLayout` and `WindowPlacement` structs need to be defined in GridLayout.swift (or GridTypes.swift). Go defines them in `layout_types.go`. Best to define in GridLayout.swift since they are output types of layout computation.

2. **CGRect vs custom Rect:** Go uses `types.Rect{X, Y, Width, Height}`. Swift's `CGRect` has `.origin.x`, `.origin.y`, `.size.width`, `.size.height`. The mapping is straightforward but every field access changes syntax. `CGRect.contains()` exists but uses different semantics (point must be strictly inside). Need a small extension or custom check.

3. **Duplicate ratio utilities:** `GridState` has private `equalRatios()`, `normalizeRatios()`, `adjustRatiosForCount()`. The Go layout package also has `equalRatios()`, `NormalizeRatios()`, `AdjustRatiosForWindowCount()`. These should be unified in GridLayout.swift as package-level functions, and GridState can call them.

4. **CGRect.center / contains / overlaps:** Go's `Rect` has `Center()`, `Contains()`, `Overlap()` methods. CGRect has some of these but with different semantics. Need small extensions.

## Prerequisites
- [x] Phase 1 GridTypes.swift exists with all needed types
- [x] Phase 1 GridConfig.swift exists with config access methods
- [x] Phase 2 GridState.swift exists with ratio/assignment access
- [x] Go source files available for porting
- [x] Type mappings are clear

## Recommendation
**BUILD** - All prerequisites are met. Create `Grid/GridLayout.swift` with pure layout computation functions. Define `GridCalculatedLayout` and `GridWindowPlacement` structs. Add CGRect extensions for center/overlap. Consolidate ratio utility functions here so GridState can reuse them.
