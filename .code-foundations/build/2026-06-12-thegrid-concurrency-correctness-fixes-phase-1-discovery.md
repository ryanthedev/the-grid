# Discovery + Design: Phase 1 - Serialization foundation

## Files Found

Ingress / dispatch / primitives (all exist):
- `grid-server/Sources/GridServer/MessageHandler.swift` — `handle()` spawns one `Task{}` per request (line 52); `registerGridHandlers.dispatchAndRespond` calls `await router.dispatch(...)` inside its own `Task{}` (line 1389-1391). Two other call sites (1800, 1880) dispatch record/sub-commands.
- `grid-server/Sources/GridServer/BFD/BFDManager.swift` — `handleInternalCommand` spawns `Task { await router.dispatch(command) }` (line 137-138). One `Task` per hotkey/auto-repeat.
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` — `dispatch(_ command:)` (line 158): plain async method on a plain `class`, no serialization. `handleNudge` (774-871) holds nudge session state (`nudgeKeyHandler`, `nudgeActionToken`) as plain stored properties; `@nudge exit` re-dispatches through `self.dispatch` from the tap callback (818).
- `grid-server/Sources/GridServer/Grid/GridReconciler.swift` — plain `class` (line 21). `suppressionDepth` (57), `fencedWindows: [UInt32: CFAbsoluteTime]` (63), `acquireFence`/`releaseFence` (163-186, NOT refcounted — overwrite/unconditional-delete), `executeAction`/`beginAction`/`endAction` (91-158, ActionToken is label+time only — no unique id), `handle()` event-drop during suppression (441-444, no queue/replay).
- `grid-server/Sources/GridServer/Grid/GridNudge.swift` — `move`/`resize(spaceID:direction:)` read-modify-write cached frame; no coalescing (#50).
- `grid-server/Sources/GridServer/BFD/NudgeKeyHandler.swift` — `onNudge: ((NudgeAction)->Void)?`, `start()->Bool`, `stop()`. `NudgeAction = .move(dir)|.resize(dir)|.exit`.
- `grid-server/Sources/GridServer/main.swift:211-230` — wiring: `GridCommandRouter` constructed, passed to `MessageHandler.registerGridHandlers` and `BFDManager.setCommandRouter`.

Test infra:
- `grid-server/Tests/GridServerTests/` — XCTest, `@testable import GridServer`. Established pattern (`SuppressionLiftTests`, `FocusLoopDetectorTests`): extract a pure `static` helper / value-type struct and unit-test it off the AX/SkyLight boundary.

## Current State
- Command ingress is fully unserialized: every request/keypress runs `router.dispatch` in its own unstructured `Task` on a concurrent queue. N commands execute concurrently and finish in arbitrary order (#11/#3/#5).
- `GridReconciler` is a plain class with non-atomic `suppressionDepth`, a non-refcounted fence map, and a suppression branch that silently drops `windowCreated`/`windowDestroyed`/etc. with no replay (#14/#12).
- Nudge session state lives on the plain router class; the `nudgeKeyHandler != nil` idempotency check is split from the store by an `await`, so a concurrent double `@nudge enter` installs two CGEventTaps and double-suppresses; `endAction` consumes a token that has no identity (#4). Held nudge keys spawn unordered RMW `Task`s and lose steps (#50).
- No generation counter exists.
- Baseline: `swift build` green (after `make generate-version` — `Version.swift` is gitignored/generated), `swift test` = 112 tests, 0 failures.

## Gaps (plan assumption vs reality)

| # | Gap | Resolution |
|---|-----|-----------|
| 1 | Plan File hints cite `GridReconciler.swift:21,57-66,91-129,441-444` etc.; audit JSON notes "file paths slightly off — files live under `Grid/`". | Confirmed actual paths under `Grid/`; used those. |
| 2 | `Version.swift` absent → baseline build fails out of the box. | Generated via `make generate-version`; it is a build artifact, not Phase-1 scope. |
| 3 | `router.dispatch` has 5 call sites, not 2 (MessageHandler ×4 incl. record sub-dispatch + nudge-exit re-dispatch). | Route ALL command ingress through the executor seam; internal `@nudge exit` re-dispatch must NOT re-enter the queue (it runs inside an already-dequeued body) → it calls a non-serialized internal path, or is left as a direct router call. Designed below. |
| 4 | Audit #3 fix-direction offers "actorize reconciler OR confine to serial executor". | Approach B (user decision) = confine. Reconciler stays a class; serialization comes from the executor. Event-stream-vs-command races are explicitly OUT (P2/P3). |

## Code Standards
From `docs/code-standards.md` (read; present in this worktree):
- §8 Swift actors for shared mutable state — never DispatchQueue+locks for new state. → CommandExecutor is an actor-confined serial queue; nudge session state moves behind the serial seam.
- §1 never `Task{}` back into the owning actor. → the serial consumer must not re-submit to itself; `@nudge exit` re-dispatch handled without re-queuing.
- `jlog` event codes dot-separated lowercase; `warn.<scope>.<reason>` / `err.<scope>`. → new seams: `cmd.submit`, `cmd.exec{inflight}`, `fence.acquire`/`fence.release{wid,depth}`, `reconcile.suppressed.queue`/`reconcile.suppressed.replay{event,wid,gen}`.
- Comments on their own line above the code, never trailing.
- `[weak self]` + `guard let self else { return }` in escaping closures.
- Tests: extract pure decision predicates as `static` helpers; name `test_DW_1_X_...`. Ports fakeable for `[I]`.

## Test Infrastructure
XCTest, `@testable import GridServer`. Pure-helper-first. `JSONLogger.shared` writes JSONL to `$XDG_STATE_HOME` — `[M]` log-signature items (inflight≤1 under live held-key burst, tap balance) are UAT-asserted on a deployed build, not in the unit suite. The unit/integration layer proves the *mechanism* (ordering, refcount, consume-once, queue/replay, monotonic generation) via pure helpers and a fake router.

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|---------------|--------|------------|
| DW-1.1 (#11,#3) | serial CommandExecutor exists; MessageHandler+BFD submit through it; 4 overlapping submits complete in submission order; `cmd.exec{inflight}` never >1 under held-key burst | COVERED | `[I]` `test_DW_1_1_overlapping_submits_complete_in_submission_order` (fake router records dispatch order; 4 concurrent submits → order preserved). `[I]` `test_DW_1_1_inflight_never_exceeds_one` (fake router records max concurrent bodies via an actor counter → asserts max==1). `[M]` live `cmd.exec{inflight}` under held key = UAT. |
| DW-1.2 (#5) | two concurrent `layout cycle` submits no longer interleave — one consistent layout id + cell map | COVERED | `[I]` `test_DW_1_2_concurrent_layout_cycle_serialized` (fake router whose `layout cycle` body does read-sleep-write on shared layout id; two concurrent submits → final state consistent, no torn read; without the executor the same fake interleaves). Asserts serialization at the seam. |
| DW-1.3 (#14) | fence refcounted — acquire×2/release×1 stays fenced; `fence.release{wid,depth}` logged; release of an unheld wid is a no-op | COVERED | `[U][D]` `test_DW_1_3_fence_refcount_acquire_twice_release_once_still_fenced`; `test_DW_1_3_release_to_zero_removes_entry`; `test_DW_1_3_release_unheld_is_noop`; `test_DW_1_3_expiry_path_clears`. Pure `RefcountedFence` struct/helper. |
| DW-1.4 (#4) | concurrent double `@nudge enter` installs ≤1 tap, token consumed once; after exit `suppressionDepth==0`, zero live taps | COVERED | `[U]` `test_DW_1_4_action_token_consumed_exactly_once` (unique-id token; second consume rejected). `[I]` `test_DW_1_4_double_enter_one_session` (serial NudgeSession: second enter is idempotent no-op behind the serial seam; exit drains to depth 0). Tap install is behind the same consume-once guard. |
| DW-1.5 (#50) | held nudge key coalesces repeats; applies steps in order (none lost/back-stepped) | COVERED | `[U][D]` `test_DW_1_5_coalesce_same_direction_repeats` (NudgeStepQueue carries frame forward / coalesces same-dir; N steps apply in order); `test_DW_1_5_out_of_order_step_rejected`. |
| DW-1.6 (#12) | create/destroy during suppression queued + replayed at depth 0; created-while-suppressed window becomes tracked; `reconcile.suppressed.queue`+`.replay{event,wid,gen}` logged | COVERED | `[U]` `test_DW_1_6_events_queued_while_suppressed_replayed_in_order` (SuppressedEventQueue: enqueue while depth>0, drain FIFO at depth 0). `test_DW_1_6_replay_of_gone_wid_is_idempotent`. `[U]` replay carries generation stamp. |
| DW-1.7 | generation counter increments per action; readable by handlers/sweep; monotonic | COVERED | `[U]` `test_DW_1_7_generation_increments_per_action`; `test_DW_1_7_generation_monotonic_under_interleave`. Pure `GenerationCounter`. |

**All items COVERED:** YES (7/7 DW-IDs; count matches dispatch prompt).

## Design Decisions

### Pattern selection (gof-design-patterns)
- **CommandExecutor** = producer/consumer serial queue (GoF Command encapsulated as a string + continuation; one consumer task). NOT a bare actor with `await router.dispatch` inside `submit` — actor reentrancy would release isolation at the inner `await` and let a second `submit` interleave, defeating serialization. Instead: `submit` enqueues `(command, CheckedContinuation)` onto an `AsyncStream`; a single long-lived consumer task pulls ONE item, runs `await router.dispatch` to completion, resumes the continuation, then pulls the next. This guarantees `inflight ≤ 1` and FIFO. `inflight` is an internal counter logged on each `cmd.exec`.
- **RefcountedFence** (replaces the overwrite map) — per-wid `count: Int` + shared `expiresAt`; `acquire` increments, `release` decrements and removes only at 0; `release` of an unheld wid logs/returns no-op. Pure value-type so it is unit-testable; the reconciler embeds it.
- **GenerationCounter** — `UInt64` bumped on each `beginAction`/`executeAction` entry; exposed via a reader the focus sweep + handlers can snapshot pre-`await` and re-check post-`await`. P1 only ships + tests the primitive (monotonic increment); consumers are P2/P3.
- **SuppressedEventQueue** — ordered buffer of `(event, wid, gen)`; `handle()` enqueues `windowCreated`/`windowDestroyed` when `suppressionDepth>0` instead of dropping; drained FIFO when depth returns to 0, each replay logged `reconcile.suppressed.replay{event,wid,gen}`. Replay of an already-gone wid is idempotent (handlers are already idempotent via `assignWindow`/destroy-of-untracked).
- **NudgeSession consume-once** — `ActionToken` gets a unique `id: UInt64`; `endAction` consumes by id exactly once (second consume → `warn.action.end.underflow`/reject, does not decrement another session). Nudge enter/exit run as discrete serial submits; the held-key step queue (NudgeStepQueue) coalesces same-direction repeats and carries the frame forward.

### Architecture boundaries (ca-architecture-boundaries)
- CommandExecutor is a new ingress seam (adapter-level) that wraps the router; it does not import AX/SkyLight. The four primitives are pure value types (Entities-level) with no infrastructure imports → directly unit-testable, satisfying the "fakeable Ports" assumption without even needing the Ports.
- SRP: executor owns "run one command at a time"; fence/generation/queue each own one concern; nudge session owns "consume-once + ordered steps". No actor coupling added to the reconciler beyond embedding these value types.

### Defensive programming (cc-defensive-programming)
- The UNIX socket is a trust boundary but command-string parsing already exists in `parse()` (unchanged). New code: `release` of an unheld wid = anticipated runtime condition → log-and-noop (not assertion). Token double-consume = programmer/race bug surfaced as a `warn` + reject (robustness domain: consumer tool — log-and-continue, never crash). `executeAction` throwing must still drain the suppressed queue → the queue drain is in the same `defer`/depth-0 path as border sync (mirrors existing catch branch at 117-128).

### Refactoring discipline (cc-refactoring-guidance)
- Baseline saved (git worktree) and verified green (112 tests) BEFORE changes.
- Primitives land as ADD-ONLY pure types first (each with its own red→green), then the reconciler swaps its fence map / drop-branch to use them, then the executor seam is inserted at ingress LAST. One structural change at a time; full suite re-run after each.
- This is a behavior-changing fix (serialization), not a pure refactor — so it is the "fix" activity; tests are written first (TDD), matching the plan's Backend-100% mandate.

## Prerequisites
- [x] Required files exist (paths under `Grid/`)
- [x] Dependencies available; baseline build+test green after `make generate-version`
- [x] Test framework + pure-helper pattern confirmed

## Assumption Verification
- "Serial executor won't starve under normal hotkey rates" — HOLDS. Only `awaitWakeCompletion()` is long-running and it is already awaited inside `dispatch`; the serial queue simply orders the same bodies that already ran. Fallback (read-only lane) not needed for P1.
- "Ports protocols fakeable for `[I]` tests" — HOLDS, and P1's primitives are pure value types needing no Ports at all; the `[I]` executor tests use a trivial fake router conforming to a minimal protocol (introduced as the executor's dependency seam).

## Recommendation
**BUILD.** All 7 DW items are implementable in one pass via four pure primitives + one ingress seam, with the reconciler staying a class (Approach B). The refactor is bounded: primitives are add-only and unit-tested in isolation; the seam swap at `dispatch` call sites is mechanical (5 sites) and preserves `awaitWakeCompletion` semantics. No UPDATE_PLAN needed.
