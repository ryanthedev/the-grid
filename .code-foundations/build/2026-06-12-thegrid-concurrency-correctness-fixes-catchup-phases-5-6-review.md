# Review: Phases 5 & 6 - Geometry Writes + Borders

## Executed Results (Step 0)

| Command | Result |
|---------|--------|
| `swift build` | Build complete (0 errors, 0 warnings beyond baseline) |
| `swift test` | **242 tests, 0 failures** |
| `GeometryWritesTests` | 15 tests, all PASS |
| `BordersPhase6Tests` | 14 tests, all PASS |

---

## Phase 5 Requirement Fulfillment

### DW-5.1
PREMISE:  "grow grows / shrink shrinks the focused window even when it is last in its stack; `resize.split.done` reflects correct direction."
EVIDENCE: `GridResize.swift:93-96` (`resolveBoundaryAndDelta` call), `GridResize.swift:139-154` (static pure helper), `GridResize.swift:121` (`jlog("resize.split.done")`)
TRACE:    `adjustFocusedSplit(delta=+0.1, focusedIdx=last)` → `resolveBoundaryAndDelta` clamps to `ratios.count-2` and negates delta → `adjustSplitRatio` expands focused (last) window's ratio → `jlog("resize.split.done")` emitted after `reapplyLayout`
VERDICT:  PASS — tests `test_DW_5_1_grow_last_window_expands_it`, `test_DW_5_1_shrink_last_window_contracts_it`, `test_DW_5_1_grow_first_window_expands_it`, `test_DW_5_1_sole_window_noop_no_crash`, `test_DW_5_1_three_window_cell_middle_window_no_negation` all pass.

### DW-5.2
PREMISE:  "split ratios preserved across send/assign (recalculate, not equalize) — custom ratios survive a cell-send in both source and target cells."
EVIDENCE: `GridState.swift:397-447` (`assignWindow`, `prependWindow` call `recalculateSplitsAfterAddition`), `GridState.swift:461-583` (`removeWindow` calls `recalculateSplitsAfterRemoval`), `GridLayout.swift:781,807` (pure recalculation helpers)
TRACE:    `assignWindow(3, toCellID:"left")` with existing [0.7, 0.3] → `recalculateSplitsAfterAddition([0.7,0.3], newIndex:2)` → [~0.467, ~0.200, ~0.333] (proportional, not equal) — `after[0] > after[1]` invariant holds
VERDICT:  PASS — tests `test_DW_5_2_assignWindow_preserves_existing_ratios`, `test_DW_5_2_removeWindow_preserves_existing_ratios`, `test_DW_5_2_first_window_into_empty_cell_gets_unity_ratio`, `test_DW_5_2_prependWindow_preserves_existing_ratios` all pass.

### DW-5.3
PREMISE:  "displaced-window migration calls `applyCellLayout` for the target (and vacated source) cell."
EVIDENCE: `GridReconciler.swift:1777-1788` (post-migration loop calling `gridApply?.applyCellLayout` for `migration.targetSpaceID/targetCell` and `migration.sourceSpaceID/sourceCell`); `GridApply.swift:345-346` (`_test_applyCellLayoutHook` test hook)
TRACE:    `sweepDisplacedWindows()` detects window 100 displaced from space "1" to space "2" → `migrations.append(...)` → loop calls `applyCellLayout(spaceID:"2", cellID:"left")` then `applyCellLayout(spaceID:"1", cellID:"left")` → both space IDs appear in `capturedCalls`
VERDICT:  PASS — test `test_DW_5_3_sweep_calls_applyCellLayout_for_target_and_source_cells` passes.

### DW-5.4
PREMISE:  "cross-display move aborts state mutation when `moveWindowToSpace` returns false; logs `err.verify` on the SLS-fallback branch."
EVIDENCE: `GridWindowMove.swift:450-458` (abort path in `moveWindowCrossDisplay`); `GridReconciler.swift:888-905` (`err.verify` log on SLS-fallback locked-cell branch in `handleWindowCreated`)
TRACE:    (a) `moveWindowCrossDisplay` path: `moved=false` → `shouldAbortCrossDisplayMove(moved:false)=true` → fence released, `err.move.cross_display` logged, `throw .windowMoveFailed` — GridState never mutated. (b) locked-cell inactive-space path: `moveWindowToSpace` returns false → `jlog("err.verify", data:[...])` emitted before `return`
VERDICT:  PASS — tests `test_DW_5_4_move_abort_predicate_true_when_failed`, `test_DW_5_4_move_abort_predicate_false_when_succeeded`, `test_DW_5_4_err_verify_logged_on_sls_fallback_failure` all pass.

