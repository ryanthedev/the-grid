# Review: Phase 1 - Concurrency Correctness Fixes

## Executed Results (Step 0)

| Check | Command | Result |
|-------|---------|--------|
| Build | `swift build` | PASS — Build complete (0 errors, 0 warnings) |
| Test suite | `swift test` | PASS — 131 tests, 0 failures |
| Typecheck | (via swift build) | PASS |
| Lint | N/A (no lint tool configured) | N/A |

---

## Requirement Fulfillment

### DW-1.1
PREMISE:  "serial CommandExecutor actor exists; MessageHandler+BFD submit through it; 4 overlapping submits complete in submission order; `cmd.exec{inflight}` never exceeds 1 under a held-key burst."
EVIDENCE: CommandExecutor.swift:28–82; MessageHandler.swift:1385–1394; BFDManager.swift:146–148
TRACE:    4 tasks each call `executor.submit(cmd)` concurrently → AsyncStream.Continuation.yield enqueues each item FIFO → single consumer Task pops one item, sets `inflight += 1`, runs `runner.run(item.command)` to completion, sets `inflight -= 1`, resumes continuation → next item dequeued → ordering and inflight≤1 maintained end-to-end.
VERDICT:  PASS (tests `test_DW_1_1_overlapping_submits_complete_in_submission_order` and `test_DW_1_1_inflight_never_exceeds_one` both pass)

### DW-1.2
PREMISE:  "two concurrent `layout cycle` submits no longer interleave — rapid double-apply yields one consistent layout id + cell map (no cellNotFoundInLayout)."
EVIDENCE: CommandExecutor.swift:66–79 (serial consumer); CommandExecutorTests.swift:90–104
TRACE:    Two concurrent `executor.submit("layout cycle")` calls → both enqueue on stream → consumer runs first body to completion (read layoutID=0, yield, sleep, check no torn read, write layoutID=1) → then runs second body (read layoutID=1, yield, sleep, check no torn read, write layoutID=2) → `tornReadDetected` stays false, `finalID == 2`.
VERDICT:  PASS (test `test_DW_1_2_concurrent_layout_cycle_serialized` passes)

### DW-1.3
PREMISE:  "fence refcounted — acquire×2/release×1 stays fenced; `fence.release{wid,depth}` logged; release of an unheld wid is a no-op."
EVIDENCE: SerializationPrimitives.swift:27–96; GridReconciler.swift:247–255 (fence.release log with wid+depth)
TRACE:    `fence.acquire(100)` × 2 → `entries[100] = Entry(count:2, …)` → `fence.release(100)` → count becomes 1, entry retained → `isFenced(100)` returns true. Second release → count becomes 0, entry removed → `isFenced` returns false. `fence.release(999)` on unheld wid → guard returns 0, no mutation.
VERDICT:  PASS (tests `test_DW_1_3_fence_refcount_*`, `test_DW_1_3_release_unheld_is_noop`, `test_DW_1_3_reconciler_fence_is_refcounted` all pass)

### DW-1.4
PREMISE:  "concurrent double `@nudge enter` installs ≤1 CGEventTap, token consumed exactly once; after exit suppressionDepth==0 and zero live taps."
EVIDENCE: GridCommandRouter.swift:797–799 (idempotent nil check, serialized), GridReconciler.swift:164–169 (beginAction mints token), GridReconciler.swift:177–200 (endAction consumes once via actionTokens.consume)
TRACE:    Two concurrent `@nudge enter` → executor serializes them → first enter sees `nudgeKeyHandler == nil`, mints token, installs tap, returns .ok → second enter sees `nudgeKeyHandler != nil`, returns early with no new token or tap. On exit: `actionTokens.consume(id: token.id)` removes id from `active` set (returns true) → `suppressionDepth -= 1` → depth 0. A racing second endAction for the same token finds `active` set no longer contains id → returns false (no-op), depth unchanged.
VERDICT:  PASS (tests `test_DW_1_4_action_token_consumed_exactly_once`, `test_DW_1_4_distinct_tokens_independent`, `test_DW_1_4_double_endAction_same_token_does_not_underflow_other_session` all pass)

### DW-1.5
PREMISE:  "held nudge key coalesces repeats and applies steps in order (none lost or back-stepped)."
EVIDENCE: GridCommandRouter.swift:815–836 (serial AsyncStream step pump); SerializationPrimitives.swift:200–218 (NudgeStepQueue.advance carries frame forward)
TRACE:    Each key repeat → `nudgeStepFeed?.yield(action)` enqueues to unbounded AsyncStream → single consumer Task processes one action at a time (move/resize completes AX write before next dequeue) → NudgeStepQueue.advance(current: x, direction: .right) = x + step each call → 3 rights from x=100 yields 120, 140, 160 (no backstep, none lost).
VERDICT:  PASS (tests `test_DW_1_5_coalesce_same_direction_repeats` and `test_DW_1_5_reverse_direction_steps_back_once` pass)

