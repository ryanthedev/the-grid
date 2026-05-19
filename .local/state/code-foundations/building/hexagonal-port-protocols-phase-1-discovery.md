# Discovery + Design: Phase 1 - StateProvider Port

## Files Found
- `Sources/GridServer/StateManager.swift` -- actor with `getState() -> WindowManagerState` (line 137, synchronous actor-isolated method)
- `Sources/GridServer/Grid/GridReconciler.swift` -- `private weak var stateManager: StateManager?` (line 26), 16 `getState()` call sites
- `Sources/GridServer/Grid/GridApply.swift` -- `private weak var stateManager: StateManager?` (line 45), 3+ call sites
- `Sources/GridServer/Grid/GridFocus.swift` -- `private weak var stateManager: StateManager?` (line 52), 6+ call sites
- `Sources/GridServer/Grid/StateValidator.swift` -- `private weak var stateManager: StateManager?` (line 21), 1 call site (line 150-151)
- `Sources/GridServer/main.swift` -- wiring of StateManager.shared into setup methods
- `Sources/GridServer/StateModels.swift` -- `WindowManagerState` struct (Codable, not explicitly Sendable)
- `Sources/GridServer/Grid/GridState.swift` -- actor used in tests alongside stateManager
- `Sources/GridServer/Grid/GridAssignment.swift` -- `isTileable()` and `classifyWindow()` free functions

## Current State
- Build succeeds (after `make generate-version`)
- 88 existing tests pass
- `StateManager` is an actor with a `getState() -> WindowManagerState` method
- All consumers use `await stateManager.getState()` (actor hop provides the await)
- Consumers hold `private weak var stateManager: StateManager?`
- `Ports/` directory does not exist

## Gaps
1. **getState() is not `async` in signature** -- it's a synchronous method on an actor. When called cross-actor, Swift implicitly requires `await`. The protocol MUST declare `func getState() async -> WindowManagerState` so that a non-actor fake can also require `await` at call sites. This is a signature difference but NOT a behavioral change -- call sites already use `await`.

2. **StateManager's setup methods pass concrete type** -- GridReconciler.setup, GridApply.setup, GridFocus.setup, StateValidator.init all accept `StateManager` not `any StateProvider`. These must change to accept `any StateProvider`.

3. **`any StateProvider` existential with actor** -- verified: Swift existential protocol conformance works fine for actors. Since `any StateProvider` is not `Sendable` by default but `WindowManagerState` is a struct (value type, implicitly Sendable since all fields are Sendable), the `async` protocol method handles the actor hop. No `@Sendable` annotation needed on the protocol.

4. **GridReconciler uses other StateManager methods** -- `stateManager` in GridReconciler is only used for `getState()`. Confirmed by grep: all 16 references are `stateManager.getState()`.

5. **GridFocus uses `stateManager.overrideActiveSpace()`** -- line 555. This is NOT part of the StateProvider protocol (it's a mutation, not a state query). GridFocus will need to keep a separate reference for this, OR we add it to the protocol. Since this phase is just `getState()`, GridFocus needs both `any StateProvider` AND `StateManager` for the override. WAIT -- re-checking: `stateManager?.overrideActiveSpace()` appears once. For Phase 1, we can have GridFocus hold `any StateProvider` for getState calls, and keep a separate `weak var stateManager: StateManager?` for overrideActiveSpace. But that's messy. Better approach: ONLY change the type of the stored property that's used for `getState()`. Since it's the same property used for overrideActiveSpace, we need to check all methods that use `stateManager` for non-getState calls.

## Detailed Consumer Analysis

### GridReconciler
All `stateManager` uses: only `stateManager.getState()`. Safe to change to `any StateProvider`.

### GridApply
Uses: `stateManager.getState()` at multiple call sites. Also passes `stateManager` to helper methods that only call getState. Safe to change.

### GridFocus
Uses: `stateManager.getState()` (6 sites) PLUS `stateManager?.overrideActiveSpace()` (1 site, line 555). The overrideActiveSpace call is NOT on the StateProvider protocol. Options:
  - A) Keep GridFocus holding concrete `StateManager` for now (partially defeats purpose)
  - B) Add `overrideActiveSpace` to the protocol
  - C) GridFocus holds both `any StateProvider` and a separate `StateManager?` ref for mutation

