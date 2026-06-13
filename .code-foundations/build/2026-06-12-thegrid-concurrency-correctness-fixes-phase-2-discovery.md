# Discovery + Design: Phase 2 - Space & wake state migration

## Finding ID → JSON entry map (authoritative spec)

The plan references findings by `#ID`; the JSON has no `id` field, so IDs map by title to array positions.

| Plan DW | Finding | JSON entry | File:line | Confidence |
|---------|---------|-----------|-----------|------------|
| DW-2.1 | #2 | confirmed[0] "Every space switch routes spaceIDReassigned" | StateManager.swift:1762 | confirmed |
| DW-2.2 | #6 | confirmed[43] "Wake space-ID migration pairs a stale persisted snapshot positionally (string-sorted)" | GridState.swift:236 | confirmed |
| DW-2.3 | #26 | confirmed[51] "applyLayoutBody writes layout back to a space ID that spaceIDReassigned migrated away mid-apply" | (GridApply.swift body) | confirmed |
| DW-2.4 | #51 | confirmed[39] "Router-level stale-space TOCTOU" | GridCommandRouter.swift:305 | **suspected** (severity low) |
| DW-2.5 | #23 | confirmed[40] "Wake unconditionally resumes StateValidator while screen is still locked" | GridReconciler.swift:962 | confirmed |
| DW-2.6 | #24 | confirmed[41] "No zero-bounds guard in layout apply" | GridApply.swift:136 | confirmed |
| DW-2.7 | #25 | confirmed[42] "Resolution/scaling/dock changes never reapply layouts" | StateManager.swift:1903 | confirmed |
| DW-2.8 | #20 | confirmed[16] "Reconciler space-change handling is dead code" | GridReconciler.swift:866 | confirmed |
| DW-2.8 | #52 | confirmed[44] "Reconciler's display-disconnect zombie prune is dead code" | GridReconciler.swift:1118 | confirmed |
| DW-2.9 | #62s | suspected[4] "Display-reconnect reapply runs against a stale snapshot" | GridReconciler.swift:1089 | suspected |
| DW-2.9 | #63s | suspected[5] "refreshDisplays joins SLS order to NSScreen by array index" | StateManager.swift:404 | suspected |

Note: the plan tags #51 (router stale-space TOCTOU) as confirmed in its DW list, but the audit marks it **suspected** (confidence: suspected, severity low). The mechanism (resolve-once-act-across-awaits) is real and code-visible, and the fix (re-resolve immediately before the mutating call) is a safe correctness hardening regardless of whether the race is reproducible. We implement the re-resolve guard (it is a defensive structural fix, not a blind behavioral change) AND add the trace log. This is consistent with both the plan's DW-2.4 and the audit's instrument-then-confirm rule.