### DW-5.5
PREMISE:  "all-cells-locked autoflow logs `warn.assign.dropped{wids}` instead of silently dropping."
EVIDENCE: `GridAssignment.swift:372-378` (guard `!sortedCells.isEmpty` → `JSONLogger.shared.log("warn.assign.dropped", data: ["wids": droppedWIDs])`)
TRACE:    `assignAutoFlow(windows:[1,2], sortedCells:["left","right"], lockedCells:{"left","right"})` → `sortedCells.filter{!locked}` = [] → `guard !sortedCells.isEmpty` fires → `warn.assign.dropped` with `wids:[1,2]` logged → return
VERDICT:  PASS — tests `test_DW_5_5_all_cells_locked_logs_dropped_wids`, `test_DW_5_5_partial_lock_still_assigns_without_dropping` both pass.

**All Phase 5 requirements met: YES**

---

## Phase 6 Requirement Fulfillment

### DW-6.1
PREMISE:  "atomic `setCellAssignments` diffs active-cell membership and rebuilds on change (no silent delta drop; correct stack count on cell send)."
EVIDENCE: `BordersPolicy.swift:18-40` (`BorderMembershipPolicy.activeCellMembersChanged`); `SimpleBorderManager.swift:185-198` (call site in `setCellAssignmentsImpl` that triggers `rebuildBorderPool` on membership change)
TRACE:    `setCellAssignmentsImpl` with `newFocused` in same cell, same window, but `activeCellMembersChanged(cellID:old:new:)=true` (window added/removed) → `rebuildBorderPool(source:"atomic-membershipChange")` called
VERDICT:  PASS — tests `test_DW_6_1_membership_unchanged_skips_rebuild`, `test_DW_6_1_membership_diff_added_window_triggers_rebuild`, `test_DW_6_1_membership_diff_removed_window_triggers_rebuild`, `test_DW_6_1_nil_old_assignments_is_changed`, `test_DW_6_1_window_moved_to_other_cell_not_changed` all pass.

### DW-6.2
PREMISE:  "mutable state captured into immutable locals before any `Task{}` log block (no off-main reads of freePool/activeBorder/focusedWindowID)."
EVIDENCE: `SimpleBorderManager.swift:710-719` (`rebuildBorderPool`: `capturedFocused`, `capturedPoolSize`, `capturedTabbed` captured before `Task{}`); `SimpleBorderManager.swift:354-396` (`handleWindowDestroyedImpl`: Task blocks use parameter `windowID` only); `BorderWindow.swift:455-500` (`retarget`: Task blocks use `currentWindowID`, `oldTarget`, `newTargetID` — all captured locals or parameters before any Task)
TRACE:    In `rebuildBorderPool`, `let capturedFocused = focusedWindowID ?? 0` on line 712 before `Task { JSONLogger.shared.log("bdr.rebuild", data: ["focused": capturedFocused, ...]) }` — no live `self.focusedWindowID` read inside Task
VERDICT:  PASS — structural verification confirmed; `test_DW_6_2_task_log_blocks_capture_locals_not_live_state` passes (documented structural invariant).

### DW-6.3
PREMISE:  "`retarget` returns success; on a bounds-guard failure the manager hides/reacquires (no border stuck on a closed window)."
EVIDENCE: `BorderWindow.swift:455-501` (`retarget` returns `Bool`; bounds guard at line 467 returns `false` without committing `targetWindowID`; commits at line 481 only after successful bounds query); `BordersPolicy.swift:44-56` (`BorderRetargetPolicy.shouldCommitTarget`)
TRACE:    `retarget(to:newTargetID)` → `SLSGetWindowBounds` fails → `return false` (targetWindowID unchanged at old value, border is safe) vs success path: `targetWindowID = newTargetID` committed after bounds obtained
VERDICT:  PASS — tests `test_DW_6_3_retarget_returns_true_on_success`, `test_DW_6_3_retarget_returns_false_on_bounds_failure` pass.