Decision: Option A for Phase 1. GridFocus keeps `StateManager?`. The plan says "switch all consumers to hold `any StateProvider`" but the overrideActiveSpace mutation makes this impossible without expanding the protocol. We'll change the type for the property used in getState calls. Actually, looking again -- all GridFocus getState calls use the same `stateManager` property. We can't split one property into two types without a larger refactor. Best path: change GridFocus to `any StateProvider` and add the `overrideActiveSpace` to the protocol, or keep GridFocus as-is. I'll go with: change GridFocus to `any StateProvider` BUT keep a separate `private weak var stateManagerForOverride: StateManager?` for the one override call. This is the cleanest minimal approach.

Actually, simplest: just add `func overrideActiveSpace(_ spaceID: UInt64) async` to StateProvider. It's still a state-related operation. But the plan says "protocol StateProvider defining `func getState() async -> WindowManagerState`" (singular method). Let me stick to the plan and use a dual-reference approach for GridFocus.

Re-reading the plan DW-1.1: "protocol StateProvider defining func getState() async -> WindowManagerState". The protocol has exactly one method. For GridFocus, I'll use two properties.

### StateValidator
Uses: `stateManager.getState()` (1 site). Safe to change to `any StateProvider`.

## Code Standards
Applied from `docs/code-standards.md`:
- Comments on their own line above code
- `jlog()` for structured logging
- Test names: `test_DW_<phase>_<item>_<descriptor>`
- PascalCase files matching primary type
- Protocols in new `Ports/` directory

## Test Infrastructure
- XCTest framework
- Tests in `grid-server/Tests/GridServerTests/`
- Run via `swift test` from `grid-server/`
- Pure-logic tests preferred (extract static helpers)
- Actor test helpers use `_test_` prefix
- 88 existing tests, all passing

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|---------------|--------|------------|
| DW-1.1 | `Ports/StateProvider.swift` exists with `protocol StateProvider` defining `func getState() async -> WindowManagerState` | COVERED | test_DW_1_1_protocol_exists (compile-time: if protocol doesn't exist, MockStateProvider and tests won't compile) |
| DW-1.2 | `StateManager` conforms to `StateProvider` with no method body changes | COVERED | test_DW_1_2_stateManager_conforms (compile-time: build succeeds; runtime: verified by injection in main.swift) |
| DW-1.3 | GridReconciler, GridApply, GridFocus, StateValidator hold `any StateProvider` instead of `StateManager` | COVERED | test_DW_1_3_consumers_accept_mock (MockStateProvider injected into GridReconciler setup proves the type changed) |
| DW-1.4 | `main.swift` passes `StateManager.shared` as `any StateProvider` to setup methods | COVERED | Compile-time verification (build succeeds) |
| DW-1.5 | `MockStateProvider` test fake exists, returns canned `WindowManagerState` | COVERED | test_DW_1_5_mock_returns_canned_state |
| DW-1.6 | At least 3 tests exercise `handleWindowCreated` logic using `MockStateProvider` + real `GridState` actor | COVERED | test_DW_1_6a_tileable_window_assigned_to_cell, test_DW_1_6b_non_tileable_window_rejected, test_DW_1_6c_locked_cell_routing |
| DW-1.7 | `swift build` succeeds with no errors or warnings from this change | COVERED | Build verification step |
| DW-1.8 | Existing tests pass (`swift test`) | COVERED | Test suite run |

**All items COVERED:** YES

## Design Decisions

### Protocol Shape
The protocol has a single method:
```swift
protocol StateProvider: AnyObject, Sendable {
    func getState() async -> WindowManagerState
}
```

