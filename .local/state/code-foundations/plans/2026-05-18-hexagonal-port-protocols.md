# Plan: Hexagonal Port Protocols for Testability
**Created:** 2026-05-18
**Status:** in-progress
**Started:** 2026-05-18 18:00
**Current Phase:** 1
**Complexity:** complex
---
## Context

theGrid server's domain logic (reconciliation, layout application, focus navigation, state validation) is untestable as integrated units because all 10 core types are concrete classes/actors with direct dependencies on macOS infrastructure (AX, SkyLight, CGWindowList). Only pure static helper extractions are testable today.

**Problem:** Introducing port protocols at the 4 side-effect boundaries (state queries, border rendering, window manipulation, persistence) so domain logic can be tested end-to-end with injected fakes.

**Success criteria:** GridReconciler, GridApply, GridFocus, and StateValidator methods are testable with injected fakes — no macOS infrastructure needed at test time.

## Constraints
- Actor boundaries preserved — GridState stays an actor, protocols don't change concurrency model
- Singleton removal out of scope — singletons conform to protocols but keep their lifecycle
- Timer extraction out of scope — tests use manual trigger methods where they exist
- All port protocols use async signatures (async normalization chosen over matching existing sync/callback patterns)
- Protocols live in a new `Ports/` directory under `Sources/GridServer/`

## Chosen Approach
**Async-Normalized Port Protocols** — Extract 4 port protocols with normalized async signatures. All methods become async (completion callbacks replaced with async/await, sync methods made async). Protocols in `Ports/` directory for architectural visibility. **Fallback:** If async normalization of a specific method causes timing issues (especially `setCellAssignments`), fall back to thin protocol matching existing signature for that method only.

## Rejected Approaches
- **Thin Port Protocols:** Minimal diff but leaks completion-callback patterns into protocol definitions, making test fakes more complex. Sync/async inconsistency in WindowController stays.

---
## Implementation Phases

### Phase 1: StateProvider Port
**Model:** opus
**Skills:** `none -- Swift protocol extraction, no matching skill`

**Goal:** Define the `StateProvider` protocol, conform `StateManager`, switch all consumers (GridReconciler, GridApply, GridFocus, StateValidator) to hold `any StateProvider`, write a test fake, and write tests for GridReconciler's `handleWindowCreated` path using the fake.

**Scope:**
- IN: Protocol definition in `Ports/StateProvider.swift`, `StateManager` conformance, consumer type changes, `main.swift` wiring, `MockStateProvider` fake, tests for reconciler window creation
- OUT: Other ports, StateManager internals, singleton removal

**Constraints:** `StateManager` is an actor — protocol must be usable across actor boundaries (`any StateProvider` must support `await`).

**Approach notes:** User chose async normalization. `getState()` is already async (actor-isolated), so no normalization needed here — this phase establishes the pattern (directory structure, fake conventions, test patterns) that Phases 2-4 follow.

**File hints:** `Grid/GridReconciler.swift` — 16 call sites for `stateManager.getState()`. `Grid/GridApply.swift` — 3 sites. `Grid/GridFocus.swift` — 6 sites. `Grid/StateValidator.swift` — 1 site. `main.swift` — wiring.

**Depends on:** none | **Unlocks:** Phase 2, Phase 3, Phase 4

**Done when:**
- [ ] DW-1.1: `Ports/StateProvider.swift` exists with `protocol StateProvider` defining `func getState() async -> WindowManagerState`
- [ ] DW-1.2: `StateManager` conforms to `StateProvider` with no method body changes
- [ ] DW-1.3: GridReconciler, GridApply, GridFocus, StateValidator hold `any StateProvider` instead of `StateManager`
- [ ] DW-1.4: `main.swift` passes `StateManager.shared` as `any StateProvider` to setup methods
- [ ] DW-1.5: `MockStateProvider` test fake exists, returns canned `WindowManagerState`
- [ ] DW-1.6: At least 3 tests exercise `handleWindowCreated` logic using `MockStateProvider` + real `GridState` actor (tileable assignment, non-tileable rejection, locked cell routing)
- [ ] DW-1.7: `swift build` succeeds with no errors or warnings from this change
- [ ] DW-1.8: Existing tests pass (`swift test`)

**Difficulty:** MEDIUM
**Uncertainty:** Actor existential conformance (`any StateProvider` from actor) may need `@Sendable` annotation — verify during implementation.

---

### Phase 2: BorderRenderer Port
**Model:** opus
**Skills:** `none -- Swift protocol extraction with async bridge refactor`

**Goal:** Define `BorderRenderer` protocol with async-normalized signatures (replace `setCellAssignments` completion callback with `async`), conform `SimpleBorderManager`, switch GridReconciler to hold `any BorderRenderer`, write a test fake, and write tests for border sync paths.

