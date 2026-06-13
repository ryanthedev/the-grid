# Discovery + Design: Phase 5 - Geometry writes

## Files Found

- `grid-server/Sources/GridServer/Grid/GridResize.swift` (resize split logic, `adjustFocusedSplit` at :58-116)
- `grid-server/Sources/GridServer/Grid/GridLayout.swift` (static helpers `adjustSplitRatio` :687-718, `recalculateSplitsAfter{Addition,Removal}` :781-825 — exist but dead for assignWindow/removeWindow path)
- `grid-server/Sources/GridServer/Grid/GridState.swift` (state mutations: `assignWindow` :379-396, `prependWindow` :398-416, `insertWindow` :418-432, `removeWindow` :434-489 — all call `equalRatios`, never recalculate)
- `grid-server/Sources/GridServer/Grid/GridCellOps.swift` (sendWindow :64-128 — calls `gridState.removeWindow` + `gridState.assignWindow`, triggering equalization in both)
- `grid-server/Sources/GridServer/Grid/GridWindowMove.swift` (cross-display move :426-432 — `let _ = windowManipulator.moveWindowToSpace(...)`, result discarded; state mutation continues unconditionally at :436)
- `grid-server/Sources/GridServer/Grid/GridReconciler.swift` (sweepDisplacedWindows :1699-1751 — does removeWindow+assignWindow+syncBorders but never applyCellLayout for target/source cells)
- `grid-server/Sources/GridServer/Grid/GridAssignment.swift` (assignAutoFlow :350-379 — `guard !sortedCells.isEmpty else { return }` at :372, silent drop with no log)
- `grid-server/Tests/GridServerTests/GridAssignmentTests.swift` (existing test file to extend)

## Current State

**DW-5.1 (resize sign bug):** `adjustFocusedSplit` at `GridResize.swift:93-96` clamps `boundaryIndex` to `ratios.count - 2` when the focused window is last in stack, but does NOT negate `delta`. `adjustSplitRatio(ratios:index:delta:)` adds `delta` to `ratios[index]` and subtracts from `ratios[index+1]`. At the last window, the clamped boundary makes `index` point to the window BEFORE the focused one — growing adds to the previous window's ratio and shrinks the focused window. Direction is inverted.

**DW-5.2 (split ratios equalized on membership change):** Every window assignment mutation in `GridState` (`assignWindow`, `prependWindow`, `insertWindow`, `removeWindow`) calls `equalRatios(cell.windows.count)` to set `cell.splitRatios`. This discards any custom ratios. `setWindowAssignments` (the bulk assignment path used by apply) preserves ratios via `recalculateSplitsAfterAddition/Removal`. The per-window mutation paths never call these helpers even though they exist.

**DW-5.3 (displaced window never repositioned):** `sweepDisplacedWindows` in `GridReconciler` migrates the window in `GridState` and calls `syncBordersForSpace` for affected spaces, but never calls `gridApply?.applyCellLayout` for the target or vacated source cell. The window is logically reassigned but never repositioned on screen.

**DW-5.4 (cross-display move ignores moveWindowToSpace result):** `GridWindowMove.moveWindowAcrossDisplays` at line 432: `let _ = windowManipulator.moveWindowToSpace(...)` discards the Bool. State mutation at line 436+ proceeds unconditionally. On failure, GridState now tracks the window on the target space while the OS still has it on the source space — feeding sweepDisplacedWindows with a wrong assignment. The fence acquired at :428 is never released on failure. Also: `GridReconciler.handleWindowCreated` line 866's SLS-fallback branch (:866-874) succeeds but logs no `err.verify` (plan spec: log `err.verify` on the SLS-fallback branch).

**DW-5.5 (autoflow silent drop):** `assignAutoFlow` in `GridAssignment` at line 372 does `guard !sortedCells.isEmpty else { return }` — when all cells are locked, it silently drops every window passed to it. No log, no error, no fallback.

## Gaps

- The plan's `#16` re `moveWindowToSpace` is about the cross-display move in `GridWindowMove.swift`, not the `handleWindowCreated` locked-cell path (that is a separate finding). The fix here is on the `GridWindowMove` path: check the return value and abort (release fence, skip state mutation) on false. The `err.verify` log target is the SLS-fallback branch in `handleWindowCreated` (:866-874).
- Bug inventory confirms plan `#ID` numbering in phase text maps to: `#10` → resize sign (inventory index 55); `#28` → split equalization (inventory index 57); `#19` → displaced reposition (inventory index 15); `#16` → cross-display move abort (inventory index 16 — note: plan has a distinct reading vs the locked-cell finding); `#48` → autoflow silent drop (inventory index 34).
- `GridWindowMove` does not currently have an `err.verify` log at all; the plan says to add it on the SLS-fallback branch in `GridReconciler.handleWindowCreated` (:866-874), not in GridWindowMove itself. Both can be addressed within P5 scope.

## Code Standards

- All jlog codes follow `warn.<scope>.<reason>` / `err.<scope>` convention.
- Comments on their own line, never trailing inline.
- `[weak self]` + `guard let self` in escaping closures.
- No new warnings: baseline is `main.swift:8` swift-log deprecation + ApplicationObserver as-casts only.
- Pure decision logic extracted as `static` helpers (testable off AX boundary).
- Test names: `test_DW_5_<item>_<descriptor>`.

## Test Infrastructure

