# Discovery + Design: Phase E - grace-sweep AX re-query (Chrome torn-tab tiling)

## Files Found
- grid-server/Sources/GridServer/Grid/GridAssignment.swift:89-97 — classifyWindow PIP heuristic (NOT changed)
- grid-server/Sources/GridServer/Grid/GridReconciler.swift:575-602 — notStandardGraceSweep (stale-cache bug)
- grid-server/Sources/GridServer/Grid/WindowAdoptionPolicy.swift:61-75 — NotStandardGracePolicy (defaultGraceWindow = 3.0)
- grid-server/Sources/GridServer/Ports/StateProvider.swift — port (only getState today)
- grid-server/Sources/GridServer/StateManager.swift:627 getAXProperties; :1609-1631 the canonical AX-field update pattern
- grid-server/Tests/GridServerTests/StateProviderTests.swift:7 — MockStateProvider fake
- grid-server/Tests/GridServerTests/EventAllowlistTests.swift:217-218 — not_standard events

## Current State
notStandardGraceSweep reads the STALE `wmState.windows[String(wid)]` snapshot and re-runs classifyWindow on it. Since AX is never re-queried, a window whose cached hasFullscreenButton=false (PIP heuristic race) re-bails .floating every tick until grace expires. StateProvider exposes only getState(); StateManager.getAXProperties is private. defaultGraceWindow is already 3.0s.

## Gaps
1. No StateProvider method to re-query a single window's AX props.
2. Grace sweep classifies stale state instead of fresh AX.

## Code Standards
- jlog scope-first dot codes; `warn.<scope>.<reason>` for recoverable conditions. New event added to EventAllowlistTests.
- Swift actors for shared state; never `Task {}` back into same actor — direct await.
- Comments on own line above code. `_test_` prefix for test seams.

## Test Infrastructure
XCTest. MockStateProvider fake conforms to StateProvider. Reconciler `_test_setup`, `_test_notStandardGraceSweep`, `_test_notStandardGraceCount`, `_test_triggerWindowCreated` seams already exist. GridState `_test_setLayout/_test_setCells/getCellWindows`.

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|---------------|--------|------------|
| DW-E1 | StateProvider method re-queries one window's AX props, updates cache, returns updated state (nil if gone); StateManager implements via getAXProperties | COVERED | StateManager integration not unit-testable off AX boundary; covered by protocol conformance + MockStateProvider.refreshWindowAXProperties drives DW-E2. Real impl verified by build + live UAT. |
| DW-E2 | notStandardGraceSweep re-queries AX and re-classifies FRESH state; fake reports floating via getState but standard via refresh → window routed to tiling | COVERED | test_DW_E2_grace_sweep_requeries_ax_and_tiles (red before fix, green after): mock getState window=AXStandardWindow+hasFullscreenButton=false (floating), refresh returns hasFullscreenButton=true (standard); after sweep assert grace map cleared + window assigned to a cell |
| DW-E3 | NotStandardGracePolicy.shouldReevaluate grace window >= ~3s; boundary unit test | COVERED | test_DW_E3_grace_window_at_least_3s (asserts defaultGraceWindow >= 3.0 and shouldReevaluate true at 3.0s boundary, false just past) |
| DW-E4 | full suite green; build clean; new jlog in EventAllowlistTests | COVERED | swift build clean (baseline warnings only); swift test all green; reconcile.not_standard.refresh_gone added to allowlist |

**All items COVERED:** YES

## Design Decisions
- Add `refreshWindowAXProperties(_ windowID: UInt32) async -> WindowState?` to StateProvider. Returns the updated WindowState, nil if window absent from state or pid unresolvable. Keeps the port narrow (single window, returns the fresh value the caller classifies — no broad re-query).
- StateManager implementation reuses the existing getAXProperties + the AX-field copy block (StateManager.swift:1611-1618 pattern), writes back to state.windows, returns the copy. Direct actor method (no Task re-entrancy).
- notStandardGraceSweep: replace stale `wmState.windows[...]` read with `await stateProvider.refreshWindowAXProperties(wid)`. Keep expiry-first guard. nil refresh → drop grace entry + jlog `reconcile.not_standard.refresh_gone` (new, recoverable). The getState() call at top of sweep is no longer needed for window lookup — removed; stateProvider guard retained.
- MockStateProvider: add a `refreshStates: [String: WindowState]` map; refreshWindowAXProperties returns that override (falling back to `state.windows`) so a test can make getState and refresh disagree.

## Prerequisites
- [x] Required files exist
- [x] Dependencies available
- [x] Baseline: 297 tests green

## Recommendation
BUILD — re-query AX in the grace sweep via a new narrow StateProvider port method.
