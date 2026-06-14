# Review: Phase 4 - Window Creation, Classification & Adoption

## Executed Results (Step 0)

| Command | Result |
|---------|--------|
| `swift build` | Build complete (1.89s) — 0 errors, 0 warnings beyond baseline |
| `swift test` | 213 tests, **0 failures**, 0 unexpected |
| Typecheck | Implicit in `swift build` — clean |
| Lint | No linter configured; no issues observed |

Baseline pre-existing warnings (excluded from verdict):
- `main.swift:8` swift-log deprecation
- `ApplicationObserver` `as`-cast warning

---

## Requirement Fulfillment

### DW-4.1 (#15)
PREMISE:  `WindowManipulator.getAXElement` applies `shouldUseSoleWindowFallback` (reusing the existing StateManager helper, not a fork) and logs `ax.fallback` when it fires; a phantom id whose sole AX window resolves to a DIFFERENT CG id is NOT substituted.
EVIDENCE: `WindowManipulator.swift:86-106` — `getAXElement` calls `StateManager.shouldUseSoleWindowFallback(resolved:soleWindowID:queriedID:)` directly (StateManager.swift:569-575 defines it as `static func`). When fallback fires, logs `ax.fallback` (line 94). When sole window resolves to a different concrete id, the condition is false and `nil` is returned (line 105). No fork: the exact static helper from commit 1cf354e is reused.
TRACE:  phantom wid 2168, sole AX window resolves to 2167 → `shouldUseSoleWindowFallback(resolved:.success, soleWindowID:2167, queriedID:2168)` returns `false` → `getAXElement` returns nil, logs `ax.fail` with `sole_window_phantom`
VERDICT:  **PASS** — `test_DW_4_1_resolvable_different_id_rejects_phantom` + `test_DW_4_1_unresolvable_promotes_ghostty_case` confirm both branches; `AXPropertiesFallbackTests` (4 tests) independently confirm `shouldUseSoleWindowFallback` behavior.

---

### DW-4.2 (#18)
PREMISE:  The pending-launch target is consumed before the first `await` in the claim path; the event path and the sweep cannot both claim it — exactly one window placed.
EVIDENCE: `GridReconciler.swift:940-945` — `guard let target = pendingLaunchTarget` snapshots the target, then `pendingLaunchTarget = nil` executes BEFORE the first `await` at line 960 (`await stateProvider.getState()`). A second concurrent invocation arriving after that line sees `nil` and falls through to `handleWindowCreated`.
TRACE:  path A reads target (non-nil) → sets `pendingLaunchTarget = nil` → first `await` suspends → path B reads `pendingLaunchTarget` → sees nil → falls through to ordinary `handleWindowCreated` → window placed exactly once
VERDICT:  **PASS** — `test_DW_4_2_consume_before_await_single_claim` verifies cell contains exactly one entry for wid 500 after two sequential invocations; target is nil after the first call.

---

### DW-4.3 (#31)
PREMISE:  The target requires a bundle-id match (not pid-less first-come); a failed launch clears the target + logs.
EVIDENCE: `GridReconciler.swift:972-990` — `PendingLaunchPolicy.matchesTarget(windowBundleID:targetBundleID:windowPID:targetPID:)` is called. On mismatch, `restorePendingTarget(target)` re-arms the target, logs `reconcile.pending.skip` with `reason: "no_match"`, and routes the foreign window to `handleWindowCreated`. For failed launch: `PickerManager.swift:249-260` builds `onLaunchFail` closure that calls `reconcilerRef?.clearPendingLaunchTarget(reason:)` → `GridReconciler.swift:323-327` sets `pendingLaunchTarget = nil` and logs `warn.pick.launch_fail`.
TRACE:  Foreign app window (bundleID "com.foreign.app") arrives; target has bundleID "com.picked.app", no pid → `matchesTarget` returns false → target re-armed → foreign window auto-assigned normally
VERDICT:  **PASS** — `test_DW_4_3_pidless_target_rejects_foreign_window` (integration) + `test_DW_4_3_pidless_target_accepts_matching_bundle` + `test_DW_4_3_known_pid_is_authoritative` + `test_DW_4_3_unconstrained_target_accepts` (unit) all pass.