XCTest, `@testable import GridServer`. Pure-logic tests preferred. `GridAssignmentTests.swift` and `GridAssignmentTests.swift` demonstrate patterns. `GridState` tests go in new file `GeometryWritesTests.swift`. Integration test for DW-5.3/5.4 uses protocol fakes (`StateProvider`, `WindowController`) already present in the codebase (see `WindowAdoptionIntegrationTests.swift` pattern).

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|---------------|--------|------------|
| DW-5.1 | grow grows / shrink shrinks the focused window even when it is last in its stack — unit test on a 2-window cell with the last window focused; `resize.split.done` reflects the correct direction | COVERED | `test_DW_5_1_grow_last_window_expands_it`, `test_DW_5_1_shrink_last_window_contracts_it`, `test_DW_5_1_grow_first_window_expands_it`, `test_DW_5_1_sole_window_is_noop` |
| DW-5.2 | split ratios preserved across send/assign (recalculate, not equalize) — custom ratios survive a cell-send in both source and target cells | COVERED | `test_DW_5_2_assignWindow_preserves_existing_ratios`, `test_DW_5_2_removeWindow_preserves_existing_ratios`, `test_DW_5_2_prependWindow_preserves_existing_ratios`, `test_DW_5_2_first_window_gets_ratio_1_0` |
| DW-5.3 | displaced-window migration calls `applyCellLayout` for the target (and vacated source) cell — geometry matches the new assignment | COVERED | `test_DW_5_3_sweep_calls_applyCellLayout_for_target_cell`, `test_DW_5_3_sweep_calls_applyCellLayout_for_source_cell` |
| DW-5.4 | cross-display move aborts state mutation when `moveWindowToSpace` returns false, and logs `err.verify` on the SLS-fallback branch | COVERED | `test_DW_5_4_move_aborts_state_mutation_on_failure`, `test_DW_5_4_err_verify_logged_on_sls_fallback` |
| DW-5.5 | all-cells-locked autoflow logs `warn.assign.dropped{wids}` (and/or falls back) instead of silently dropping windows | COVERED | `test_DW_5_5_all_cells_locked_logs_dropped_wids`, `test_DW_5_5_partial_lock_still_assigns` |

**All items COVERED:** YES

## Design Decisions

**DW-5.1 (resize sign fix):** When `boundaryIndex` is clamped (focused window is last), negate `delta` before passing to `adjustSplitRatio`. This is the minimal surgical fix: `adjustSplitRatio(ratios:index:delta:)` adds delta to `ratios[index]` and subtracts from `ratios[index+1]`. When `index = ratios.count - 2` (boundary before the focused window), positive delta grows ratios[count-2] (previous window) and shrinks ratios[count-1] (focused window) — wrong. Negating delta fixes it: now ratios[count-2] shrinks and ratios[count-1] (focused) grows. Extracted as `static func resolveBoundaryAndDelta(idx:ratios:delta:) -> (Int, Double)` for unit testability.

**DW-5.2 (split recalculation):** Change `assignWindow`, `removeWindow`, `prependWindow`, and `insertWindow` in `GridState` to call `GridLayout.recalculateSplitsAfterAddition/Removal` instead of `equalRatios`. These helpers already normalize, so the behavior is correct. Edge cases: empty cell gets `[1.0]`; sole-window removal returns `[]` (consistent with empty check at :468-469). The `recalculateSplitsAfterAddition` uses the insertion index, so `assignWindow` (appends) passes `cell.windows.count - 1` (index after append, which is the new last index) — wait, actually `assignWindow` appends, so after append `cell.windows.count` is the new count; the new window is at index `count - 1`. Pass `newIndex = cell.windows.count - 1` after the append. For `prependWindow` (inserts at 0), pass `newIndex = 0`. For `insertWindow`, pass `clampedIndex`.

**DW-5.3 (displaced reposition):** After `sweepDisplacedWindows` migrates a window in GridState, call `gridApply?.applyCellLayout(spaceID:cellID:)` for both the target cell and the vacated source cell. The `applyCellLayout` is `async throws` — use `try? await` consistent with existing call sites at :848/:870. Track `(spaceID, cellID)` pairs for source vacated cells. To make the call testable without a full GridApply, expose the `applyCellLayout` via the `BorderRendering` or add a `_test_` helper — actually, the simplest approach is to test via a fake `GridApply` class that tracks calls. Since `GridApply` is a concrete class (not a protocol), we need to count invocations via `_test_` hook or check side effects. The plan says `[I]` integration test — use a fake `StateProvider` and check that `affectedSpaces` includes target+source.

**DW-5.4 (cross-display move abort):** Check the return value of `moveWindowToSpace`. On `false`: log `err.move.cross_display`, release the fence acquired at step 6, and throw `GridWindowMoveError.windowMoveFailed` (new case). The fence must be released before the throw to avoid a leaked fence. The `err.verify` log on SLS-fallback branch in `GridReconciler.handleWindowCreated:866-874` — add `jlog("err.verify", ...)` when the SLS-move branch is taken (currently logs `reconcile.win.create.locked` but not a verification error).

**DW-5.5 (autoflow drop logging):** Replace the silent `return` with a `jlog("warn.assign.dropped", data: ["wids": windows.map { Int($0.id) }])` before returning. The function signature is `private static func assignAutoFlow` — it doesn't have access to `jlog` directly (it's a static function). Use `JSONLogger.shared.log(...)` instead, which is the underlying call `jlog` wraps, OR restructure the guard to log before returning. Check how `jlog` works — it's a free function that calls `JSONLogger.shared.log`. Since this is a static method with no actor context, calling `JSONLogger.shared.log` directly is correct.

## Prerequisites

- [x] Required files exist (all confirmed above)
- [x] `GridLayout.recalculateSplitsAfterAddition/Removal` already implemented and correct
- [x] Fence API (P1) already in place for DW-5.4 (fence release)
- [x] `gridApply?.applyCellLayout` already used at :848, :870 for DW-5.3 pattern
- [x] 213 tests green baseline confirmed

## Recommendation

BUILD — all DW items have clear, localized fixes with no design uncertainty.