### DW-1.6
PREMISE:  "create/destroy during suppression queued + replayed at depth 0; a window created-while-suppressed becomes tracked; `reconcile.suppressed.queue`+`.replay{event,wid,gen}` logged."
EVIDENCE: GridReconciler.swift:487–504 (queue on suppress), GridReconciler.swift:206–222 (replay with logging), GridReconciler.swift:127–134 and 148–153 (drain at depth 0 in both normal and error paths)
TRACE:    `suppressionDepth > 0` → incoming `.windowCreated(wid:700)` → `suppressedEvents.enqueue(.windowCreated(wid:700), generation: generation)` + `jlog("reconcile.suppressed.queue", …)` → depth returns to 0 → `replaySuppressedEvents()` drains FIFO → `handleWindowCreated(700, nil)` called with `jlog("reconcile.suppressed.replay", …)` → window assigned to cell.
VERDICT:  PASS (tests `test_DW_1_6_events_queued_while_suppressed_replayed_in_order`, `test_DW_1_6_replay_of_gone_wid_is_idempotent`, `test_DW_1_6_create_destroy_queued_while_suppressed` all pass)

### DW-1.7
PREMISE:  "generation counter increments per action and is readable by handlers/sweep — unit test asserts monotonic increase."
EVIDENCE: SerializationPrimitives.swift:103–113 (GenerationCounter); GridReconciler.swift:70–74 (`var generation: UInt64`, bumped in executeAction and beginAction)
TRACE:    `generationCounter.bump()` called on each action entry → `current &+= 1` → `generation` property returns `generationCounter.current` → handlers read `generation` before/after await to detect staleness.
VERDICT:  PASS (tests `test_DW_1_7_generation_increments_per_action`, `test_DW_1_7_generation_monotonic_under_interleave`, `test_DW_1_7_generation_increments_on_each_begin` all pass)

**All requirements met:** YES

---

## Test-DW Coverage

| DW Item | Test(s) | Coverage Type |
|---------|---------|---------------|
| DW-1.1 ordering | `test_DW_1_1_overlapping_submits_complete_in_submission_order` | Automated |
| DW-1.1 inflight≤1 | `test_DW_1_1_inflight_never_exceeds_one` | Automated |
| DW-1.2 no interleave | `test_DW_1_2_concurrent_layout_cycle_serialized` | Automated |
| DW-1.3 refcount | `test_DW_1_3_fence_refcount_acquire_twice_release_once_still_fenced`, `test_DW_1_3_release_to_zero_removes_entry`, `test_DW_1_3_release_unheld_is_noop`, `test_DW_1_3_expiry_path_clears`, `test_DW_1_3_reconciler_fence_is_refcounted` | Automated |
| DW-1.4 consume-once | `test_DW_1_4_action_token_consumed_exactly_once`, `test_DW_1_4_distinct_tokens_independent`, `test_DW_1_4_double_endAction_same_token_does_not_underflow_other_session` | Automated |
| DW-1.5 step order | `test_DW_1_5_coalesce_same_direction_repeats`, `test_DW_1_5_reverse_direction_steps_back_once` | Automated |
| DW-1.6 queue+replay | `test_DW_1_6_events_queued_while_suppressed_replayed_in_order`, `test_DW_1_6_replay_of_gone_wid_is_idempotent`, `test_DW_1_6_create_destroy_queued_while_suppressed` | Automated |
| DW-1.7 monotonic gen | `test_DW_1_7_generation_increments_per_action`, `test_DW_1_7_generation_monotonic_under_interleave`, `test_DW_1_7_generation_increments_on_each_begin` | Automated |

- [x] All DW items have corresponding automated tests (ran in Step 0, all 131 pass)
- [x] Coverage matches the stated level: unit/integration tested for mechanism; UAT-tagged items (live tap balance, real held-key burst) are noted as live-build only per spec

---

## Dead Code

None found. No unreachable code after early returns, no debug statements, no commented-out blocks in the reviewed files.

Minor note: `inflight` counter in CommandExecutor (line 43) is written and logged but never read from outside the consumer task. This is intentional for log-observable diagnostics per DW-1.1 ("cmd.exec{inflight}" logged).

---