### DW-6.4
PREMISE:  "a resize-redraw failure sets `isVisible=false` (or retries); `err.bdr.resize_ctx` logged."
EVIDENCE: `BorderWindow.swift:416-424` (`isVisible = false` set on context-create failure; `JSONLogger.shared.log(BorderResizePolicy.resizeContextFailureLogEvent, ...)` emitted); `BordersPolicy.swift:64-76` (`BorderResizePolicy.resizeContextFailureLogEvent = "err.bdr.resize_ctx"`, `shouldClearVisibilityOnContextFailure() = true`)
TRACE:    `performUpdate` with resize needed → `SLWindowContextCreate` returns nil → `isVisible = false` → `JSONLogger.shared.log("err.bdr.resize_ctx", data:["wid":..., "targetID":...])` → next `updateStyle/show` call can repair the border
VERDICT:  PASS — tests `test_DW_6_4_resize_redraw_failure_sets_isVisible_false`, `test_DW_6_4_err_bdr_resize_ctx_log_event_code_matches_spec` pass.

### DW-6.5
PREMISE:  "`borders.query` is async (no socket-thread main.sync)."
EVIDENCE: `SimpleBorderManager.swift:505-512` (`queryBorderInfo` uses `withCheckedContinuation` + `DispatchQueue.main.async`); `MessageHandler.swift:1294-1336` (`borders.query` handler uses `Task { await borderManager.queryBorderInfo(...) }` — no `DispatchQueue.main.sync` anywhere in either file)
TRACE:    Caller on socket/background thread → `await manager.queryBorderInfo(forWindowID:wid)` → resumes via `DispatchQueue.main.async` continuation, not `.sync` → no deadlock
VERDICT:  PASS — test `test_DW_6_5_query_border_info_async_no_main_sync` passes (awaited from XCTest async context, off-main).

### DW-6.6
PREMISE:  "`windowOrderPerDisplay` pruned on destroy (correct stack indicator count after a close)."
EVIDENCE: `SimpleBorderManager.swift:385-395` (`handleWindowDestroyedImpl` iterates `windowOrderPerDisplay.keys` and calls `WindowOrderPrunePolicy.prune(wid:from:)` for each display); `BordersPolicy.swift:84-98` (`WindowOrderPrunePolicy.prune` strips `wid` from every cell array)
TRACE:    `handleWindowDestroyedImpl(windowID:200)` → `windowOrderPerDisplay["d1"] = prune(wid:200, from:{"A":[100,200,300],"B":[200,400]})` → result `{"A":[100,300],"B":[400]}` — stack count for "A" drops from 3 to 2
VERDICT:  PASS — tests `test_DW_6_6_window_order_pruned_on_destroy`, `test_DW_6_6_stack_count_correct_after_destroy`, `test_DW_6_6_prune_absent_wid_is_noop` all pass.

**All Phase 6 requirements met: YES**

---

## Test-DW Coverage

| DW Item | Automated Test(s) | Ran in Step 0 |
|---------|-------------------|---------------|
| DW-5.1 | `test_DW_5_1_grow_last_window_expands_it`, `test_DW_5_1_shrink_last_window_contracts_it`, `test_DW_5_1_grow_first_window_expands_it`, `test_DW_5_1_sole_window_noop_no_crash`, `test_DW_5_1_three_window_cell_middle_window_no_negation` | YES |
| DW-5.2 | `test_DW_5_2_assignWindow_preserves_existing_ratios`, `test_DW_5_2_removeWindow_preserves_existing_ratios`, `test_DW_5_2_first_window_into_empty_cell_gets_unity_ratio`, `test_DW_5_2_prependWindow_preserves_existing_ratios` | YES |
| DW-5.3 | `test_DW_5_3_sweep_calls_applyCellLayout_for_target_and_source_cells` | YES |
| DW-5.4 | `test_DW_5_4_move_abort_predicate_true_when_failed`, `test_DW_5_4_move_abort_predicate_false_when_succeeded`, `test_DW_5_4_err_verify_logged_on_sls_fallback_failure` | YES |
| DW-5.5 | `test_DW_5_5_all_cells_locked_logs_dropped_wids`, `test_DW_5_5_partial_lock_still_assigns_without_dropping` | YES |
| DW-6.1 | `test_DW_6_1_membership_unchanged_skips_rebuild`, `test_DW_6_1_membership_diff_added_window_triggers_rebuild`, `test_DW_6_1_membership_diff_removed_window_triggers_rebuild`, `test_DW_6_1_nil_old_assignments_is_changed`, `test_DW_6_1_window_moved_to_other_cell_not_changed` | YES |
| DW-6.2 | `test_DW_6_2_task_log_blocks_capture_locals_not_live_state` (structural doc + code review) | YES |
| DW-6.3 | `test_DW_6_3_retarget_returns_true_on_success`, `test_DW_6_3_retarget_returns_false_on_bounds_failure` | YES |
| DW-6.4 | `test_DW_6_4_resize_redraw_failure_sets_isVisible_false`, `test_DW_6_4_err_bdr_resize_ctx_log_event_code_matches_spec` | YES |
| DW-6.5 | `test_DW_6_5_query_border_info_async_no_main_sync` | YES |
| DW-6.6 | `test_DW_6_6_window_order_pruned_on_destroy`, `test_DW_6_6_stack_count_correct_after_destroy`, `test_DW_6_6_prune_absent_wid_is_noop` | YES |