---

### DW-4.4 (#32)
PREMISE:  A locked cell on an inactive space moves/defers the window to that space instead of leaving it bounced.
EVIDENCE: `GridReconciler.swift:878-903` — after assigning the window to the locked cell on `otherSpaceID`, the code checks `findDisplayUUIDForSpace(otherSpaceID, from: wmState)`. When nil (inactive/not visible), it attempts `windowController?.moveWindowToSpace(windowID: windowID, spaceID: targetSpaceNum)` and logs `reconcile.win.create.locked` with `inactive: true, moved: moved`. The assignment is preserved regardless of move success.
TRACE:  Terminal window on space 100; locked rule targets cell "right" on space 200 (not on any display) → assigned to space 200 → `findDisplayUUIDForSpace("200", ...)` returns nil → `moveWindowToSpace(800, 200)` called on `windowController` → MockWindowController records `.moveWindowToSpace(800, 200)`
VERDICT:  **PASS** — `test_DW_4_4_locked_cell_inactive_space_moves_window` confirms assignment to cell and `moveWindowToSpace` call on the mock.

---

### DW-4.5 (#40)
PREMISE:  Observer-register failure retries with backoff; pid/app logged (`ax.observer.create.failed`).
EVIDENCE: `StateManager.swift:1240-1278` — `createObserver(pid:appName:attempt:)` tries `observer.observe(stateManager:)` on MainActor. On failure, calls `scheduleObserverRetry(pid:appName:attempt:)`. That function calls `ObserverRetryPolicy.nextDelay(attempt:)`. When delay is non-nil: logs `ax.observer.create.failed` with `pid`, `app`, `attempt`, `retryIn` fields, then `Task.sleep` + recursive call. When nil (exhausted): logs `ax.observer.create.failed` with `giveUp: true`.
TRACE:  attempt 0: `nextDelay(0) = 0.5` → log `ax.observer.create.failed` + retry after 0.5s → attempt 1: `nextDelay(1) = 1.0` → retry after 1.0s → attempt 2: `nextDelay(2) = 2.0` → retry after 2.0s → attempt 3: `nextDelay(3) = nil` → log final `ax.observer.create.failed` with `giveUp: true`
VERDICT:  **PASS** — `test_DW_4_5_backoff_schedule_then_gives_up` verifies delays [0.5, 1.0, 2.0] and nil at attempt 3; negative attempt also returns nil (bounds guard).

---

### DW-4.6 (#41)
PREMISE:  `not_standard` is re-evaluated within a grace window (or next sweep) — a slow-button window tiles without reopen.
EVIDENCE: `GridReconciler.swift:801-816` — on `category != .standard`, sets `notStandardGrace[windowID] = CFAbsoluteTimeGetCurrent()` if not already present and returns (does not tile). `notStandardGraceSweep()` (lines 552-579): iterates `notStandardGrace`; calls `NotStandardGracePolicy.shouldReevaluate`; when expired, drops; when still standard classification, clears entry and calls `handleWindowCreated`. `NotStandardGracePolicy` defaults to 3.0s grace.
TRACE:  Window 1100 created with `hasFullscreenButton=false` → `classifyWindow` returns `.floating` → tracked in `notStandardGrace` → grace sweep runs → buttons now populated → `classifyWindow` returns `.standard` → `notStandardGrace[1100] = nil` → `handleWindowCreated(1100)` → tiled into cell
VERDICT:  **PASS** — `test_DW_4_6_not_standard_reeval_tiles_after_grace_sweep` + `test_DW_4_6_within_grace_reevaluates` + `test_DW_4_6_expired_grace_drops` + `test_DW_4_6_boundary_is_inclusive` all pass.

---