**Scope:**
- IN: Protocol in `Ports/BorderRenderer.swift`, `SimpleBorderManager` conformance (with async wrapper bridging internal DispatchQueue.main), GridReconciler consumer change, fake, tests
- OUT: SimpleBorderManager internals, border rendering logic, nudge mode, StateValidator (no dependency on this port)

**Constraints:** `SimpleBorderManager` does all work on `DispatchQueue.main`. The async protocol method must still dispatch to main internally — the async wrapper bridges this, it doesn't change the threading model.

**Approach notes:** The current `setCellAssignments` uses a completion callback bridged via `withCheckedContinuation` at the call site (GridReconciler). With async normalization, the continuation moves INTO the conformance implementation, and the protocol method becomes `async`. This is a mechanical inversion, not a behavior change. Other methods (`updateFocus`, `handleWindowMoved`, etc.) are currently fire-and-forget — they become `async` with an empty return (no functional change).

**File hints:** `Borders/SimpleBorderManager.swift` — conformance. `Grid/GridReconciler.swift` — `syncBordersForSpace` method (lines 1113-1208) has the `withCheckedContinuation` bridge that moves into the conformance. Also lines 359, 504, 964, 1054.

**Depends on:** Phase 1 (pattern established) | **Unlocks:** Phase 5

**Done when:**
- [ ] DW-2.1: `Ports/BorderRenderer.swift` exists with `protocol BorderRenderer` — all 5 consumer-facing methods async
- [ ] DW-2.2: `SimpleBorderManager` conforms, with `setCellAssignments` wrapping the existing completion-callback pattern in `withCheckedContinuation` internally
- [ ] DW-2.3: GridReconciler holds `any BorderRenderer`, continuation removed from `syncBordersForSpace`
- [ ] DW-2.4: `MockBorderRenderer` records all calls with arguments for assertion
- [ ] DW-2.5: At least 3 tests exercise border sync (focus change triggers updateFocus, window destroy triggers handleWindowDestroyed, layout sync triggers setCellAssignments with correct window-to-cell map)
- [ ] DW-2.6: `swift build` succeeds, existing tests pass

**Difficulty:** HIGH
**Uncertainty:** Moving the continuation into SimpleBorderManager could change timing if border renders complete before the caller expects. Monitor for visual glitches at runtime.

---

### Phase 3: WindowController Port
**Model:** sonnet
**Skills:** `none -- follows pattern from Phase 1-2`

**Goal:** Define `WindowController` protocol with async-normalized signatures, conform `WindowManipulator`, switch GridApply and GridFocus to hold `any WindowController`, write a test fake, and write tests for layout application and focus navigation.

**Scope:**
- IN: Protocol in `Ports/WindowController.swift`, `WindowManipulator` conformance, GridApply + GridFocus consumer changes, fake, tests
- OUT: WindowManipulator internals, AX/SkyLight implementation, ManipulationContext details, StateValidator (no dependency on this port)

**Approach notes:** `focusWindow(pid:windowID:)` is currently synchronous. Async normalization wraps it as `async`. `setWindowFrame(context:frame:)` is already async. The protocol surface should accept `(windowID: UInt32, pid: pid_t)` for focus and `(windowID: UInt32, frame: CGRect)` for setFrame — hiding `ManipulationContext` behind the port. The conformance builds the context internally.

**File hints:** `WindowManipulator.swift` — conformance. `Grid/GridApply.swift` line 504 — `setWindowFrame`. `Grid/GridFocus.swift` lines 396, 446 — `focusWindow`.

**Depends on:** Phase 1 (pattern established) | **Unlocks:** Phase 5

**Done when:**
- [ ] DW-3.1: `Ports/WindowController.swift` exists with `protocol WindowController` — `focusWindow` and `setWindowFrame` both async
- [ ] DW-3.2: `WindowManipulator` conforms, hiding `ManipulationContext` behind the port interface
- [ ] DW-3.3: GridApply and GridFocus hold `any WindowController`
- [ ] DW-3.4: `MockWindowController` records operations with window IDs and frames
- [ ] DW-3.5: At least 3 tests (layout apply positions windows correctly, focus navigates to correct window, focus handles missing window gracefully)
- [ ] DW-3.6: `swift build` succeeds, existing tests pass

**Difficulty:** MEDIUM
**Uncertainty:** Hiding `ManipulationContext` might require GridApply to pass `pid` alongside `windowID` where it currently relies on context resolution. Check call sites.

---

### Phase 4: GridStorage Port
**Model:** sonnet
**Skills:** `none -- follows pattern, actor-internal extraction`

**Goal:** Extract persistence from GridState into a `GridStorage` protocol. GridState holds `any GridStorage` and delegates load/save. Write an in-memory fake for tests.