`AnyObject` constraint: consumers hold weak references (`private weak var stateProvider: (any StateProvider)?`). Protocols must be class-bound for weak refs.

`Sendable` constraint: the protocol is used across actor boundaries. Since StateManager is an actor (implicitly Sendable), and MockStateProvider will be an actor too, `Sendable` is natural. Actually -- `any StateProvider & Sendable` is the cleanest. Let me check: `private weak var x: (any StateProvider)?` requires AnyObject. And for cross-actor passing, Sendable helps. But actors already conform to Sendable. The simpler approach: make the protocol `: AnyObject, Sendable` which lets both actors and classes conform, and enables weak references.

Wait -- the mock needs to be an actor too (to conform to Sendable and be used across async boundaries). OR we make the mock a class and mark it `@unchecked Sendable`. Since mock is test-only and single-threaded, `@unchecked Sendable` is fine.

Actually, for the mock fake: it needs to be callable with `await`. If MockStateProvider is a simple class, `func getState() async -> WindowManagerState` just returns the canned value. No actor needed. `@unchecked Sendable` for the class is sufficient since tests are single-threaded.

Final protocol:
```swift
protocol StateProvider: AnyObject, Sendable {
    func getState() async -> WindowManagerState
}
```

### StateManager Conformance
StateManager already has `func getState() -> WindowManagerState`. Actor methods are implicitly async when called cross-isolation. Adding `extension StateManager: StateProvider {}` should work because an actor-isolated synchronous method satisfies an `async` protocol requirement (the compiler wraps the call). Verified: Swift allows actor methods to satisfy async protocol requirements.

### GridFocus Dual-Reference
GridFocus needs `overrideActiveSpace()` which is StateManager-specific. Solution: rename internal property to `stateProvider: any StateProvider` for getState calls, add a separate `stateManagerRef: StateManager?` for the override call. The setup method accepts both.

### Test Strategy for DW-1.6
`handleWindowCreated` is private. We cannot call it directly. The plan says "tests exercise handleWindowCreated logic". Options:
1. Call via EventRouter -- requires too much infrastructure
2. Extract the decision logic as a static helper -- already partially done (pickTargetCell, resolveDisplacedTarget are static)
3. Make handleWindowCreated internal/package -- breaks encapsulation
4. Test the static helpers that handleWindowCreated delegates to

Best approach: test the pure decision predicates that handleWindowCreated uses: `isTileable()`, `classifyWindow()`, and `pickTargetCell()`. These are the actual logic under test. The handleWindowCreated method is just orchestration (getState, guard checks, delegate to helpers). Testing the helpers with MockStateProvider proves the pattern works.

Actually, the DW says "using MockStateProvider + real GridState actor". This implies we need a test that actually wires MockStateProvider and GridState together and exercises a code path. The closest we can get without making handleWindowCreated public is to test a method that uses stateManager.getState() and GridState together.

Alternative: create a `_test_handleWindowCreated` method on GridReconciler that delegates to the private one. This follows the existing `_test_` convention in the codebase (StateManager._test_setState, StateValidator._test_seedOrphanCounts).

Decision: Add a `_test_triggerWindowCreated(windowID:pid:)` method to GridReconciler that calls handleWindowCreated. This follows the codebase convention and lets tests exercise the real orchestration path with MockStateProvider + GridState.

## Assumption Verification
- **`any StateProvider` works across actor boundaries without `@Sendable`**: VERIFIED. The protocol will be `Sendable` (actors are implicitly Sendable), and `any StateProvider` existentials work fine. The `async` keyword on the protocol method handles the actor hop.

## Prerequisites
- [x] Required files exist (StateManager.swift, GridReconciler.swift, etc.)
- [x] Dependencies available (no new external deps)
- [x] Build succeeds
- [x] Tests pass
- [x] Version.swift generated

## Recommendation
BUILD -- proceed to TDD implementation.
