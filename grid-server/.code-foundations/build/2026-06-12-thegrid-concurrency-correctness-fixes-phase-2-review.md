# Review: Phase 2 - Concurrency Correctness Fixes

## Executed Results (Step 0)

- Test suite: `swift test` → 164 tests, 0 failures, 0 unexpected
- Build: `swift build` → Build complete (no warnings)
- Typecheck: clean (embedded in `swift build`)
- Lint: N/A (Swift compiler only)

---

## Requirement Fulfillment

### DW-2.1 (#2)
PREMISE:  `spaceIDReassigned` routes only when the old ID is absent from refreshed `state.spaces`; plain switches route `spaceActivated`; two laid-out desktops both preserved; `state.space_migrated.live` no longer fires on a persistent round-trip.
EVIDENCE: StateManager.swift:1787-1813, SpaceMigrationPolicy.swift:29-44, GridReconciler.swift:998-1028
TRACE: StateManager.handleSpaceChanged reads refreshed Set(state.spaces.keys), calls SpaceMigrationPolicy.classifySpaceChange; .reassigned routes .spaceIDReassigned (line 1798), .activated routes .spaceActivated (line 1807). On a round-trip (A→B where both persist), classifySpaceChange returns .activated because old ID is still in refreshedSpaceIDs → .spaceActivated routed → GridReconciler.handleSpaceActivated (border resync only, no migrateSpace call) → state.space_migrated.live never fires.
VERDICT: PASS

Tests: test_DW_2_1_classify_reassigned_when_old_absent, test_DW_2_1_classify_activated_when_old_present, test_DW_2_1_classify_activated_on_noop, test_DW_2_1_roundtrip_AB_A_both_classified_activated — all pass.

---

### DW-2.2 (#6)
PREMISE:  `migrateSpaceIDs` sorts numerically + refuses to overwrite a `hasSignificantState` destination; `state.space_migrate.snapshot{old,new,paired}` logged.
EVIDENCE: GridState.swift:265-330, SpaceMigrationPolicy.swift:50-64, 94-99
TRACE: migrateSpaceIDs calls SpaceMigrationPolicy.numericallySorted on both old and new lists (lines 272-273); for each positional pair, calls SpaceMigrationPolicy.canMigrate (which returns false if destination hasSignificantState, line 298-307); on success logs state.space_migrate.snapshot with "old", "new", "paired" fields (lines 315-320). migrateSpace (live) similarly guards with canMigrate at line 225-234, logs state.space_migrated.live at line 247.
VERDICT: PASS

Tests: test_DW_2_2_numeric_sort_not_lexicographic, test_DW_2_2_canMigrate_blocks_significant_destination, test_DW_2_2_migrateSpaceIDs_refuses_to_overwrite_significant_destination, test_DW_2_2_migrateSpaceIDs_migrates_into_empty_destination, test_DW_2_2_migrateSpaceIDs_numeric_pairing_not_lexicographic, test_DW_2_2_migrateSpace_live_refuses_significant_destination — all pass.

---

### DW-2.3 (#26)
PREMISE:  apply re-resolves the space id before its write phase (or aborts on mid-apply migration) — no zombie-space write after a transition.
EVIDENCE: GridApply.swift:130-301, SpaceMigrationPolicy.swift:81-88, GridReconciler.swift:70-74, 131-133
TRACE (DEFECT):
  1. applyLayoutBody runs inside executeAction (GridReconciler line 133 bumps generation to N+1). entryGeneration = N+1 captured at GridApply.swift:136.
  2. applyLayoutBody awaits (e.g., MainActor.run for layout definition at step 1).
  3. Concurrently, EventRouter routes .spaceIDReassigned → GridReconciler.handle() (line 488 bypasses suppression) → handleSpaceIDReassigned → gridState.migrateSpace(from:"100", to:"414"). migrateSpace does NOT call generationCounter.bump(). generationCounter remains at N+1.
  4. applyLayoutBody resumes. Stale-write check at line 286: currentGeneration = reconciler.generation = N+1 = entryGeneration. spaceStillExists = await gridState.getSpaceReadOnly("100") → nil (migrated away).
  5. SpaceMigrationPolicy.shouldAbortStaleWrite(N+1, N+1, false): returns (N+1 != N+1) && !false = false && true = FALSE. No abort.
  6. setCurrentLayout("100", ...) at line 307 calls getSpace("100") which auto-creates the space. setWindowAssignments("100", ...) at line 310 similarly. Zombie space "100" now exists alongside the real space "414". Data corruption.

The shouldAbortStaleWrite predicate (GridApply.swift:289-299) uses a logical AND: it only aborts when BOTH generation advanced AND space is gone. In the migration-only scenario (no concurrent executeAction, only the spaceIDReassigned event handler which bypasses suppression), generation does not advance. The guard fails to abort. The write proceeds against the migrated-away space, resurrecting it as a zombie.

