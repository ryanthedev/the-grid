# Discovery: Phase 7 - Resize

## Files Found
- `grid-server/Sources/GridServer/Grid/GridLayout.swift` -- contains `adjustSplitRatio`, `adjustSplitRatioWithMax`, `normalizeRatios`, `equalRatios`, `minimumRatio` constant
- `grid-server/Sources/GridServer/Grid/GridState.swift` -- actor with `getColumnRatios`, `setColumnRatios`, `getRowRatios`, `setRowRatios`, `getCellSplitRatios`, `setCellSplitRatios`, `getFocusedCell`, `getSpaceReadOnly`, `getCellWindows`
- `grid-server/Sources/GridServer/Grid/GridApply.swift` -- `reapplyLayout(spaceID:strategy:)`, `applyCellLayout(spaceID:cellID:)`
- `grid-server/Sources/GridServer/Grid/GridFocus.swift` -- `findActiveSpaceID()`, `getDisplayBoundsForSpace()`
- `grid-server/Sources/GridServer/Grid/GridConfig.swift` -- `GridResizeSettings` with `minRatio`/`maxRatio` (defaults 0.1/0.9), `getLayout(id:)`
- `grid-server/Sources/GridServer/Grid/GridTypes.swift` -- `GridTrackSize`, `GridTrackType`, `GridCellDef`, `GridLayoutDef`
- `grid-cli/internal/layout/resize.go` -- Go source to port (403 lines)

## Current State

**GridResize.swift does not exist.** All dependencies are in place from Phases 1-6.

The Go `resize.go` has 4 public functions and 3 private helpers:
- `AdjustFocusedSplit` -- grow/shrink split ratio within a cell (between stacked windows)
- `ResetFocusedSplits` -- reset focused cell's split ratios to equal
- `ResetAllSplits` -- reset ALL cells' splits to equal
- `AdjustCellBoundary` -- grow/shrink column/row ratios (between cells in the grid)
- `ResetCellRatios` -- reset column/row ratios to layout defaults (nil)
- `countFlexibleTracks` -- count fr/minmax tracks (private helper)
- `initializeTrackRatios` -- create ratios from track fr values (private helper)
- `getFlexBoundaryIndex` -- map overall track index to flex-only index (private helper)

**What already exists in Swift:**
- `GridLayout.adjustSplitRatio(ratios:index:delta:minRatio:)` -- split ratio adjustment (used by `AdjustFocusedSplit`)
- `GridLayout.adjustSplitRatioWithMax(ratios:index:delta:minRatio:maxRatio:)` -- with max constraint (used by `AdjustCellBoundary`)
- `GridLayout.equalRatios(_:)` -- equal ratio initialization
- `GridLayout.normalizeRatios(_:)` -- ratio normalization
- `GridLayout.minimumRatio` constant (0.1)
- `GridConfig.GridResizeSettings` -- `minRatio`/`maxRatio` config
- `GridState.setColumnRatios` / `setRowRatios` -- but these normalize, not clear to nil
- `GridApply.reapplyLayout(spaceID:strategy:)` -- reapply after ratio changes

## Gaps

1. **No `clearTrackRatios` on GridState.** Go's `ResetCellRatios` sets `ColumnRatios = nil` and `RowRatios = nil`. Current Swift `setColumnRatios`/`setRowRatios` always normalizes. Need a `clearTrackRatios(spaceID:)` method or similar.

2. **No `countFlexibleTracks`, `initializeTrackRatios`, `getFlexBoundaryIndex` in Swift.** These are Go-only helpers in `resize.go` used by `AdjustCellBoundary`. They need to be ported -- logically they belong on `GridLayout` since they operate on `[GridTrackSize]`.

3. **Go resize functions each build `ApplyOptions` and call `ReapplyLayout`.** In Swift, `GridApply.reapplyLayout` already uses preserve strategy by default. The Go boilerplate for extracting baseSpacing/padding/windowSpacing is unnecessary in Swift because `GridApply` has its own dependency references.

## Prerequisites
- [x] GridState actor with ratio get/set (Phase 2)
- [x] GridLayout with split ratio adjustment functions (Phase 3)
- [x] GridApply with reapplyLayout (Phase 6)
- [x] GridFocus with findActiveSpaceID (Phase 5)
- [x] GridConfig with resize settings and layout lookup (Phase 1)
- [ ] GridState needs clearTrackRatios method (minor addition)

## Recommendation
**BUILD** -- Create `Grid/GridResize.swift` and add `clearTrackRatios` to `GridState.swift`. The three private track helpers (`countFlexibleTracks`, `initializeTrackRatios`, `getFlexBoundaryIndex`) should be added to `GridLayout` as static methods since they operate on track definitions.
