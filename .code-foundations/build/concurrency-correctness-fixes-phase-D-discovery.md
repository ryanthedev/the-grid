# Discovery + Design: Phase D - Two SLS-lag debug fixes (grace + tombstone)

## Files Found
- `grid-server/Sources/GridServer/Grid/GridReconciler.swift` — `sweepDisplacedWindows()` (~1709), `resolveDisplacedTarget` (1654), existing grace-map precedent `notStandardGrace: [UInt32: CFAbsoluteTime]` (58), sync `acquireFence`/`releaseFence` (283/302). `class GridReconciler` (not actor).
- `grid-server/Sources/GridServer/Grid/GridWindowMove.swift` — `moveWindowCrossDisplay` cross-display path; #16 abort check passes at line 458; holds `private weak var gridReconciler: GridReconciler?` and calls sync reconciler methods directly.
- `grid-server/Sources/GridServer/StateManager.swift` — `actor StateManager`; poll-prune removal at line 1418 (`applyPollResults`), `handleWindowDestroyed` removal at 1661, the `warn.poll.readd` flood site at 1388.
- `grid-server/Tests/GridServerTests/EventAllowlistTests.swift` — source-scan allowlist; `warn.poll.readd` already present (line 221); `reconcile.lift.skip` absent → must add (DW-D5).

## Current State
- `sweepDisplacedWindows` trusts SLS `wmState.windows[wid].spaces` with no grace; a deliberate cross-space move looks displaced for ~3s → bounces back.
- `warn.poll.readd` fires for EVERY poll-discovered window absent from state (~126/poll), not just genuine resurrections.
- `GridReconciler` already uses a `[UInt32: CFAbsoluteTime]` grace map (`notStandardGrace`) swept on a timer — exact precedent for the cross-move grace map.

## Gaps
- No pure predicate exists for grace/resurrection decisions.
- No `noteCrossSpaceMove` on the reconciler; no cross-move grace map.
- No removal tombstone in StateManager.

## Code Standards
- Pure decision predicates extracted as `static`/enum helpers, unit-tested off the OS boundary.
- `jlog` codes: `warn.<scope>.<reason>` / `err.<scope>` / `<scope>.<event>`. `reconcile.lift.skip` fits `<scope>.<event>`.
- Comments on their own line. Swift actors for shared mutable state. New Grid logic → one file under `Grid/`.
- Test names `test_DW_D_N_...`. Guard nil; grace check is a number-line in-range test.

## Test Infrastructure
- XCTest, `swift test` from `grid-server/`. 282 tests green baseline.
- Pattern: pure static helpers tested directly (e.g. `GridFocus.detectFocusRace`, `GridReconciler.resolveDisplacedTarget`). Actor test helpers prefixed `_test_`.

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|---------------|--------|------------|
| DW-D1 | Pure predicate `GraceWindowPolicy.withinCrossMoveGrace(movedAt:now:graceSeconds:)`: nil⇒false, recent⇒true, at/after grace⇒false | COVERED | `test_DW_D_1_nil_movedAt_returns_false`, `test_DW_D_1_recent_move_within_grace_returns_true`, `test_DW_D_1_at_grace_boundary_returns_false`, `test_DW_D_1_after_grace_returns_false` |
| DW-D2 | `sweepDisplacedWindows` skips window within cross-move grace + logs `reconcile.lift.skip` reason `recent_cross_move`; `moveWindowCrossDisplay` records via `noteCrossSpaceMove(_:)`; normal sweep after grace | COVERED | `test_DW_D_2_note_cross_space_move_skips_displaced_sweep`, `test_DW_D_2_after_grace_sweep_resumes` (reconciler-level via `_test_` seam + injected state) |
| DW-D3 | Pure predicate `GraceWindowPolicy.isResurrection(removedAt:now:graceSeconds:)`: nil⇒false, recent⇒true, expired⇒false | COVERED | `test_DW_D_3_nil_removedAt_returns_false`, `test_DW_D_3_recent_removal_returns_true`, `test_DW_D_3_at_grace_boundary_returns_false`, `test_DW_D_3_expired_returns_false` |
| DW-D4 | `warn.poll.readd` fires ONLY when `isResurrection` true; tombstone set at poll-prune AND `handleWindowDestroyed`; expired pruned each poll; never-tracked wid never logged | COVERED | `test_DW_D_4_*` via StateManager `_test_` seams: removal sets tombstone, poll re-add within grace ⇒ resurrection true; never-removed wid ⇒ false; tombstone prune |
| DW-D5 | `reconcile.lift.skip` added to EventAllowlistTests allowlist; full suite green; build clean | COVERED | existing `test_DW_2_5_no_unexpected_events_in_source` passes after allowlist update; `swift test` count grows, all green |

**All items COVERED:** YES

## Design Decisions
- New file `Grid/GraceWindowPolicy.swift`: an `enum GraceWindowPolicy` with two `static` pure functions. Both are number-line in-range checks (`now - stamp < grace`), guard nil first (cc-defensive: external/optional input guarded; predicate is pure → assertions N/A, returns neutral `false`). `withinCrossMoveGrace` and `isResurrection` are structurally identical (nil-guard + strict `<` upper bound); kept as two named functions for call-site clarity (single-use-named-boolean rationale) but both delegate to one private `within(stamp:now:grace:)` to avoid duplication.
- Boundary semantics: `now - movedAt < grace` ⇒ strict `<`, so exactly-at-grace ⇒ false (matches "at/after grace ⇒ false"). Negative/future stamps fall out naturally (`< grace` still holds only if within window; a future stamp yields negative delta < grace ⇒ true, acceptable — clock is monotonic CFAbsoluteTime in practice).
- Reconciler wiring: add `crossMoveGrace: [UInt32: CFAbsoluteTime]` map + `noteCrossSpaceMove(_ wid:)` (synchronous, mirrors `acquireFence` — `GridReconciler` is single-threaded via its serialized event path; same threading class as existing `notStandardGrace`). `sweepDisplacedWindows` consults `GraceWindowPolicy.withinCrossMoveGrace` per wid before migrating; on skip logs `reconcile.lift.skip`. Expired entries pruned inside the sweep loop (no separate timer needed — sweep already iterates all wids).
- Grace constant: `crossMoveGraceSeconds: CFAbsoluteTime = 5.0` (covers the ~3s poll lag with margin; matches fence timeout magnitude).
- StateManager: add `removalTombstone: [UInt32: CFAbsoluteTime]` (actor-isolated). Set at both removal sites (poll-prune 1418, handleWindowDestroyed 1661). Gate `warn.poll.readd` with `GraceWindowPolicy.isResurrection`. Prune expired tombstone entries each poll inside `applyPollResults`. Grace `resurrectionGraceSeconds = 3.5` (just over one poll interval of 3.0).
- Concurrency: both maps stay within their owner's existing single-threaded/actor-isolated path. No new shared concurrency state. No flag to raise.

## Prerequisites
- [x] Required files exist
- [x] Dependencies available (CFAbsoluteTime, existing test seams)
- [x] No missing prerequisites

## Recommendation
BUILD — extract two pure predicates into `GraceWindowPolicy.swift`, TDD them red→green, then wire the reconciler grace map + StateManager tombstone, and add `reconcile.lift.skip` to the allowlist.