Fix required: shouldAbortStaleWrite should also abort when !spaceStillExists alone (generation gating is over-conservative and defeats the purpose here), OR handleSpaceIDReassigned should bump the generation counter when it migrates a space.
VERDICT: FAIL

Test coverage for the predicate exists (test_DW_2_3_abort_when_generation_changed_and_space_gone, etc.), but no behavioral test exercises the concurrent migration scenario.

---

### DW-2.4 (#51)
PREMISE:  each mutating handler re-resolves active space immediately before acting; a queued `@state reset`/resize after a switch cannot hit the prior space.
EVIDENCE: GridCommandRouter.swift:317-336, 685-695; SpaceMigrationPolicy.swift:71-76
TRACE: GridCommandRouter.reresolveActiveSpaceID (line 324) calls SpaceMigrationPolicy.confirmActiveSpace; if the active space changed between initial resolve and the pre-mutation re-resolve, returns nil and the caller aborts. handleState:reset (line 692) calls reresolveActiveSpaceID before removeSpace — preventing a queued reset from hitting the prior space. The defensive trace (logging at line 328-335) is present and fires on mismatch.

Note on @resize: handleResize (line 541) resolves spaceID at entry and passes it directly to gridResize methods without a second re-resolve. The DW states "@state reset/resize … cannot hit the prior space." However, the dispatch instructions explicitly mark "the #51 part of DW-2.4" as instrumentation-only (PASS = instrumentation present, not behavioral fix). The instrumentation (confirmActiveSpace helper, reresolveActiveSpaceID wrapper with logging) is present. The behavioral fix for @state reset is present. @resize lacks explicit re-resolve but is covered by the instrumentation-only exemption for the #51 part. PASS under that reading.
VERDICT: PASS

Tests: test_DW_2_4_confirm_returns_space_when_unchanged, test_DW_2_4_confirm_aborts_when_space_switched, test_DW_2_4_confirm_aborts_when_no_active_space — all pass.

---

### DW-2.5 (#23)
PREMISE:  validator resumes on wake only when unlocked — tiled windows survive a login-screen wake (no `ax_orphan` prune while locked).
EVIDENCE: GridReconciler.swift:84-90, 531-543, 1083-1089; StateValidator.swift:96-111, 175-179
TRACE: screenLocked Bool (line 87) is set true by .screenLocked (line 531) and cleared by .screenUnlocked (line 537). handleSystemWake (line 1083-1089) checks screenLocked before calling stateValidator?.resume() — if still locked, emits reconcile.wake.validator.deferred and does NOT resume. validate(wmState:) early-returns with validate.skip.paused if paused (lines 175-179). AX orphan pruning is inside validate(), so it skips while locked.
VERDICT: PASS

Tests: test_DW_2_5_wake_while_locked_defers_validator_resume, test_DW_2_5_wake_while_unlocked_resumes_validator, test_DW_2_5_phase_2_events_are_present_in_source, test_DW_2_5_no_unexpected_events_in_source — all pass.

---

### DW-2.6 (#24)
PREMISE:  zero/degenerate display bounds skip + log `err.layout.zero_bounds` instead of tiling to the corner.
EVIDENCE: SpaceMigrationPolicy.swift:103-116, GridApply.swift:148-158, 362-369
TRACE: LayoutBoundsPolicy.isDegenerate (line 108) checks non-finite components and width/height <= 0. In applyLayoutBody (line 150) and applyCellLayout (line 364): if isDegenerate(displayBounds) → jlog("err.layout.zero_bounds", ...) + throw GridApplyError.noDisplayBounds. No window placements computed from degenerate rect.
VERDICT: PASS

Tests: test_DW_2_6_isDegenerate_zero, test_DW_2_6_isDegenerate_negative_dimension, test_DW_2_6_isDegenerate_nonfinite, test_DW_2_6_isDegenerate_valid_rect_is_false, test_DW_2_6_applyLayout_zero_bounds_skips_with_noDisplayBounds — all pass.

---

### DW-2.7 (#25)
PREMISE:  geometry-only reconfig diffs frame/visibleFrame and reapplies (debounced) after a resolution/scaling/Dock change.
EVIDENCE: SpaceMigrationPolicy.swift:119-145, StateManager.swift:1936-2007, GridReconciler.swift:1046-1064
TRACE: captureDisplayGeometry() (StateManager line 1936) snapshots frame+visibleFrame per UUID. handleDisplayConfigurationChanged diffs old vs new via DisplayGeometryPolicy.changedDisplays; for each UUID with changed geometry, routes .displayGeometryChanged. GridReconciler.handleDisplayGeometryChanged debounces 300ms (line 1053-1063) then calls gridApply.refreshAllDisplays(displayFilter: displayUUID).
VERDICT: PASS

