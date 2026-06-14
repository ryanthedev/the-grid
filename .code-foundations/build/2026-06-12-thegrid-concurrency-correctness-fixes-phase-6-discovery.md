# Discovery + Design: Phase 6 - Borders

## Files Found

- `grid-server/Sources/GridServer/Borders/SimpleBorderManager.swift` (1085 lines) — `@unchecked Sendable`, all mutable state on main queue; IPC handlers, border pool, focus management
- `grid-server/Sources/GridServer/Borders/BorderWindow.swift` (619 lines) — single overlay window, retarget, resize/redraw, visibility
- `grid-server/Sources/GridServer/Ports/BorderRendering.swift` (41 lines) — protocol port; no `queryBorderInfo` (only the concrete class exposes it)
- `grid-server/Sources/GridServer/MessageHandler.swift` — `borders.query` handler at line 1294 calls `borderManager.queryBorderInfo(forWindowID:)` synchronously
- `grid-server/Tests/GridServerTests/BorderRenderingTests.swift` — `MockBorderRenderer` conforming to `BorderRendering`

## Current State

`SimpleBorderManager` is `@unchecked Sendable` with the stated invariant "all mutable state on DispatchQueue.main". The six bugs are all localized to this class and `BorderWindow`:

| Bug | Location | Nature |
|-----|----------|--------|
| #9 | `setCellAssignmentsImpl:165-189` | Atomic branch's final `else` takes `refreshBorderPositions` even when cell membership changed (window added/removed) — no rebuild |
| #27 | Multiple `Task {}` blocks in `rebuildBorderPool:676`, `updateFocusImpl:296-312`, `handleWindowDestroyedImpl:350-370`, `handleDisplayDisconnectedImpl:403` | `Task {}` closures capture `freePool.count`, `activeBorder`, `focusedWindowID` as part of the dictionary literal INSIDE the task — reads happen off-main |
| #53 | `BorderWindow.retarget:449` | `targetWindowID = newTargetID` committed before `SLSGetWindowBounds` guard; on failure the border is stuck pointing at a destroyed window |
| #54 | `BorderWindow.performUpdate:404` | `SLWindowContextCreate` failure on resize-redraw: alpha is 0 but `isVisible` stays `true`; next `show()` guard `isVisible` is no-op; border never repairs |
| #55 | `SimpleBorderManager.queryBorderInfo:486` | `DispatchQueue.main.sync` from the socket client thread; hangs if main is wedged |
| #56 | `handleWindowDestroyedImpl:372-375` | Only prunes `cellAssignmentsPerDisplay`; `windowOrderPerDisplay` retains the destroyed wid, inflating stack indicator count |

## Gaps

None — all six findings map directly to specific lines and have clear fix directions from the audit. No prerequisite is missing.

## Code Standards

- `jlog` codes: `warn.<scope>.<reason>` / `err.<scope>` — `err.bdr.resize_ctx` required for DW-6.4
- Comments on their own line above the code, never inline
- `[weak self]` + `guard let self else { return }` in escaping closures
- Border rendering on the main queue only (§8)
- Extract pure predicates as `static`/value helpers and unit-test them
- `BorderRendering` is a fakeable port for integration tests

## Test Infrastructure

XCTest, `@testable import GridServer`, `swift test` from `grid-server/`. Existing mock: `MockBorderRenderer` in `BorderRenderingTests.swift`. Pattern: pure-logic unit tests for decision predicates, mock-injected integration tests for manager behaviour. DW-6.2 is `[M]` TSan — proven structurally by code review (no runtime test possible without SkyLight). 228 tests currently green.

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|----------------|--------|------------|
| DW-6.1 | atomic `setCellAssignments` diffs active-cell membership and rebuilds on change | COVERED | `test_DW_6_1_membership_diff_added_window_triggers_rebuild`, `test_DW_6_1_membership_diff_removed_window_triggers_rebuild`, `test_DW_6_1_membership_unchanged_skips_rebuild` |
| DW-6.2 | all mutable state captured into immutable locals before any `Task{}` log block | COVERED | `test_DW_6_2_task_log_blocks_use_captured_locals` — structural (code-level assertion; no off-main read in compiled code) |
| DW-6.3 | `retarget` returns success; on bounds-guard failure the manager hides/reacquires | COVERED | `test_DW_6_3_retarget_returns_true_on_success`, `test_DW_6_3_retarget_returns_false_on_bounds_failure` |
| DW-6.4 | resize-redraw failure sets `isVisible=false`; `err.bdr.resize_ctx` logged | COVERED | `test_DW_6_4_resize_redraw_failure_sets_isVisible_false`, `test_DW_6_4_err_bdr_resize_ctx_logged` |
| DW-6.5 | `borders.query` is async (continuation + `main.async`) — no `main.sync` | COVERED | `test_DW_6_5_query_border_info_async_no_main_sync` |
| DW-6.6 | `windowOrderPerDisplay` pruned on destroy — stack count correct after close | COVERED | `test_DW_6_6_window_order_pruned_on_destroy`, `test_DW_6_6_stack_count_correct_after_destroy` |

**All items COVERED:** YES

## Design Decisions

### DW-6.1: Membership diff predicate

The atomic branch currently uses `refreshBorderPositions` when cell+focus+display are all unchanged. The fix adds a membership check comparing the active cell's window set in `oldAssignments` vs `assignments`. Extract this as a `static func activeCell(membersOf cellID: String, changedBetween old: [UInt32: String]?, and new: [UInt32: String]) -> Bool` in a new `BorderMembershipPolicy` value — unit-testable without SkyLight.

GoF pattern: **Template Method** — the existing `setCellAssignmentsImpl` already has the decision tree; we're inserting one more step in the `else` branch rather than redesigning the structure.

### DW-6.2: Off-main reads

The simplest and lowest-risk fix: capture immutable locals before each `Task {}` block, as `destroyAllBorders` already does correctly (the audit notes this as the reference pattern). Making the class `@MainActor` would be cleaner but is a larger structural change with blast-radius risk on a live WM. Staying with local capture is consistent with existing patterns and has zero impact on callers.

### DW-6.3: retarget return value

Change `retarget(to:)` to `@discardableResult retarget(to:) -> Bool`. Commit `targetWindowID` only after the bounds guard succeeds. In `reassignBorders` (tabbed path), on retarget failure: hide the border and release it to pool, clear `activeBorder`, fall through to `rebuildBorderPool`. This is the "reacquire" path the audit prescribes.

### DW-6.4: isVisible repair on failed redraw

In `performUpdate`, when the `SLWindowContextCreate` at the resize-redraw path fails: set `isVisible = false` and log `err.bdr.resize_ctx`. The next `updateStyle` call will see `isVisible=false` and call `show()` after drawing, repairing visibility. No retry needed — natural repair on next update.

### DW-6.5: Async query

Add `queryBorderInfo(forWindowID:) async -> [String: Any]?` using `withCheckedContinuation` + `DispatchQueue.main.async`. Keep the old synchronous overload as private (used only in `queryBorderInfoImpl`). Update `MessageHandler`'s `borders.query` handler to `await` the async version inside its existing `Task {}` block.

### DW-6.6: windowOrderPerDisplay pruning

In `handleWindowDestroyedImpl`, add a loop mirroring the `cellAssignmentsPerDisplay` loop that strips the destroyed wid from every `windowOrderPerDisplay[display][cell]` array.

## Prerequisites

- [x] Required files exist
- [x] P3 `GridState.focusedWindow` write-on-success invariant delivered (consumed, not re-implemented here)
- [x] P1 serialized event path in place
- [x] 228 tests green baseline

## Recommendation

BUILD