## Files Found (all exist in worktree)
- `grid-server/Sources/GridServer/StateManager.swift` — `handleSpaceChanged` (1728), `handleDisplayConfigurationChanged` (1888); both `private` to the actor.
- `grid-server/Sources/GridServer/Grid/GridReconciler.swift` — `handle` switch (457), `handleSpaceIDReassigned` (977), `handleSpaceChanged` (958), `handleSystemWake` (1009), `handleDisplayDisconnected` (1170), `handleFocusChanged` (878). Class (Approach B). Has `generation` (74), `setApply/setValidator/_test_*` hooks.
- `grid-server/Sources/GridServer/Grid/GridState.swift` — actor; `migrateSpace` (207), `migrateSpaceIDs` (236), `hasSignificantState` (279, private), `spaces`/`displaySpaces` private dicts.
- `grid-server/Sources/GridServer/Grid/GridApply.swift` — `applyLayout` (76) wraps `applyLayoutBody` (120) in `executeAction`; `refreshAllDisplays` (393); `GridApplyError` enum (22).
- `grid-server/Sources/GridServer/Grid/GridFocus.swift` — `getDisplayBoundsForSpace` (948) → `.zero` on unknown; `findActiveSpaceID` (973).
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` — `resolveActiveSpaceID` (312); handlers at 521 (resize), 665 (state reset).
- `grid-server/Sources/GridServer/EventRouter.swift` — `StateEvent` enum; cases at 31-39. No `spaceActivated` / `displayGeometryChanged` cases yet.
- `grid-server/Sources/GridServer/WorkspaceObserver.swift` — lock notifications already wired (98-111), routed as `.screenLocked`/`.screenUnlocked`.

## Current State
- **#2**: `handleSpaceChanged` routes `.spaceIDReassigned` for ANY display whose `currentSpaceID` differs from the pre-refresh value — i.e. every plain desktop switch. `migrateSpace` then moves the old space's whole grid state onto the new ID, wiping the destination if it already had state. There is no `spaceActivated` event.
- **#6**: wake builds `displaySpaces` with `spaceIDs.sorted()` over `[String]` (lexicographic, so "999" > "1001"); `migrateSpaceIDs` pairs positionally and overwrites `spaces[newSpaceID]` with NO `hasSignificantState` destination guard.
- **#26**: `applyLayoutBody` resolves `spaceID` once at entry, then writes `setCurrentLayout`/`setWindowAssignments` after many awaits; if a reassignment migrated that ID mid-apply, the write resurrects a zombie space. The reconciler exposes `generation` (P1) but `applyLayoutBody` never reads it.
- **#51**: handlers call `resolveActiveSpaceID()` once then act across awaits.
- **#23**: `handleSystemWake` Step 0 calls `stateValidator?.resume()` unconditionally — even at the lock screen. No lock-state tracking in the reconciler (it pauses/resumes per event but does not remember the current lock state).
- **#24**: `getDisplayBoundsForSpace` returns `.zero`; `applyLayoutBody`/`applyCellLayout`/`refreshAllDisplays` feed it straight into layout math with no guard.
- **#25**: `handleDisplayConfigurationChanged` diffs only UUID SETS; geometry-only change → empty sets → no event. `GridReconciler.handle` has no `.displayReconfigured` case (`default:` ignores it).
- **#20**: `handleSpaceChanged` (reconciler, border-sync) only runs from `handleFocusChanged` when `focusState.previousSpaceID != nil` — never populated → dead. Borders stale after a switch.
- **#52**: `handleDisplayDisconnected` reads `wmState.spaces` AFTER StateManager already refreshed spaces out → `affectedSpaceIDs` empty → prune is dead code.
- **#62s/#63s**: suspected; only instrumentation per the instrument-then-confirm rule.

## Gaps (plan vs reality)
| # | Gap | Resolution |
|---|-----|-----------|
| 1 | Plan says #51 confirmed; audit says suspected | Implement the re-resolve guard (defensive structural fix, safe) + add `cmd.space.reresolve` trace. Documented above. |
| 2 | `handleSpaceChanged`/`handleDisplayConfigurationChanged` are `private` actor methods → not directly unit-testable | Extract pure `static` decision predicates (per code-standards "extract pure decision predicates as `static` helpers") and unit-test those off the actor. Wire the predicates into the private methods. |
| 3 | Plan mentions `displayGeometryChanged` event name; existing enum has `displayReconfigured` | Add a new `.displayGeometryChanged(displayUUID:)` case (frame-diff) distinct from the UUID-set `displayReconfigured`; reconciler handles it debounced. |
| 4 | No `spaceActivated` event exists | Add `.spaceActivated(spaceID:displayUUID:)` case; plain switches route it; reconciler handles it by syncing borders (closes #20 too). |
| 5 | `migrateSpace` already has a `hasSignificantState(oldState)` guard on SOURCE but NOT a destination guard | Add destination guard to both `migrateSpace` and `migrateSpaceIDs`. |

## Code Standards (applied)
- Swift **actors** for shared mutable state — GridState stays an actor; lock-state flag lives on the GridReconciler class (already the single-consumer event handler; no new lock primitive).
- `jlog` codes: `state.space_migrate.snapshot`, `err.layout.zero_bounds`, `dsp.geometry.change`, `warn.space.derive_override`, `reconcile.space.activated`, `cmd.space.reresolve`, plus the existing signatures.
- Comments on their own line, never inline.
- Extract **pure decision predicates** as `static` helpers, unit-tested off the AX/SkyLight boundary: reassignment-gate, numeric-sort + significant-state guard, zero-bounds guard, geometry-diff.
- `[weak self]` + `guard let self else { return }` already used in the wake task; new debounce task follows the same pattern.

## Test Infrastructure
- XCTest; `@testable import GridServer`. 131 tests green at baseline (build clean).
- Fakes: `MockStateProvider` (StateProviderTests.swift), `InMemoryGridStorage` (GridStorageTests.swift), `StubGridApply` (WakeLayoutRestoreTests.swift — subclass overriding `refreshAllDisplays`).
- Reconciler test hooks: `setup`, `_test_setup`, `setApply`, `setValidator`, `_test_handle`, `_test_triggerFocusChanged`, `generation`. Validator: `pause`/`resume`/`peekHeartbeatTickCount`/`_test_seedOrphanCounts`.
- Pure-predicate unit tests are the primary `[U]` vehicle; integration `[I]` tests drive the reconciler/GridState through real wiring with fakes. Live `[M]` items (round-trip, login-wake, resolution change, border resync, #62s/#63s) are asserted via `jlog` signatures during UAT.

## Design Decisions

### Simplifying-complexity / control-flow application
- **Pure predicates (OT-1 reduce information, off-boundary testable):**
  - `SpaceMigrationPolicy.classifySpaceChange(oldSpaceID:newSpaceID:refreshedSpaceIDs:) -> SpaceChangeRouting` returning `.reassigned` (old absent from refreshed set) or `.activated` (old still present). One decision, named result type (OP-1: no bare bool/tuple).
  - `SpaceMigrationPolicy.numericallySorted(_ ids: [String]) -> [String]` — numeric sort (#6).
  - `SpaceMigrationPolicy.canMigrate(destinationHasSignificantState:sourceHasSignificantState:) -> Bool` — destination guard (#6); single source of truth used by both migrate paths.
  - `LayoutBoundsPolicy.isDegenerate(_ rect: CGRect) -> Bool` — zero/degenerate guard (#24): width or height `<= 0`, or non-finite.
  - `DisplayGeometryPolicy.changedDisplays(old:new:) -> [String]` — per-UUID frame/visibleFrame diff (#25/#62s). Named, pure, off-NSScreen.
- **Error reduction (ER hierarchy):**
  - #24 zero-bounds: **Define out is unsafe** (DO-1: a zero frame is NOT normal correct operation — it is a degenerate state we must not act on; DO-3: operators need to see it). So **fail-fast + log** (`err.layout.zero_bounds`) and skip the apply — surface, do not mask. Returns cleanly (no throw cascade) since `refreshAllDisplays` already aggregates per-display errors; `applyLayoutBody` throws `GridApplyError.noDisplayBounds` so the existing aggregation path reports it.
  - #26 mid-apply migration: **fail-fast** — abort the write phase with a logged `warn.layout.stale_space` and skip the GridState write (essential error, NA-3 silent-data-loss risk: writing to a migrated ID corrupts a live space). Detected by re-reading `reconciler.generation` captured at entry vs before the write, AND by re-checking the space still exists.
- **Guard clauses** for the new predicates at call sites (flatten nesting, NS-1 ≤3 levels).
- **Lock-state tracking:** add `private var screenLocked: Bool` to the reconciler, set in the existing `.screenLocked`/`.screenUnlocked` cases (single writer, the serialized event consumer — no new actor needed; §8 satisfied because the reconciler runs one event at a time). `handleSystemWake` Step 0 becomes: resume only if `!screenLocked`; otherwise log `reconcile.wake.validator.deferred` and let the later `.screenUnlocked` resume it.
- **#52 dead prune:** the cleanest fix is to have `handleDisplayDisconnected` diff GridState's OWN per-display space map instead of the post-refresh `wmState.spaces` (which no longer lists the gone display). GridState already owns `displaySpaces`. Add `GridState.getSpaceIDsForDisplay(_:)` reading `displaySpaces`. This pulls the complexity into the module that owns the data (PD-1/PD-3) and removes the reliance on stale wmState.
- **#20/#2 border resync:** the new `.spaceActivated` event handler in the reconciler calls `syncBordersForSpace` for the activated space — fixing the dead `handleSpaceChanged` border-sync path without needing `FocusState.previous*`.
- **#62s/#63s (suspected):** instrumentation only. `dsp.geometry.change` is emitted by the #25 geometry diff (load-bearing — also drives the real #25 fix). For #63s add `dsp.refresh.join` trace in `refreshDisplays` recording `(index, uuid, screenCount, matchedByUUID?)` — NO behavioral change to the index-join. Confirm-or-drop in UAT.

### Why not actorize / restructure P1 primitives
The fixes consume P1's `generation` counter (read-only) and add a plain `Bool` lock flag on the existing single-consumer class. No primitive is restructured; the live command path is untouched except the defensive re-resolve in the router (additive guard). No UPDATE_PLAN needed.

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|---------------|--------|------------|
| DW-2.1 | #2 spaceIDReassigned only when old ID absent from refreshed spaces; plain switch → spaceActivated; round-trip preserves both | COVERED | `[U]` `test_DW_2_1_classify_reassigned_when_old_absent`, `test_DW_2_1_classify_activated_when_old_present`, `test_DW_2_1_roundtrip_AB_A_both_classified_activated`; `[M]` no `state.space_migrated.live` on persistent round-trip |
| DW-2.2 | #6 migrateSpaceIDs numeric sort + refuse overwrite of hasSignificantState destination; `state.space_migrate.snapshot{old,new,paired}` logged | COVERED | `[U]` `test_DW_2_2_numeric_sort_not_lexicographic`, `test_DW_2_2_refuses_overwrite_significant_destination`, `[D]` `test_DW_2_2_count_mismatch_partial_migrates_prefix`; `[I]` `test_DW_2_2_migrateSpaceIDs_preserves_destination_state` |
| DW-2.3 | #26 apply re-resolves space id before write phase (or aborts on mid-apply migration) — no zombie write | COVERED | `[I][D]` `test_DW_2_3_applyLayoutBody_aborts_when_space_migrated_midapply` (drive a generation bump + space removal between entry and write); `[U]` `test_DW_2_3_staleSpace_predicate` |
| DW-2.4 | #51 each mutating handler re-resolves active space immediately before acting | COVERED | `[I]` `test_DW_2_4_router_reresolves_space_before_mutation` (fake StateManager returns space A then B; assert mutation targets B / aborts on mismatch) |
| DW-2.5 | #23 validator resumes on wake only when unlocked | COVERED | `[I][D]` `test_DW_2_5_wake_while_locked_defers_validator_resume`, `test_DW_2_5_wake_while_unlocked_resumes_validator` (drive `.screenLocked` then `.systemWoke`; assert validator stays paused) |
| DW-2.6 | #24 zero/degenerate bounds skip + log `err.layout.zero_bounds` | COVERED | `[U][D]` `test_DW_2_6_isDegenerate_zero/negative/nonfinite/valid`; `[I][D]` `test_DW_2_6_applyLayout_zero_bounds_skips_and_logs` |
| DW-2.7 | #25 geometry-only reconfig diffs frame/visibleFrame and reapplies (debounced) | COVERED | `[U]` `test_DW_2_7_changedDisplays_detects_frame_change`, `test_DW_2_7_changedDisplays_empty_when_identical`, `test_DW_2_7_changedDisplays_visibleFrame_change`; `[M]` resolution change reapplies |
| DW-2.8 | #20,#52 dead space-change + display-disconnect handlers fixed/removed; borders resync after switch | COVERED | `[I]` `test_DW_2_8_spaceActivated_syncs_borders` (fake border renderer records setCellAssignments); `[I]` `test_DW_2_8_disconnect_prunes_via_gridstate_displayspaces` |
| DW-2.9 | #62s,#63s instrumentation added; confirmed/dropped in UAT | COVERED (instrumentation only) | `[U]` `test_DW_2_9_geometry_change_signature_present` (assert `dsp.geometry.change` emitted by diff path); `[M]` `dsp.refresh.join` + `dsp.geometry.change` observed in UAT. **No blind behavioral fix.** |

**All items COVERED:** YES (DW-ID count = 9 = prompt count.)

## Prerequisites
- [x] P1 primitives shipped (`generation` counter readable — confirmed at GridReconciler.swift:74).
- [x] Lock state observable via `com.apple.screenIsLocked/Unlocked` (WorkspaceObserver.swift:101-111) — **assumption VERIFIED**; already routed as `.screenLocked`/`.screenUnlocked` into the reconciler.
- [x] StateProvider/GridStorage/BorderRendering fakes exist.
- [x] Baseline build clean, 131 tests green.

## Recommendation
**BUILD.** All 9 DW items are COVERED with concrete tests. The suspected findings (#51 router TOCTOU re-resolve is a safe defensive structural fix; #62s/#63s are instrumentation-only). No P1 primitive restructuring and no risky live-command-path change required.