Tests: test_DW_2_7_changedDisplays_detects_frame_change, test_DW_2_7_changedDisplays_detects_visibleFrame_only_change, test_DW_2_7_changedDisplays_empty_when_identical, test_DW_2_7_changedDisplays_ignores_connect_disconnect, test_DW_2_7_displayGeometryChanged_reapplies_after_debounce — all pass.

---

### DW-2.8 (#20,#52)
PREMISE:  the dead space-change + display-disconnect handlers are either fixed to fire or removed; borders resync after a switch.
EVIDENCE: GridReconciler.swift:1034-1041, 1234-1270; GridState.swift:201-203
TRACE (#20): handleSpaceActivated (line 1034) replaced the dead FocusState.previous*-gated border path. On .spaceActivated, syncBordersForSpace is called unconditionally (line 1039). (#52): handleDisplayDisconnected (line 1234) now unions wmState-visible spaces with GridState's own per-display snapshot (gridState.getSpaceIDsForDisplay, line 1251), so the prune works even when the display is already gone from SLS. getSpaceIDsForDisplay reads displaySpaces map (GridState line 201-203) seeded on each migrateSpaceIDs call.
VERDICT: PASS

Tests: test_DW_2_8_spaceActivated_syncs_borders_for_active_space, test_DW_2_8_disconnect_prunes_assignments_via_gridstate_displayspaces — both pass.

---

### DW-2.9 (#62s,#63s)
PREMISE:  instrumentation added (`dsp.geometry.change`, display index-vs-UUID join trace) and NO blind behavioral fix; confirmed or dropped during UAT.
EVIDENCE: StateManager.swift:411-424 (dsp.refresh.join instrumentation), StateManager.swift:1996-2006 (dsp.geometry.change instrumentation)
TRACE: dsp.refresh.join logs SLS display index, UUID, slsCount, screenCount at every refreshDisplays call (StateManager line 418) — trace-only, no behavioral change to enrichDisplayInfo's index-based join. dsp.geometry.change is logged at line 1997-2002 with old/new frame per UUID — this IS load-bearing for #25 (it routes .displayGeometryChanged which drives DW-2.7's reapply), but the #62s suspected finding about UUID-index mismatch has no behavioral fix; the existing index-based join in enrichDisplayInfo is unchanged. No blind behavioral fix applied.
VERDICT: PASS

Tests: test_DW_2_7_displayGeometryChanged_reapplies_after_debounce covers the event type. EventAllowlistTests (test_DW_2_5_phase_2_events_are_present_in_source) verifies dsp.geometry.change appears in source.

---

**All requirements met:** NO (DW-2.3 FAIL)

---

## Test-DW Coverage

| DW Item | Test(s) | Type |
|---------|---------|------|
| DW-2.1 | test_DW_2_1_classify_reassigned_when_old_absent, test_DW_2_1_classify_activated_when_old_present, test_DW_2_1_classify_activated_on_noop, test_DW_2_1_roundtrip_AB_A_both_classified_activated | Automated (ran Step 0) |
| DW-2.2 | test_DW_2_2_numeric_sort_not_lexicographic, test_DW_2_2_canMigrate_*, test_DW_2_2_migrateSpaceIDs_*, test_DW_2_2_migrateSpace_live_* | Automated |
| DW-2.3 | test_DW_2_3_abort_when_generation_changed_and_space_gone, test_DW_2_3_no_abort_when_space_still_exists, test_DW_2_3_no_abort_when_generation_unchanged | Automated (predicate only) — NO behavioral test for migration-only concurrent scenario |
| DW-2.4 | test_DW_2_4_confirm_returns_space_when_unchanged, test_DW_2_4_confirm_aborts_when_space_switched, test_DW_2_4_confirm_aborts_when_no_active_space | Automated (predicate) |
| DW-2.5 | test_DW_2_5_wake_while_locked_defers_validator_resume, test_DW_2_5_wake_while_unlocked_resumes_validator, test_DW_2_5_phase_2_events_are_present_in_source, test_DW_2_5_no_unexpected_events_in_source | Automated |
| DW-2.6 | test_DW_2_6_isDegenerate_*, test_DW_2_6_applyLayout_zero_bounds_skips_with_noDisplayBounds | Automated |
| DW-2.7 | test_DW_2_7_changedDisplays_*, test_DW_2_7_displayGeometryChanged_reapplies_after_debounce | Automated |
| DW-2.8 | test_DW_2_8_spaceActivated_syncs_borders_for_active_space, test_DW_2_8_disconnect_prunes_assignments_via_gridstate_displayspaces | Automated |
| DW-2.9 | test_DW_2_7_displayGeometryChanged_reapplies_after_debounce (type coverage), EventAllowlistTests (source presence) | Automated (observed behavior for instrumentation-only) |

