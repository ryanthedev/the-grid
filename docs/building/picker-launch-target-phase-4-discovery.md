# Discovery: Phase 4 - Wire deps in GridCommandRouter init

## Files Found
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` - exists, contains init block with dependency wiring

## Current State
- GridCommandRouter.swift init (lines 80-127) already wires dependencies using two patterns:
  1. `setup()` methods for initial construction (lines 81-120)
  2. `setApply()` calls for circular dependency resolution (lines 122-124)
- Existing circular dep wiring at lines 122-124:
  - `gridCellOps.setApply(gridApply)`
  - `gridWindowMove.setApply(gridApply)`
- GridReconciler already has the target methods from Phase 1:
  - `func setApply(_ apply: GridApply)` at line 86
  - `func setFocus(_ focus: GridFocus)` at line 90
  - `private weak var gridApply: GridApply?` at line 27
  - `private weak var gridFocus: GridFocus?` at line 28
- `gridReconciler` is available as a `private let` at line 42, assigned at line 76

## Gaps
- None. The `setApply` and `setFocus` methods exist on GridReconciler. The `gridApply` and `gridFocus` instances are available in the init scope. The pattern to follow is clear at lines 123-124.

## Prerequisites
- [x] GridReconciler.setApply() exists (Phase 1, line 86)
- [x] GridReconciler.setFocus() exists (Phase 1, line 90)
- [x] gridApply available in init scope (line 70)
- [x] gridFocus available in init scope (line 67)
- [x] gridReconciler available in init scope (line 76)
- [x] Existing pattern to follow (lines 123-124)

## Recommendation
BUILD - Add 2 lines to the circular dependency resolution block at lines 123-124.
