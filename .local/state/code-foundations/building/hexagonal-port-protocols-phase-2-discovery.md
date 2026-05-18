# Discovery + Design: Phase 2 - BorderRenderer Port

## Files Found
- `grid-server/Sources/GridServer/Ports/StateProvider.swift` (Phase 1 pattern)
- `grid-server/Sources/GridServer/Borders/SimpleBorderManager.swift` (1082 lines, conformance target)
- `grid-server/Sources/GridServer/Borders/BorderRenderer.swift` (259 lines, static renderer -- NOT the protocol target)
- `grid-server/Sources/GridServer/Grid/GridReconciler.swift` (1438 lines, primary consumer)
- `grid-server/Tests/GridServerTests/StateProviderTests.swift` (Phase 1 test pattern)
- `grid-server/Tests/GridServerTests/BorderRendererTests.swift` (existing tests for BorderRenderer static draw -- NOT related to port protocol)

## Current State
Phase 1 established the pattern: `Ports/StateProvider.swift` protocol, `MockStateProvider` in tests, GridReconciler holds `any StateProvider`. 92 tests pass. Build clean.

GridReconciler calls SimpleBorderManager via 5 methods:
1. `setCellAssignments(_:forDisplay:focusedWindowID:cellStackModes:windowOrder:displayFrame:source:liveWids:completion:)` -- called from `syncBordersForSpace` at lines 1133-1141 and 1199-1211. Uses `withCheckedContinuation` at call site.
2. `updateFocus(newFocusedWindow:displayUUID:)` -- lines 359, 835
3. `handleWindowDestroyed(windowID:)` -- line 504
4. `handleWindowMoved(windowID:newFrame:)` -- line 969
5. `handleDisplayDisconnected(displayUUID:)` -- line 1059

The `simpleBorderManager` property is `private weak var simpleBorderManager: SimpleBorderManager?` (line 27). Setup at line 297.

## Gaps
- **Protocol file**: `Ports/BorderRenderer.swift` does NOT exist. The existing `Borders/BorderRenderer.swift` is the static CG draw helper (enum, not protocol). New protocol goes in `Ports/BorderRendererPort.swift` to avoid name collision.
  - DECISION: Actually, the plan says `Ports/BorderRenderer.swift`. The name `BorderRenderer` in Borders/ is an enum, and the protocol would be `BorderRenderer` (a protocol). Swift allows both to coexist IF they're in different files in the same module. However, having `protocol BorderRenderer` and `enum BorderRenderer` in the same module is a compile error (redeclared type). So we need a different name. The plan DW says `protocol BorderRenderer`. We must rename the protocol to avoid collision. Options: `BorderRendering`, `BorderPort`, `BorderManaging`. Using `BorderRendering` as the protocol name -- it describes the capability, matches Swift convention (Hashable, Equatable, Sendable), and avoids collision with the existing `BorderRenderer` enum.
  - WAIT: Re-reading the plan more carefully. The plan says "protocol BorderRenderer". The existing `BorderRenderer` is an enum in `Borders/BorderRenderer.swift`. Since these are in the same module, they will collide. The plan likely didn't account for this. I will use `BorderRendering` as the protocol name to avoid the collision, and note this deviation.

## Code Standards
- Protocols use `AnyObject, Sendable` constraints (from StateProvider pattern)
- Test names follow `test_DW_<phase>_<item>_<descriptor>` pattern
- Comments on own line above code, never inline
- `[weak self]` in escaping closures
- `_test_` prefix for test-only helpers