Coverage matches stated level (Backend 100% for pure decision predicates). DW-2.3 test coverage exists for the predicate but not for the behavioral concurrent scenario where the defect occurs.

---

## Dead Code

None found in the reviewed Phase 2 files.

---

## Correctness Dimensions

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Concurrency | FAIL | DW-2.3 defect demonstrated above: spaceIDReassigned migration during applyLayoutBody awaits does not bump the generation counter; shouldAbortStaleWrite returns false; zombie space written. GridState is an actor (correct); GridReconciler is a class but protected by EventRouter serialization (acceptable). No new DispatchQueue+locks for shared state. |
| Error Handling | PASS | isDegenerate throws noDisplayBounds (logged). migrateSpaceIDs count mismatch logs and processes common prefix. Empty catch blocks in markDirty are documented (Cancelled = newer save pending). |
| Resources | PASS | GridState.saveTask is properly cancelled and replaced on each markDirty (no task leak). Weak references in EventRouter and module dependencies prevent retain cycles. |
| Boundaries | PASS | numericallySorted handles nil UInt64 parse (non-numeric sorts last). migrateSpaceIDs uses limit = min(old.count, new.count) for safe indexing. isDegenerate guards non-finite CGFloat. |
| Security | N/A | No untrusted external input (all data from local SkyLight/AX APIs). |

---

## Notes (non-blocking)

1. **DW-2.4 @resize gap (design observation)**: handleResize resolves spaceID at entry but does not call reresolveActiveSpaceID before the actual gridResize mutation. The DW marks this as the instrumentation-only "#51 part", but the DW statement "a queued resize after a switch cannot hit the prior space" is fully addressed only for @state reset. The reresolveActiveSpaceID helper is available and its call would be a one-line addition.

2. **DW-2.9 comment overlap**: The comment at StateManager.swift:1997 says "#62s instrumentation (load-bearing — also drives the #25 fix)". This wording is slightly misleading: dsp.geometry.change is indeed load-bearing for #25 (it routes .displayGeometryChanged, which DW-2.7 requires). The #62s suspected index-vs-UUID mismatch is separately addressed by the dsp.refresh.join trace. The comment should clarify these are distinct concerns.

3. **StateManager.handleSystemWake: displaySpaces snapshot does not seed GridState's own map**: The wake migration at GridReconciler.swift:1091-1104 builds displaySpaces from wmState.displays/spaces and calls migrateSpaceIDs. However, migrateSpaceIDs updates displaySpaces (GridState line 323) only for the current run's new list. If the wake occurs after a display disconnect where the old snapshot was not seeded, displaySpaces[display.uuid] will be empty and no migration runs. This is a pre-existing design consideration, not a Phase 2 regression.

4. **EventAllowlistTests naming**: test_DW_2_5_phase_2_events_are_present_in_source and test_DW_2_5_no_unexpected_events_in_source are labeled DW-2.5 but cover the event allowlist broadly. Minor naming imprecision, not a correctness issue.

---

## Issues (FAIL)

### Issue 1: DW-2.3 stale-write abort misses migration-only concurrent scenario

- **File**: GridApply.swift:286-301, SpaceMigrationPolicy.swift:82-88
- **Demonstrated by TRACE**: 
  - applyLayoutBody enters executeAction → generation bumped to N+1; entryGeneration = N+1
  - applyLayoutBody awaits (e.g. MainActor.run for layout at step 1, GridApply.swift:139)
  - EventRouter concurrently routes .spaceIDReassigned → GridReconciler.handle() line 488 bypasses suppression → handleSpaceIDReassigned → gridState.migrateSpace(from:"100", to:"414"); migrateSpace has no generationCounter.bump() call
  - applyLayoutBody resumes; stale-write check: currentGeneration = N+1 = entryGeneration; spaceStillExists = getSpaceReadOnly("100") → nil
  - shouldAbortStaleWrite(N+1, N+1, false) = (N+1 != N+1) && true = **false** → no abort
  - setCurrentLayout("100",...) and setWindowAssignments("100",...) call getSpace("100") which auto-creates → zombie space "100" persists alongside real "414"
- **Fix option A**: Change shouldAbortStaleWrite to `!spaceStillExists` (abort when space gone, regardless of generation change) — remove the generation gate. This is the minimal fix and matches the DW requirement "no zombie-space write after a transition."
- **Fix option B**: Have handleSpaceIDReassigned call `generationCounter.bump()` when it actually migrates a space. This aligns the generation counter semantics with "any significant state mutation bumps the counter."

**Verdict: FAIL — DW-2.3 zombie-write defect demonstrated by TRACE.**