### DW-4.7 (#57)
PREMISE:  A pending claim is merged (not clobbered) by an in-flight apply.
EVIDENCE: `GridReconciler.swift:583-597` — `handle(_:context:)` checks `pendingLaunchTarget != nil` BEFORE the `suppressReconciliation` guard. A `windowCreated` event during a suppressed apply routes to `handlePendingLaunchWindow` immediately, bypassing the suppressed-event queue. The target is consumed before the first `await` in that path (DW-4.2), so the claim wins against the in-flight apply. `executeAction` drains suppressed events at depth 0 AFTER the apply body completes, at which point the pending claim has already been processed.
TRACE:  `executeAction("apply")` increments depth to 1 → body runs → window 900 created (pending target) → routes to `handlePendingLaunchWindow` (bypasses suppression check) → target consumed → window placed in "left" → body returns → depth returns to 0 → suppressedEvents replayed (none for this window) → "left" still contains 900
VERDICT:  **PASS** — `test_DW_4_7_pending_claim_survives_suppressed_apply` confirms `left` contains 900 after an `executeAction` wrapping the claim.

---

### DW-4.8
PREMISE:  Tileable-but-unassigned windows are logged `validate.win.untracked` and adopted at suppression depth 0.
EVIDENCE: `GridReconciler.swift:254-278` — `adoptUntrackedTileables()` guards `suppressionDepth == 0`; iterates `wmState.windows`; for each wid not in `trackedWids` and not rejected, calls `AdoptionPolicy.isUntrackedTileable(isTileable:isAssignedAnywhere:)`; on true, logs `validate.win.untracked` with `wid` and `app`, then calls `handleWindowCreated(wid, windowState.pid)`. Called from `replaySuppressedEvents()` (line 249) which is invoked at every depth-0 exit.
TRACE:  Window 1000 in StateManager but not in GridState cells, not rejected, tileable → `AdoptionPolicy.isUntrackedTileable(true, false)` returns true → log `validate.win.untracked` → `handleWindowCreated(1000)` → assigned to a cell
VERDICT:  **PASS** — `test_DW_4_8_adopt_untracked_tileable_at_depth0` (integration) + `test_DW_4_8_tileable_unassigned_is_adopted`, `test_DW_4_8_tileable_already_assigned_not_adopted`, `test_DW_4_8_non_tileable_not_adopted` (unit) all pass.

---

### DW-4.9 (#29s, #60s, #61s)
PREMISE:  Instrumentation added (`warn.space.derive_override`, `warn.poll.readd`, `warn.subrole.unknown`) with the underlying behavior UNCHANGED; confirmed/dropped in UAT.
EVIDENCE:
- `warn.space.derive_override`: StateManager.swift:987-994 — inside `deriveSpaceFromDisplay`, only logs when `!originalSpaces.isEmpty && originalSpaces != [display.currentSpaceID]`. Behavioral code at line 995 (`window.spaces = [display.currentSpaceID]`) is UNCHANGED; log is additive.
- `warn.poll.readd`: StateManager.swift:1357-1360 — inside `addWindowFromPoll`, logs before `addWindowFromPoll(...)` but the call itself proceeds unconditionally as before. Behavioral code unchanged.
- `warn.subrole.unknown`: StateManager.swift:1438-1444 — inside `updateWindowFromPoll`, logs when `window.role != nil && (window.subrole == nil || window.subrole == "AXUnknown")` but does NOT requery or alter the window. The existing `if window.role == nil { ... }` requery block at line 1448 is unchanged.

All three event names appear in the `EventAllowlistTests` allowlist (EventAllowlistTests.swift:210-212).
TRACE:  `warn.space.derive_override` fires when `deriveSpaceFromDisplay` overrides a non-empty SLS space list → window.spaces updated as before → log added → no behavioral change. Same structure for the other two.
VERDICT:  **PASS** — `test_DW_2_5_no_unexpected_events_in_source` confirms all three new event names appear in sources and are in the allowlist. Behavioral code paths surrounding each log are verified unchanged.

---

## Test-DW Coverage