## Correctness Dimensions

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Concurrency | PASS | CommandExecutor uses AsyncStream + single consumer Task; no shared mutable state between concurrent submitters. `inflight` var is only read/written inside the single consumer task (no concurrent access). GridReconciler state mutated only from within serialized command bodies (via executor) or event handler calls. |
| Error Handling | PASS | `executeAction` catch branch at GridReconciler.swift:143–158 drains `suppressedEvents` and decrements `suppressionDepth` even on throw. BFDManager fallback to direct router dispatch if executor not wired (lines 156–163). NudgeKeyHandler.start() failure path at GridCommandRouter.swift:855–860 cleans up token, feed, and BFD tap before returning error. |
| Resources | PASS | NudgeStepFeed Continuation is `finish()`-ed on both normal exit (line 887) and tap-start failure (line 858), allowing the consumer Task to exit. RefcountedFence lazily clears expired entries on `isFenced()`. AsyncStream uses `.unbounded` buffering — no drop risk for nudge repeats. |
| Boundaries | PASS | `GenerationCounter` uses wrapping add (`&+=`) to avoid UInt64 overflow. `ActionTokenRegistry.nextID` uses wrapping add. `suppressionDepth` clamped via `max(0, suppressionDepth - 1)` in all decrement sites to prevent negative values. `RefcountedFence.release()` guards `entry.count <= 0` to prevent underflow. |
| Security | N/A | No untrusted external input parsing in the reviewed primitives; all inputs come from internal server state. |

---

## Edge Case Verification

| Edge Case | Handling | Verdict |
|-----------|----------|---------|
| double `@nudge enter` racing `nudgeKeyHandler != nil` | CommandExecutor serializes both enters; second enter sees `nudgeKeyHandler != nil` at GridCommandRouter.swift:799 and returns early — no second token minted, no second tap installed. Token consumed exactly once. | PASS |
| fence release with overlapping acquisitions | `RefcountedFence.release()` only calls `entries.removeValue` when `entry.count <= 0` (line 65). At count > 0 the entry is retained. | PASS |
| `executeAction` throwing still drains suppressed queue | catch branch at GridReconciler.swift:143–158 calls `replaySuppressedEvents()` when `suppressionDepth == 0` unconditionally. | PASS |
| replay of already-gone wid is idempotent | `handleWindowDestroyed` calls `gridState?.removeWindowFromAllSpaces(windowID)` — safe no-op for untracked wid. `handleWindowCreated` bails at line 627–634 if wid not in `wmState.windows`. `test_DW_1_6_replay_of_gone_wid_is_idempotent` verified this at the queue layer. | PASS |

### Stated Constraints

| Constraint | Verification | Verdict |
|-----------|-------------|---------|
| Serializer preserves `awaitWakeCompletion` | `GridCommandRouter.dispatch()` calls `await gridReconciler.awaitWakeCompletion()` at line 174 before routing — still honored in every command body. | PASS |
| Nudge session does NOT hold serial queue across keystrokes | `handleNudge("enter")` returns `.ok()` at line 872 after installing the tap; the step consumer is a standalone `Task {}` (line 820) independent of the executor queue. | PASS |
| Swift actor (not DispatchQueue+locks) for new serial state | CommandExecutor.swift has zero `DispatchQueue`, `NSLock`, or `pthread_mutex` calls. Serialization is via `AsyncStream` + single consumer `Task`. Comment at lines 10–16 explains the explicit choice of AsyncStream over bare actor (actor reentrancy would break serialization). | PASS |
| No `Task{}` back into the owning actor/consumer | The nudge exit callback `Task { _ = await self.dispatch("@nudge exit") }` calls `GridCommandRouter.dispatch()` directly (not `executor.submit()`). The step pump consumer `Task {}` is a separate independent task, not re-entered. | PASS |

---

## Notes (non-blocking)

1. **Nudge exit bypasses executor serialization:** The `@nudge exit` dispatch from the tap callback calls `self.dispatch()` directly rather than going through `executor.submit()`. This is intentional (comment at GridCommandRouter.swift:839: "NOT through the executor") and safe for the current design, but means nudge-exit can race with any in-flight executor command body. Not a requirement violation per the DW items.

2. **`inflight` counter not actor-isolated:** `CommandExecutor.inflight` is a stored var on a `final class` accessed exclusively from the single consumer `Task` (via weak `self`). This is safe because only one consumer task ever touches it, but Swift's strict concurrency checker may warn about this in future toolchain versions. Not a current test failure.

3. **EventAllowlistTests covers DW-2.5** (a different phase's DW), not a Phase 1 item. It passes, confirming the event names introduced by Phase 1 (`cmd.exec`, `cmd.submit`, `fence.acquire`, `fence.release`, `reconcile.suppressed.queue`, `reconcile.suppressed.replay`, `warn.action.end.consumed`, `warn.action.end.underflow`) are all in the allowlist.

---

**Verdict: PASS**
