# Discovery + Design: Phase 4 - Window creation, classification & adoption

## Files Found
- `grid-server/Sources/GridServer/WindowManipulator.swift` — `getAXElement` (57-85) has the unguarded sole-window fallback (#15).
- `grid-server/Sources/GridServer/StateManager.swift` — owns `shouldUseSoleWindowFallback` pure helper (569-575); `deriveSpaceFromDisplay` (973+, #29s instrumentation); poll re-add (#60s); subrole requery guard (#61s); `createObserver` (1220-1235, #40 retry).
- `grid-server/Sources/GridServer/Grid/GridReconciler.swift` — `handle` (497+), suppressed-event replay (219-236, #12/DW-4.8 adoption hook), `handleWindowCreated` (662-806, locked #32 / not_standard #41), `handlePendingLaunchWindow` (808-924, #18/#31/#57).
- `grid-server/Sources/GridServer/Picker/ActionExecutor.swift` — `.openApp` (31-45) has no else when `urlForApplication` fails (#31 clear-on-fail).
- `grid-server/Sources/GridServer/Picker/PickerManager.swift` — `onLaunch`/`onPID` wiring (218-248).
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` — `setPendingLaunchTarget` call site (654-663).
- `grid-server/Sources/GridServer/Grid/GridAssignment.swift` — `classifyWindow`, `isTileable`, `getLockedCell`, `lockedCellIDs` free functions.

## Current State
- The `shouldUseSoleWindowFallback(resolved:soleWindowID:queriedID:)` pure helper exists in `StateManager` (commit 1cf354e) and is unit-tested in `AXPropertiesFallbackTests`. `WindowManipulator.getAXElement` still does a naked `if windows.count == 1 { return windows[0] }` with no resolution check and no log.
- Pending-launch consume happens AFTER multiple awaits (read at :809, consume at :910). PID guard is skipped when `target.pid == nil` → any foreign window can claim a pid-less target. ActionExecutor `.openApp` has no failure branch to clear an armed target.
- Suppressed-event replay (depth-0) already replays queued create/destroy but does NOT scan for tileable-but-unassigned windows (DW-4.8 adoption gap).
- `handleWindowCreated` locked-cell branch (749-787): when the locked cell exists only on another space, it assigns in GridState but only applies layout if a display currently shows that space — otherwise the window is never moved (#32).
- not_standard bail (715-723) is terminal: the window is NOT rejected, so neither `rejectedWindowSweep` nor the move-unreject path re-evaluates it (#41).
- `createObserver` (1230-1234) discards `observe()==false` with no retry (#40).
- Reconciler is exercised in tests via `_test_setup`, `_test_handle`, `_test_triggerWindowCreated`, `_test_pendingLaunchTarget`, `_test_appRuleOverride`. `MockWindowController`/`MockStateProvider` are the fakeable Ports.

## Gaps
- DW-4.1: WindowManipulator must reuse the StateManager helper (do not fork) + log `ax.fallback`.
- DW-4.2/4.3/4.7: pending consume must move before first await; bundle-id match; clear-on-fail; in-flight merge.
- DW-4.4: locked cell on inactive space must move-to-space (or defer) instead of bouncing.
- DW-4.5: observer-register retry with backoff.
- DW-4.6: not_standard grace re-eval.
- DW-4.8: depth-0 adoption of unassigned tileables.
- DW-4.9: instrumentation only for #29s/#60s/#61s.

## Code Standards
- Swift actors / pure static helpers for testable logic; unit-test pure predicates off the AX/SkyLight boundary (sole-window guard, bundle-id match, not_standard grace, untracked-adoption decision).
- `jlog` codes `warn.<scope>.<reason>` / `err.<scope>` / `<scope>.<event>`.
- Comments on their own line.
- `[weak self]` + `guard let self else { return }` in escaping closures.
- Reuse the exact `shouldUseSoleWindowFallback` helper (commit 1cf354e) — do not fork.

## Test Infrastructure
- XCTest, `@testable import GridServer`. Pure-predicate suites (`SpaceMigrationPolicyTests`, `FocusOwnershipPolicyTests`, `AXPropertiesFallbackTests`) and integration suites against `MockWindowController`/`MockStateProvider` + real `GridState`/`GridReconciler` (`FocusOwnershipIntegrationTests`). 193 tests green at baseline.

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|---------------|--------|------------|
| DW-4.1 | #15 getAXElement applies sole-window guard + logs ax.fallback; phantom no longer substitutes | COVERED | `test_DW_4_1_*` reuse of `shouldUseSoleWindowFallback` truth table via WindowManipulator path; integration: phantom-different-id returns nil, sole-unresolvable returns element |
| DW-4.2 | #18 pending consumed before first await; event+sweep cannot both claim | COVERED | `test_DW_4_2_consume_before_await_*`: two interleaved `handlePendingLaunchWindow` calls → exactly one claim; pure `PendingLaunchPolicy.claim` consume-once |
| DW-4.3 | #31 bundle-id match (not pid-less first-come); failed launch clears + logs | COVERED | `test_DW_4_3_bundleid_match_*` pure predicate (foreign bundle rejected, match accepted); `test_DW_4_3_launch_fail_clears` ActionExecutor failure branch |
| DW-4.4 | #32 locked cell on inactive space moves/defers | COVERED | `test_DW_4_4_locked_cell_inactive_space_moves`: MockWindowController records `moveWindowToSpace` |
| DW-4.5 | #40 observer-register failure retries with backoff; pid/app logged | COVERED | `test_DW_4_5_observer_retry_schedule` pure backoff-schedule predicate |
| DW-4.6 | #41 not_standard re-evaluated within grace window | COVERED | `test_DW_4_6_not_standard_grace_*` pure grace predicate; integration: grace re-eval tiles a now-standard window |
| DW-4.7 | #57 pending claim merged (not clobbered) by in-flight apply | COVERED | `test_DW_4_7_merge_pending_claim`: claim queued while suppressed, applied at depth 0 (no clobber) |
| DW-4.8 | #12 tileable-but-unassigned logged validate.win.untracked + adopted at depth 0 | COVERED | `test_DW_4_8_adopt_untracked_at_depth0`: unassigned tileable adopted on replay; pure `AdoptionPolicy.isUntrackedTileable` |
| DW-4.9 | #29s/#60s/#61s instrumentation added; confirmed/dropped in UAT | COVERED | `test_DW_4_9_*` assert log-signature predicates exist (derive-override, poll tombstone, subrole-requery) — instrumentation only |

**All items COVERED:** YES (DW-ID count = 9 = dispatch prompt count)

## Design Decisions

### Pure-predicate extraction (code-standards: test off the AX/SkyLight boundary)
New module `Grid/WindowAdoptionPolicy.swift` holds the pure decisions:
- `PendingLaunchPolicy.matchesTarget(windowBundleID:targetBundleID:windowPID:targetPID:)` — bundle-id-first match (#31/#18): a pid-less target requires a bundle-id match; a known pid requires pid match. Replaces the "pid-nil → skip pid check, first tileable wins" hole.
- `AdoptionPolicy.isUntrackedTileable(isTileable:isAssignedAnywhere:)` — DW-4.8 decision.
- `NotStandardGracePolicy` — tracks `(wid → firstSeen)`; `shouldReevaluate(now:firstSeen:graceWindow:)` decides whether a not_standard window is still within grace (re-eval) or expired. Pure time math.
- `ObserverRetryPolicy.nextDelay(attempt:)` → bounded backoff `[0.5, 1.0, 2.0]`, nil after 3 attempts (#40).

These keep the AX/timer/await orchestration thin and the branch logic unit-tested.

### #15 — reuse, do not fork
`WindowManipulator.getAXElement` calls `StateManager.shouldUseSoleWindowFallback` (the existing static helper) before returning `windows[0]`, and logs `ax.fallback{pid,wid,resolved,op}` when it fires; returns nil (no substitution) when the guard rejects. `op:"getAXElement"`.

### #18/#57 — consume before await + merge
`PendingLaunchTarget` gains a `bundleID: String?`. `handlePendingLaunchWindow` snapshots and clears `pendingLaunchTarget` to a local BEFORE the first await (consume-once), restoring it on skip paths where the window is rejected (so a later real window can still claim). For #57, the depth-0 path already runs the claim outside suppression for the replay/sweep entry; the claim sets GridState via `prependWindow` which an in-flight apply must not clobber — covered by queueing the claim until depth 0 (existing replay path) rather than racing a live apply. Test asserts the claim survives a suppressed apply window.

### #31 — bundle-id + clear-on-fail
`setPendingLaunchTarget` carries the picked app's bundleID (from `PickerAction.openApp(bundleID:)`). `handlePendingLaunchWindow` uses `PendingLaunchPolicy.matchesTarget`. ActionExecutor `.openApp` gets an else branch on `urlForApplication==nil` and an error branch in the completion that both call a new `onLaunchFail` closure → `reconciler.clearPendingLaunchTarget(reason:)` + `warn.pick.launch_fail` log.

### #32 — move-to-space on inactive locked cell
In the cross-space locked branch, when the target space is not visible on any display (`findDisplayUUIDForSpace == nil`), call `windowController.moveWindowToSpace` before assigning; log `reconcile.win.create.locked{moved:true}`. If move fails, log and fall back to the original behavior (defer) rather than silently bouncing.

### #40 — observer retry
`createObserver` schedules bounded retries via `ObserverRetryPolicy.nextDelay`; logs `ax.observer.create.failed{pid,app,attempt}` on each failed attempt.

### #41 — not_standard grace
Reconciler keeps a `notStandardGrace: [UInt32: CFAbsoluteTime]` map. On the not_standard bail, record firstSeen and log. `rejectedWindowSweep` (or a new grace sweep within the existing sweep tick) re-runs `classifyWindow`; if now `.standard`, route to `handleWindowCreated`; if grace expired, drop from the map. Pure decision in `NotStandardGracePolicy`.

### #29s/#60s/#61s — instrumentation ONLY (no behavioral change)
- #29s: `deriveSpaceFromDisplay` logs `warn.space.derive_override{wid,from,to}` when it overrides a NON-empty SLS `originalSpaces` list with a different display-current space.
- #60s: poll re-add path logs a tombstone trace when a wid in the snapshot is absent from state (already destroyed candidate) — `warn.poll.readd{wid}` (no tombstone-skip behavior added).
- #61s: subrole-requery — log `warn.subrole.unknown{wid,subrole}` where the role!=nil guard currently skips an AXUnknown subrole (no requery behavior added).
These are confirm-or-drop in UAT per the suspected-finding rule. No blind behavioral fix.

## Prerequisites
- [x] P1 primitives present (`SuppressedEventQueue`, generation counter, serial executor) — replay path exists.
- [x] P2 correct space identity present (`resolveWindowSpace`, `findDisplayUUIDForSpace`).
- [x] `shouldUseSoleWindowFallback` helper exists (commit 1cf354e).
- [x] `MockWindowController`/`MockStateProvider` fakeable.
- [x] 193 tests green baseline.

## Recommendation
BUILD — all 9 DW items are reachable with the existing primitives and fakes. #16 explicitly excluded (Phase 5). #29s/#60s/#61s instrumented only.