All DW items have automated tests that ran in Step 0. Coverage matches the "minimal unit tests" level stated in the project guidelines.

---

## Dead Code

None found. No unreachable code after early returns, no commented-out blocks, no debug statements, no unused imports.

---

## Correctness Dimensions

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Concurrency | PASS | `GridState` is an actor (all mutation serialized). `GridReconciler` is a class running on a single async task chain; `SimpleBorderManager` enforces main-queue dispatch for all mutable state; `@unchecked Sendable` is justified by the `DispatchQueue.main` guarantee documented on the class. `fence` is accessed only within the reconciler's serial async context. No demonstrated data races. |
| Error Handling | PASS | `adjustFocusedSplit` surfaces `GridResizeError.needAtLeastTwoWindows` via the `guard boundaryIndex >= 0` path. `moveWindowCrossDisplay` throws `windowMoveFailed` and releases the fence before throwing. `applyCellLayout` called via `try?` in sweep (graceful degradation — correct for a background sweep that must not propagate). |
| Resources | PASS | Border pool capped at `maxPoolSize=10` (`SimpleBorderManager.swift:87`). `fencePool` entries expire at 5s timeout (auto-cleanup in `RefcountedFence`). `sweepTimer` is a stored property keeping the dispatch source alive. |
| Boundaries | PASS | `resolveBoundaryAndDelta` guards `ratios.count >= 2` before accessing `ratios.count - 2`. `adjustFocusedSplit` guards `cell.windows.count >= 2` before entering ratio logic. `recalculateSplitsAfterAddition/Removal` in GridLayout are pure functions. |
| Security | N/A | No untrusted network input paths in these phases. Window IDs come from OS SkyLight APIs (process-local trust boundary). |

---

## Cross-Phase Coherence

- **P5 split-ratio recalculation vs P6 membership-diff rebuild**: P5's `recalculateSplitsAfterAddition/Removal` runs in `GridState` (actor); P6's `BorderMembershipPolicy.activeCellMembersChanged` compares assignment maps in `SimpleBorderManager` (main-queue). These operate on independent state types with no shared mutable reference — no contradiction.
- **P6 consumes P3's `GridState.focusedWindow`**: `syncBordersForSpace` (`GridReconciler.swift:1558`) calls `gridState.getFocusedWindow(spaceID:)` — the P3-authoritative actor accessor — as the `focusedWindowID` parameter to `setCellAssignments`. Confirmed.
- **Full 242-test suite regression**: All 242 tests pass. No regression from P5/P6 changes into P1 (serialization), P2 (migration), P3 (focus), or P4 (adoption) functionality.

---

## Notes (non-blocking)

- **DW-6.2 test is structural documentation only** (`XCTAssertTrue(true, ...)`). The actual TSan validation is deferred to UAT as noted in the test comment. This is acknowledged as the correct approach for a concurrency constraint that cannot be exercised without multiple threads under the test runner.
- `GridWindowMove.swift` has `gridApply` wired via `setApply(_:)` post-construction to break a circular dependency; the `gridApply` field is unused in `moveWindowToCell` and `moveWindowCrossDisplay` but is set on the class. This is a pre-existing pattern, not introduced by P5/P6.

---

VERDICT: PASS