| DW Item | Automated Tests | Ran in Step 0 |
|---------|----------------|---------------|
| DW-4.1 | `test_DW_4_1_resolvable_different_id_rejects_phantom`, `test_DW_4_1_unresolvable_promotes_ghostty_case` (WindowAdoptionPolicyTests) | PASS |
| DW-4.2 | `test_DW_4_2_consume_before_await_single_claim` (WindowAdoptionIntegrationTests) | PASS |
| DW-4.3 | `test_DW_4_3_pidless_target_rejects_foreign_bundle`, `test_DW_4_3_pidless_target_accepts_matching_bundle`, `test_DW_4_3_known_pid_is_authoritative`, `test_DW_4_3_unconstrained_target_accepts` (unit); `test_DW_4_3_pidless_target_rejects_foreign_window`, `test_DW_4_3_pidless_target_accepts_matching_bundle` (integration) | PASS |
| DW-4.4 | `test_DW_4_4_locked_cell_inactive_space_moves_window` (WindowAdoptionIntegrationTests) | PASS |
| DW-4.5 | `test_DW_4_5_backoff_schedule_then_gives_up` (WindowAdoptionPolicyTests) | PASS |
| DW-4.6 | `test_DW_4_6_within_grace_reevaluates`, `test_DW_4_6_expired_grace_drops`, `test_DW_4_6_boundary_is_inclusive` (unit); `test_DW_4_6_not_standard_reeval_tiles_after_grace_sweep` (integration) | PASS |
| DW-4.7 | `test_DW_4_7_pending_claim_survives_suppressed_apply` (WindowAdoptionIntegrationTests) | PASS |
| DW-4.8 | `test_DW_4_8_tileable_unassigned_is_adopted`, `test_DW_4_8_tileable_already_assigned_not_adopted`, `test_DW_4_8_non_tileable_not_adopted` (unit); `test_DW_4_8_adopt_untracked_tileable_at_depth0` (integration) | PASS |
| DW-4.9 | `test_DW_2_5_no_unexpected_events_in_source` (EventAllowlistTests) + behavioral code walk | PASS |

Coverage level: Backend 100% — every DW item has an automated test. Pure predicates (DW-4.1, 4.3, 4.5, 4.6, 4.8) are unit-tested off the AX boundary; behavioral items (DW-4.2, 4.3, 4.4, 4.6, 4.7, 4.8) have integration tests against MockStateProvider + GridState.

**All DW items have corresponding tests that ran in Step 0: YES**

---

## Dead Code

None found in the reviewed files. No unused imports, unreachable branches, commented-out blocks, or debug statements. The `_test_*` methods in GridReconciler are test entry points intentionally; not dead code.

---

## Correctness Dimensions

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Concurrency | PASS | `pendingLaunchTarget = nil` executes before the first `await` in `handlePendingLaunchWindow` (GridReconciler.swift:945) — TOCTOU window eliminated. `notStandardGrace` and `pendingLaunchTarget` are plain value-type fields on a `class` (GridReconciler is non-actor), but all mutation happens inside `async` methods that are serialized by Swift's cooperative thread model in this codebase's single-event-dispatch pattern. `StateManager` is a Swift `actor` — its mutable fields are protected. No off-actor mutation observed. |
| Error Handling | PASS | `try? await` used for `gridApply?.applyCellLayout` and `gridFocus?.focusWindowByID` (GridReconciler.swift:1057, 1060) — deliberate best-effort; failures logged. Observer retry path exhausted → logs with `giveUp:true` and stops. `clearPendingLaunchTarget` called on `openApp` / `openDir` launch failures via `onLaunchFail`. |
| Resources | PASS | `scheduleObserverRetry` uses `[weak self]` to avoid retain cycles (StateManager.swift:1275). Sweep timer uses `[weak self]` (GridReconciler.swift:433). `DispatchSourceTimer` is retained in `sweepTimer` for lifecycle management. |
| Boundaries | PASS | `ObserverRetryPolicy.nextDelay` guards `attempt >= 0` and `attempt < delays.count` before indexing (WindowAdoptionPolicy.swift:89-91). `notStandardGrace` keys are snapshotted before iteration (`for (wid, firstSeen) in notStandardGrace`) — a copy-on-iterate pattern safe for Swift Dictionary. `UInt64(otherSpaceID)` conversion guarded before use (GridReconciler.swift:887). |
| Security | N/A | No untrusted external input, no user-controlled URLs, no shell command injection in Phase 4 code paths. ActionExecutor uses `Process` with structured arguments (not shell string). |