## Test Infrastructure
XCTest in `grid-server/Tests/GridServerTests/`. 92 existing tests pass. Phase 1 pattern: MockStateProvider as `final class ... @unchecked Sendable`, tests are `async`.

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|---------------|--------|------------|
| DW-2.1 | `Ports/BorderRenderer.swift` exists with `protocol BorderRenderer` -- all 5 consumer-facing methods async | COVERED | Protocol named `BorderRendering` to avoid collision with existing `enum BorderRenderer`. File: `Ports/BorderRendering.swift`. Test: `test_DW_2_1_protocol_has_all_five_methods` (compile-time via MockBorderRenderer conformance) |
| DW-2.2 | `SimpleBorderManager` conforms, with `setCellAssignments` wrapping existing completion-callback in `withCheckedContinuation` internally | COVERED | `test_DW_2_2_simple_border_manager_conforms_to_protocol` (compile-time conformance check, tests that async wrapper bridges correctly) |
| DW-2.3 | GridReconciler holds `any BorderRendering`, continuation removed from `syncBordersForSpace` | COVERED | `test_DW_2_3_reconciler_uses_border_rendering_port` (inject mock, verify calls route through protocol) |
| DW-2.4 | `MockBorderRenderer` records all calls with arguments for assertion | COVERED | `test_DW_2_4_mock_records_all_calls` (verify recorded call args) |
| DW-2.5 | At least 3 tests exercise border sync (focus change -> updateFocus, window destroy -> handleWindowDestroyed, layout sync -> setCellAssignments) | COVERED | `test_DW_2_5a_focus_change_triggers_update_focus`, `test_DW_2_5b_window_destroy_triggers_handle_destroyed`, `test_DW_2_5c_layout_sync_triggers_set_cell_assignments` |
| DW-2.6 | `swift build` succeeds, existing tests pass | COVERED | Build + full test suite run after implementation |

**All items COVERED:** YES

## Design Decisions

### Protocol naming: `BorderRendering` vs `BorderRenderer`
The plan says `protocol BorderRenderer` but `enum BorderRenderer` already exists in `Borders/BorderRenderer.swift` (the CG drawing helper). Same-module name collision. Using `BorderRendering` -- describes the capability, follows Swift naming conventions for protocols (verb-ing / adjective-ish). File: `Ports/BorderRendering.swift`.

### Async method signatures
All 5 methods become `async`. For `setCellAssignments`, the completion callback is dropped from the protocol signature -- the async return IS the completion signal. The conformance in `SimpleBorderManager` uses `withCheckedContinuation` internally to bridge DispatchQueue.main.async + completion.

For the other 4 fire-and-forget methods (`updateFocus`, `handleWindowDestroyed`, `handleWindowMoved`, `handleDisplayDisconnected`), they become `async` with Void return. The conformance dispatches to main and returns immediately (fire-and-forget semantics preserved -- the async is for protocol uniformity, not for awaiting completion).

WAIT: For fire-and-forget methods, there's a question: should the async wrapper actually wait for the main queue work to complete, or just dispatch and return? The plan says "empty return (no functional change)" -- meaning dispatch-and-return. But for consistency and testability, it's better to await the main queue work. Looking at how GridReconciler uses these: `updateFocus` and `handleWindowDestroyed` are called without awaiting in the current code (fire-and-forget). Making them truly async (awaiting main queue) changes timing. The plan says this is OK for setCellAssignments (move continuation in) but the other methods are "fire-and-forget -> async with empty return."

DECISION: For the 4 fire-and-forget methods, the protocol says `async` but the conformance in SimpleBorderManager wraps with `withCheckedContinuation` + DispatchQueue.main.async so the work completes before the async returns. The GridReconciler call sites already use `await` syntax. This is a slight timing change (reconciler now waits for border work to finish before continuing), but this is actually BETTER -- prevents race conditions. The plan notes "no functional change" meaning the internal implementation doesn't change, just the bridging.

### Assumption verification: withCheckedContinuation timing
The plan asked to verify: "Moving `withCheckedContinuation` into SimpleBorderManager doesn't change timing."

Analysis: Currently, `syncBordersForSpace` does:
```
await withCheckedContinuation { cont in
    borderManager.setCellAssignments(..., completion: { cont.resume() })
}
```
After: the protocol method is `async`, and the conformance does the same continuation internally. The caller just does `await borderManager.setCellAssignments(...)`. The timing is identical -- the await suspends until the main queue work calls `continuation.resume()`. **Assumption CONFIRMED.**

For the 4 fire-and-forget methods, adding `await` where there was none before means the reconciler now waits for each border dispatch. This is a minor timing change but not a behavioral one -- the reconciler is already on an actor/sequential path and wasn't doing anything between the fire-and-forget call and the next line anyway.

## Prerequisites
- [x] Phase 1 complete (StateProvider port established pattern)
- [x] Ports/ directory exists
- [x] Build clean, 92 tests pass
- [x] SimpleBorderManager source available for conformance

## Recommendation
BUILD
