# Review: Phase 2 - BorderRenderer Port

## Requirement Fulfillment

| DW-ID | Done-When Item | Status | Evidence |
|-------|---------------|--------|----------|
| DW-2.1 | `Ports/BorderRendering.swift` exists with `protocol BorderRendering` — all 5 consumer-facing methods async | SATISFIED | `Sources/GridServer/Ports/BorderRendering.swift:14` — `protocol BorderRendering: AnyObject, Sendable`. All 5 methods async: `setCellAssignments` (line 19), `updateFocus` (line 31), `handleWindowDestroyed` (line 34), `handleWindowMoved` (line 37), `handleDisplayDisconnected` (line 40). File is named `BorderRendering.swift` (not `BorderRenderer.swift`) to avoid collision with existing `enum BorderRenderer` — approved deviation noted in dispatch prompt and discovery. |
| DW-2.2 | `SimpleBorderManager` conforms, with `setCellAssignments` wrapping the existing completion-callback pattern in `withCheckedContinuation` internally | SATISFIED | `Sources/GridServer/Borders/SimpleBorderManager.swift:1092` — `extension SimpleBorderManager: BorderRendering`. Conformance `setCellAssignments` at line 1094 calls the existing completion-callback method (line 1104-1116) passing `completion: { continuation.resume() }`. The `withCheckedContinuation` is at line 1104. The other 4 fire-and-forget methods use `withCheckedContinuation` + `DispatchQueue.main.async` to bridge (lines 1119-1165). |
| DW-2.3 | GridReconciler holds `any BorderRendering`, continuation removed from `syncBordersForSpace` | SATISFIED | `Sources/GridServer/Grid/GridReconciler.swift:27` — `private weak var borderRenderer: (any BorderRendering)?`. `syncBordersForSpace` at lines 1132 and 1197 calls `await borderRenderer?.setCellAssignments(...)` directly — no `withCheckedContinuation` wrapper at the call site. Comment at line 1193 documents the removal. |
| DW-2.4 | `MockBorderRenderer` records all calls with arguments for assertion | SATISFIED | `Tests/GridServerTests/BorderRenderingTests.swift:8` — `final class MockBorderRenderer: BorderRendering, @unchecked Sendable`. `enum Call` at line 11 captures `setCellAssignments(assignments:displayUUID:focusedWindowID:source:)`, `updateFocus(windowID:displayUUID:)`, `handleWindowDestroyed(windowID:)`, `handleWindowMoved(windowID:frame:)`, `handleDisplayDisconnected(displayUUID:)`. `var calls: [Call]` at line 25. All 5 protocol methods append to `calls`. |
| DW-2.5 | At least 3 tests exercise border sync (focus change triggers updateFocus, window destroy triggers handleWindowDestroyed, layout sync triggers setCellAssignments with correct window-to-cell map) | SATISFIED | `test_DW_2_5a_focus_change_triggers_update_focus` (line 162) — injects MockBorderRenderer, triggers `_test_triggerFocusChanged`, asserts `.updateFocus` in calls. `test_DW_2_5b_window_destroy_triggers_handle_destroyed` (line 204) — triggers `_test_triggerWindowDestroyed(windowID: 500)`, asserts `.handleWindowDestroyed(windowID: 500)` in calls. `test_DW_2_3_and_2_5c_reconciler_sync_borders_calls_set_cell_assignments` (line 131) — triggers `_test_triggerSyncBorders`, asserts `.setCellAssignments` in calls. |
| DW-2.6 | `swift build` succeeds, existing tests pass | SATISFIED | `swift build`: "Build complete!" 0 errors, 0 warnings. `swift test`: 97 tests, 0 failures (92 pre-existing + 5 new `BorderRenderingTests`). All existing suites pass. |

**All requirements met:** YES

## Test-DW Coverage

- [x] All DW items have corresponding tests (DW-2.1 via compile-time conformance check in `test_DW_2_1_protocol_has_all_five_methods`; DW-2.2 indirectly via conformance compilation and `test_DW_2_3_and_2_5c`; DW-2.3 via `test_DW_2_3_and_2_5c`; DW-2.4 via `test_DW_2_4_mock_records_all_calls`; DW-2.5 via three named tests; DW-2.6 via build/test run)
- [x] Test names follow DW-ID convention (`test_DW_2_1_*`, `test_DW_2_3_and_2_5c_*`, `test_DW_2_4_*`, `test_DW_2_5a_*`, `test_DW_2_5b_*`)
- [x] No unplanned additions detected
- [x] Test coverage matches plan level (targeted — 5 tests covering the required 3+ border sync paths, plus protocol shape and mock recording verification)

Note: DW-2.2 has no dedicated test asserting that `withCheckedContinuation` is used internally. The plan's constraint (bridge must use continuation internally, not change completion-callback semantics) is verified structurally via code review of lines 1094-1116 and confirmed by the build succeeding. A runtime unit test of `withCheckedContinuation` bridging would require the main queue running inside XCTest, which is impractical. The compile-time conformance check and integration tests are the appropriate verification level for this item.

## Dead Code