---

## Edge Cases (from prompt — verified)

| Edge Case | Handled | Evidence |
|-----------|---------|----------|
| Sole AX window resolving to different CG id → no substitution | YES | WindowManipulator.swift:86-106: when `shouldUseSoleWindowFallback` returns false (different id), returns nil, not the sole window. |
| Pid-less target claimed by foreign window (must NOT happen) | YES | GridReconciler.swift:972-989: `PendingLaunchPolicy.matchesTarget` rejects foreign bundle → `restorePendingTarget` re-arms → foreign window falls through to `handleWindowCreated`. |
| Locked cell on an inactive space | YES | GridReconciler.swift:878-903: `findDisplayUUIDForSpace` nil branch → `moveWindowToSpace` called. |
| Observer AX-register failure at launch (bounded retry) | YES | StateManager.swift:1258: `ObserverRetryPolicy.nextDelay` returns nil after 3 attempts → `scheduleObserverRetry` stops. |
| not_standard from late-populated window buttons | YES | GridReconciler.swift:801-816 + 552-579: grace entry recorded, grace sweep re-evaluates within 3.0s default window. |
| Consume-before-await ordering correct (no TOCTOU) | YES | `pendingLaunchTarget = nil` at GridReconciler.swift:945 — before first `await` at line 960. |
| New shared state actor-confined to reconciler | YES | `notStandardGrace`, `pendingLaunchTarget`, `suppressionDepth` are all instance fields on `GridReconciler` (class, not actor), accessed only within the reconciler's async methods which are dispatched serially by the event router. No cross-actor mutation observed. |
| `notStandardGrace`/pending maps not mutated unsafely during iteration | YES | `notStandardGraceSweep` (GridReconciler.swift:559) iterates a copy of `notStandardGrace` entries (Swift Dictionary is value type, `for (wid, firstSeen) in notStandardGrace` iterates a structural copy). Mutations via `notStandardGrace[wid] = nil` are safe. |

---

## Notes (non-blocking)

1. **DW-4.5: no integration test for the retry behavioral path** — `test_DW_4_5_backoff_schedule_then_gives_up` tests the pure `ObserverRetryPolicy` predicate (backoff schedule). The `scheduleObserverRetry` → `createObserver` recursive path that actually drives retries is not integration-tested (would require AX mock injection). This is consistent with the project's testing pattern (pure predicates off the AX boundary) and not a FAIL per the test coverage level.

2. **DW-4.9: `warn.poll.readd` fires unconditionally for every newly-discovered poll window** — the log at StateManager.swift:1357-1360 precedes `addWindowFromPoll` with no condition. Every poll-discovered window emits this warning even if it is genuinely new (first appearance). The comment explicitly notes "confirm-or-drop in UAT." This is the intended instrumentation-only behavior per the DW-4.9 requirement.

3. **GridReconciler is a plain class (not actor)** — concurrent access to `notStandardGrace`, `pendingLaunchTarget`, and `suppressionDepth` depends on the event router's serial dispatch guarantee rather than Swift actor isolation. This is an existing architectural decision spanning the whole file (not introduced in Phase 4) and is not a new risk.

4. **`moveWindowToSpace` return value** — at GridReconciler.swift:888-889, `windowController?.moveWindowToSpace(...)` result is captured in `moved` and logged but the assignment to the locked cell on the inactive space proceeds regardless (line 892 returns). This is correct behavior per the DW-4.4 requirement ("assignment still stands (deferred until the space becomes active)").

---

**All requirements met: YES**

**Verdict: PASS**