**Scope:**
- IN: Protocol in `Ports/GridStorage.swift`, `FileGridStorage` concrete implementation extracted from current GridState persistence code, GridState refactored to delegate persistence, `InMemoryGridStorage` test fake, roundtrip tests
- OUT: GridState's domain logic (cell assignment, focus tracking), debounce timing changes, StateValidator (no dependency on this port)

**Approach notes:** Current persistence is tightly integrated into GridState actor (markDirty → debounce → persistNow). Extract the file I/O into `FileGridStorage` but keep the debounce timer in GridState (it's domain-level scheduling, not persistence). The protocol has `load() async throws -> GridRuntimeStateData` and `save(_ data: GridRuntimeStateData) async throws`. GridState's init takes `any GridStorage`.

**File hints:** `Grid/GridState.swift` — lines 97-180 (persistence, debounce, load, persistNow). `main.swift` — GridState init and load call.

**Depends on:** Phase 1 (pattern established) | **Unlocks:** Phase 5

**Done when:**
- [ ] DW-4.1: `Ports/GridStorage.swift` exists with `protocol GridStorage: Sendable`
- [ ] DW-4.2: `FileGridStorage` extracted with atomic-write logic from current `persistNow`
- [ ] DW-4.3: GridState accepts `any GridStorage` at init, delegates load/save
- [ ] DW-4.4: `InMemoryGridStorage` test fake stores data in memory
- [ ] DW-4.5: At least 2 tests (save-load roundtrip preserves state, load with no prior save returns nil/empty)
- [ ] DW-4.6: `swift build` succeeds, existing tests pass

**Difficulty:** MEDIUM
**Uncertainty:** Debounce timer interaction with the extracted storage — ensure markDirty still works correctly with delegated save.

---

### Phase 5: Integration Validation
**Model:** haiku
**Skills:** `none -- build and runtime verification`

**Goal:** Full build, run all tests, start the server, and verify grid operations work correctly with the new port architecture.

**Scope:**
- IN: `swift build`, `swift test`, `make run`, manual smoke test (focus, layout apply, window creation, border sync)
- OUT: New feature work, performance optimization

**File hints:** N/A — verification phase only.

**Depends on:** Phase 2, Phase 3, Phase 4

**Done when:**
- [ ] DW-5.1: `swift build` succeeds with zero errors and zero warnings
- [ ] DW-5.2: `swift test` passes all existing + new tests
- [ ] DW-5.3: `make run` starts server, `thegrid ping` responds
- [ ] DW-5.4: Manual smoke: apply a layout, focus between cells, create a window — all work with borders rendering correctly

**Difficulty:** LOW
**Uncertainty:** None

---
## Test Coverage
**Level:** Targeted (critical paths per phase, per project testing policy)
## Test Plan
- [ ] Phase 1: 3+ tests for reconciler window creation via MockStateProvider
- [ ] Phase 2: 3+ tests for border sync via MockBorderRenderer
- [ ] Phase 3: 3+ tests for layout apply + focus via MockWindowController
- [ ] Phase 4: 2+ tests for persistence roundtrip via InMemoryGridStorage
- [ ] Phase 5: Integration — `swift test` + runtime smoke test
- [ ] Manual: Server starts, layouts apply, borders render, focus navigates

## Assumptions
| Assumption | Confidence | Verify Before Phase | Fallback If Wrong |
|------------|-----------|---------------------|-------------------|
| `any StateProvider` works across actor boundaries without `@Sendable` | HIGH | Phase 1 | Add `@Sendable` or use generic constraint |
| Moving `withCheckedContinuation` into SimpleBorderManager doesn't change timing | MEDIUM | Phase 2 | Fall back to thin protocol (keep completion callback in protocol) |
| Hiding ManipulationContext behind WindowController port is feasible | MEDIUM | Phase 3 | Expose context type in protocol or pass components separately |
| Debounce timer works correctly when save is delegated | HIGH | Phase 4 | Keep persistence in GridState, only protocol-ize load |

## Decision Log
| Decision | Alternatives Considered | Rationale | Phase |
|----------|------------------------|-----------|-------|
| Async-normalized ports | Thin protocols matching existing signatures | Cleaner test interfaces, consistent async; user chose this | All |
| Ports/ directory | Same file as conformer, consumer file | Architectural visibility, clean separation | Phase 1 |
| One port per phase | All protocols in one phase, tests in another | Each phase independently shippable and verifiable | All |
| Phase 1 as opus | Sonnet | Establishes the pattern + directory structure; design-heavy | Phase 1 |

---
## Notes
- Phase 2 has the highest risk (async normalization of completion callback). If border rendering breaks at runtime, fall back to keeping the completion callback in the protocol for that one method.
- Phases 2, 3, 4 are independent of each other (all depend only on Phase 1). They can be parallelized if needed.
- The `Ports/` directory establishes a pattern for future port additions (e.g., EventBus, ConfigProvider).
---
## Execution Log
_To be filled during /code-foundations:building_