None found. All added symbols are referenced:
- `BorderRendering` protocol is the type of `borderRenderer` in `GridReconciler` (line 27), `setup()` (line 292), and `_test_setup()` (line 1418)
- `SimpleBorderManager: BorderRendering` conformance extension is exercised at runtime via `main.swift:170`
- `MockBorderRenderer` is used in all 5 `BorderRenderingTests`
- All 5 `_test_trigger*` helpers in `GridReconciler` are called from tests
- `Foundation` import in `BorderRendering.swift` is needed (transitively via `CoreGraphics` on some platforms); `CoreGraphics` import is needed for `CGRect` in `handleWindowMoved` and `setCellAssignments` signatures

## Correctness Dimensions

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Concurrency | PASS | `BorderRendering` is `AnyObject & Sendable`. `MockBorderRenderer` is `@unchecked Sendable` (single-threaded tests). `SimpleBorderManager` conformance uses `DispatchQueue.main.async` internally, same threading model as before. `continuation.resume()` is called inside the main-queue block, ensuring resume happens exactly once per call. `completion?()` in `setCellAssignments` is called unconditionally after the `self?.setCellAssignmentsImpl(...)` call — if `self` is nil, impl is skipped but completion still fires, preventing a stuck continuation. |
| Error Handling | PASS | All `borderRenderer?.` call sites use optional chaining — nil border renderer is silently skipped (correct: border rendering is a UI side effect, not a hard requirement for state correctness). No new error paths added. |
| Resources | PASS | `withCheckedContinuation` is used (not `withUnsafeContinuation`). Each conformance method has exactly one `continuation.resume()` call on the main queue — no double-resume or missed-resume paths. Weak references maintained correctly. |
| Boundaries | PASS | Empty `[:]` assignment map is tested by the no-layout branch in `test_DW_2_3_and_2_5c`. `focusedWindowID: nil` path is tested in the same test. |
| Security | N/A | No untrusted input, no SQL/shell/HTML construction. Protocol extraction only. |

## Defensive Programming: PASS

Crisis triage (5 checks):

1. External input validated at boundaries: `syncBordersForSpace` guards on `gridState`, `gridConfig`, `stateProvider`, layout existence, and display bounds before sending to border renderer. PASS.
2. Return values checked: `borderRenderer?.setCellAssignments(...)` is awaited and result (Void) is used. `borderRenderer?.updateFocus(...)` and other fire-and-forget methods are awaited. PASS.
3. Error paths tested: no-layout branch (empty map sent to border renderer) is exercised in `test_DW_2_3_and_2_5c`. PASS.
4. No assertions with side effects added. PASS.
5. Resources released on all paths: `withCheckedContinuation` always resumes; `DispatchQueue.main.async` closures do not hold strong references that could create retain cycles (uses `[weak self]`). PASS.

## Design Quality

**Protocol shape is correct** — 5-method protocol with `AnyObject & Sendable` constraints, matching the Phase 1 pattern. `AnyObject` enables `weak var` storage in `GridReconciler`; `Sendable` enables cross-actor use.

**Continuation placement is correct** — `withCheckedContinuation` moved from the `GridReconciler` call site into `SimpleBorderManager` conformance. The caller now uses clean `await borderRenderer?.setCellAssignments(...)` without ceremony. The conformance layer owns the bridging complexity, which is the right place for it. This is a depth improvement (abstraction hides a mechanism).

**Fire-and-forget methods now `await` to completion** — the other 4 methods (`updateFocus`, `handleWindowDestroyed`, `handleWindowMoved`, `handleDisplayDisconnected`) were previously fire-and-forget dispatches; they now `await` the main-queue work to complete before the reconciler continues. This is a minor timing change: the reconciler waits for each border operation. The discovery document analyzed this and concluded it is a net improvement (prevents reordering races), not a regression. LOW severity.

**`MockBorderRenderer.Call` captures a subset of arguments** — `setCellAssignments` call captures `assignments`, `displayUUID`, `focusedWindowID`, `source` but not `cellStackModes`, `windowOrder`, `displayFrame`, `liveWids`. These are intentionally omitted for assertion ergonomics. The test for layout sync (DW-2.5c) only needs the window-to-cell map and source — the omitted fields are tested at the integration level. LOW severity — acceptable for targeted test coverage policy.

**No pass-through concerns** — `GridReconciler.setup()` stores the protocol type; `_test_setup()` also accepts the protocol type. Both are consumers of the abstraction, not pass-through methods.

## Testing: PASS

5 tests: 1 protocol shape test (DW-2.1), 1 mock recording test (DW-2.4), 3 behavioral integration tests (DW-2.5a focus, DW-2.5b destroy, DW-2.3+2.5c sync). The 3 behavioral tests cover: focus change → `updateFocus`, window destroy → `handleWindowDestroyed`, layout sync → `setCellAssignments`. All exercise the full orchestration path through real `GridReconciler` with injected `MockBorderRenderer` and `MockStateProvider`.

All 97 tests pass (92 pre-existing + 5 new).

## Issues

None.

**Verdict: PASS**
