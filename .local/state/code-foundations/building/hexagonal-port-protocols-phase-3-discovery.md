# Discovery + Design: Phase 3 - WindowController Port

## Files Found

- `Sources/GridServer/WindowManipulator.swift` — concrete class, `focusWindow(pid:windowID:) -> Bool` (sync) + `setWindowFrame(context:frame:) async -> Bool`
- `Sources/GridServer/Grid/GridApply.swift` — holds `private weak var windowManipulator: WindowManipulator?`; calls `manipulator.setWindowFrame(context:frame:)` at line 504 via `applyPlacementsViaAX`; uses `ManipulationContext.from(windowID:)` to fetch pid before the call
- `Sources/GridServer/Grid/GridFocus.swift` — holds `private weak var windowManipulator: WindowManipulator?`; calls `windowManipulator.focusWindow(pid:windowID:)` at lines 402 and 452
- `Sources/GridServer/Grid/GridCommandRouter.swift` — wires `windowManipulator: WindowManipulator` into both `gridFocus.setup()` and `gridApply.setup()`
- `Sources/GridServer/Ports/StateProvider.swift` — pattern reference
- `Sources/GridServer/Ports/BorderRendering.swift` — pattern reference
- `Tests/GridServerTests/StateProviderTests.swift` — mock + test pattern reference
- `Tests/GridServerTests/BorderRenderingTests.swift` — mock + test pattern reference

## Current State

`WindowManipulator` is a concrete class with two methods used by the in-scope consumers:

1. `focusWindow(pid: pid_t, windowID: UInt32) -> Bool` — synchronous in `WindowManipulator`; GridFocus calls it directly then calls `Task.yield()` before re-reading state.
2. `setWindowFrame(context: ManipulationContext, frame: CGRect) async -> Bool` — async, takes `ManipulationContext` which bundles windowID + pid + frame + a reference to `StateManager.shared`.

GridApply's `applyPlacementsViaAX` first calls `ManipulationContext.from(windowID:)` (which reads `StateManager.shared.getState()`) to get the pid, then calls `manipulator.setWindowFrame(context:frame:)`. The context is used internally by `setWindowFrame` to call `context.stateManager.setWindowFrame(windowID, frame:)` after a successful AX call.

`ManipulationContext` directly embeds `var stateManager: StateManager { StateManager.shared }` — it's a singleton accessor baked into the struct.

Out-of-scope consumers (`GridWindowMove`, `GridNudge`, `GridTerminalManager`, `PickerManager`, `MessageHandler`) also use `WindowManipulator` directly but are not changed in this phase.

## Gaps vs. Plan Assumptions

**Assumption to verify: "Hiding ManipulationContext behind WindowController port is feasible" (MEDIUM confidence)**

VERIFIED FEASIBLE with a design adjustment:

The plan says `setWindowFrame(windowID: UInt32, frame: CGRect)` — hiding both context and pid. However, the conformance (`WindowManipulator.setWindowFrame`) needs pid to call `getAXElement(pid:windowID:)`. Currently `ManipulationContext` provides pid.

GridApply already fetches the pid via `ManipulationContext.from(windowID:)` before calling the method. So GridApply has `context.pid` available. The simplest approach: protocol signature is `setWindowFrame(windowID: UInt32, pid: pid_t, frame: CGRect) async -> Bool`. The conformance uses pid + windowID to call `getAXElement`, then also calls `context.stateManager.setWindowFrame` for state sync.

Alternative (pid-free): have the conformance look up pid internally from `StateManager.shared`. But that makes the conformance depend on the singleton, which we're trying to hide — no benefit over what we already have, and it's less explicit.

**Decision: Protocol signature includes pid_t for setWindowFrame, matching what GridApply already has available.**

The ManipulationContext state-update side effect (`context.stateManager.setWindowFrame(windowID, frame:)`) will be preserved in the conformance by building a minimal internal ManipulationContext for the existing method call, or inlining the state update directly.

## Code Standards

- Comments on own line above code, never inline trailing
- `private weak var` for dependency storage
- `jlog()` for logging, no `print()`
- `_test_` prefix for test-only helpers
- Test names: `test_DW_3_N_descriptor`
- `@unchecked Sendable` on test fakes (single-threaded tests)
- `AnyObject, Sendable` on port protocols (weak refs + actor boundary crossing)

## Test Infrastructure

XCTest, `@testable import GridServer`. Pattern established by Phase 1-2:
- Mock in the test file alongside the tests
- `_test_setup()` methods on consumers for injection
- Need to add `_test_setup()` to GridApply and GridFocus that accepts `any WindowController`

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|---------------|--------|------------|
| DW-3.1 | `Ports/WindowController.swift` exists with `protocol WindowController` — `focusWindow` and `setWindowFrame` both async | COVERED | `test_DW_3_1_protocol_has_both_async_methods` (compile + exercise) |
| DW-3.2 | `WindowManipulator` conforms, hiding `ManipulationContext` behind the port interface | COVERED | Compile-time; conformance verified by `test_DW_3_1` assigning to `any WindowController` |
| DW-3.3 | GridApply and GridFocus hold `any WindowController` | COVERED | `test_DW_3_3_gridapply_uses_window_controller_port` + `test_DW_3_3_gridfocus_uses_window_controller_port` (inject mock via `_test_setup`) |
| DW-3.4 | `MockWindowController` records operations with window IDs and frames | COVERED | `test_DW_3_4_mock_records_focus_call` + `test_DW_3_4_mock_records_set_frame_call` |
| DW-3.5 | At least 3 tests (layout apply positions windows correctly, focus navigates to correct window, focus handles missing window gracefully) | COVERED | `test_DW_3_5a_layout_apply_calls_set_frame`, `test_DW_3_5b_focus_calls_focus_window`, `test_DW_3_5c_focus_missing_window_throws` |
| DW-3.6 | `swift build` succeeds, existing tests pass | COVERED | Verified by build + test run at end |

**All items COVERED:** YES

## Design Decisions

### Protocol signature — setWindowFrame

Two approaches:

**A: `setWindowFrame(windowID: UInt32, frame: CGRect) async -> Bool`**
- Conformance looks up pid from `StateManager.shared` internally
- Hides pid entirely — cleaner interface
- Conformance still depends on singleton StateManager for pid lookup

**B: `setWindowFrame(windowID: UInt32, pid: pid_t, frame: CGRect) async -> Bool`**
- Caller provides pid alongside windowID
- GridApply already has both (from its `ManipulationContext.from` call)
- Conformance has no hidden singleton dependency for the lookup
- More explicit, matches focusWindow signature convention

**Chosen: B** — pid is in-hand at the GridApply call site (already fetched via `ManipulationContext.from`). This removes the singleton dependency from the conformance path, which is the point of the port abstraction. The conformance builds a ManipulationContext internally from windowID + pid.

The state-update side effect in `setWindowFrame(context:frame:)` (calling `context.stateManager.setWindowFrame`) will be preserved in the conformance by constructing a `ManipulationContext(windowID: windowID, pid: pid)` internally.

### Protocol signature — focusWindow

Plan: `focusWindow(windowID: UInt32, pid: pid_t) async`

Current WindowManipulator: `focusWindow(pid: pid_t, windowID: UInt32) -> Bool`

GridFocus has both pid and windowID available. Parameter order follows the plan (windowID first, matching the setWindowFrame convention).

Return type: current is `Bool`. GridFocus uses the return value to decide whether to throw. Keep `async -> Bool`.

### _test_setup additions

GridApply.setup and GridFocus.setup currently take `windowManipulator: WindowManipulator`. After the change they take `windowController: any WindowController`. `_test_setup` methods need to be added (following GridReconciler's pattern) to inject the mock without full wiring.

GridFocus also holds `stateManagerForOverride: StateManager?` for cross-display focus — that field is out of scope and stays as is.

## Prerequisites

- [x] Phase 1 (StateProvider) and Phase 2 (BorderRendering) patterns established
- [x] `Ports/` directory exists
- [x] 97 tests pass, build clean
- [x] ManipulationContext.from feasibility confirmed

## Recommendation

BUILD
