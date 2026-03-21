# Review: Phase 1 - State Validator

## Verdict: PASS

## Spec Match

- [x] All pseudocode sections implemented
- [x] No unplanned additions
- [x] Test coverage: plan specifies "Minimal validation"; no Phase 1 unit tests were written, which matches the plan scope (test items are listed as cross-phase, not Phase 1 blockers)

### Section mapping

| Pseudocode Section | Implementation | Status |
|---|---|---|
| `StateValidator` actor with `start()`, `validate(wmState:)`, three private passes, `pickBestSpace` | `StateValidator.swift` lines 12-196 | PASS |
| `GridState.getSpaceIDs()` | `GridState.swift` lines 246-248 | PASS |
| `GridReconciler`: strong `stateValidator` property, `setValidator(_:)`, `await stateValidator?.validate(wmState:)` in `handleSystemWake` | `GridReconciler.swift` lines 32, 109-111, 477 | PASS |
| `main.swift`: instantiate, wire, `await stateValidator.start()`, `jlog("validate.init")` | `main.swift` lines 144-154 | PASS |

### Fix verification

Previous POST-GATE found `stateValidator` declared `weak` in GridReconciler, causing immediate deallocation. The fix is confirmed: `GridReconciler.swift:32` now reads `private var stateValidator: StateValidator?` (strong). GridReconciler is the long-lived owning reference, keeping the validator and its timer alive for process lifetime.

### Plan requirements mapping

| Requirement | Code location | Status |
|---|---|---|
| Runs on wake | `GridReconciler.swift:477` — `await stateValidator?.validate(wmState: wmState)` in `handleSystemWake` | PASS |
| Runs every ~30s | `StateValidator.swift:25,43-47` — `validationInterval = 30.0`, repeating timer | PASS |
| Dead windows removed | `StateValidator.swift:81-103` — `pruneDeadWindows` via `SLSGetWindowBounds` | PASS |
| Windows in multiple spaces deduplicated | `StateValidator.swift:107-140` — `deduplicateWindows` with `pickBestSpace` | PASS |
| Spaces not in wmState pruned | `StateValidator.swift:144-156` — `pruneDeadSpaces` | PASS |
| All actions logged with `validate.*` prefix | `StateValidator.swift:61,68,74,100,133-137,153` | PASS |
| Minimized window guard | `StateValidator.swift:88-91` — checked before SLS call | PASS |

## Dead Code

None found.

`suppressionDepth`, `moveCooldownSeconds`, `moveTargetWindowID`, and `moveEndTime` remain in GridReconciler — these are Phase 2 scope and actively used by `beginMove`/`endMove`/`isInMoveCooldown`. Not dead code for Phase 1.

No unreachable code after early returns. No commented-out blocks. No debug statements in new or modified files.

## Correctness Verification

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | PASS | All 7 plan requirements mapped to specific lines above |
| Concurrency | PASS | StateValidator is an actor. Timer fires `Task { await self.validate() }` — correct pattern for actor-isolated work from DispatchSource callback. Sequential awaits on GridState actor prevent interleaved mutation. `removeWindow` on an already-absent wid safely no-ops (`GridState.swift:403` guard). `stateValidator` is now strong in GridReconciler, keeping the timer alive. |
| Error Handling | PASS | `SLSGetWindowBounds` result checked explicitly (`if err != .success`). `guard let gridState` in every private pass. `guard let stateManager` in timer handler. No thrown errors suppressed. `UInt64(spaceID)` conversion uses optional binding. |
| Resource Mgmt | PASS | `DispatchSourceTimer` stored as `self.timer` before `source.resume()` — ARC retains it. `[weak self]` in timer event handler prevents DispatchSource → actor retain cycle. `gridState`/`stateManager` held `weak` in StateValidator (they outlive it, owned by main.swift). `stateValidator` held strong in GridReconciler (owning reference). |
| Boundaries | PASS | Empty `allTrackedIDs`: loop skips, `validate.end` logged. Empty `spaceIDs`: `windowSpaces` empty, dedup pass does nothing. `spaceIDs[0]` in `pickBestSpace` only reachable when `count > 1`, so never out-of-bounds. |
| Security | N/A | No untrusted external input. Window IDs and wmState are internal actor-sourced data. |

## Defensive Programming

Checked against cc-defensive-programming checklist:

| Item | Status | Evidence |
|------|--------|----------|
| No empty catch blocks | PASS | No try/catch used; Swift async/await propagates cleanly |
| No executable code in assertions | PASS | No assertions used in StateValidator |
| External input validated at entry | N/A | No external trust boundary crossed in this module |
| `guard let self` in timer closure | PASS | `StateValidator.swift:50` |
| `guard let gridState` in each private pass | PASS | `StateValidator.swift:82, 109, 145` |
| Correct weak/strong ownership | PASS | Weak for dependencies (gridState, stateManager); strong for owned object (stateValidator in GridReconciler) |
| wmState consistency in handleSystemWake | PASS | Same wmState snapshot used for both `migrateSpaceIDs` and `validate()`. After migration, GridState keys match the new space IDs drawn from that same wmState, so `pruneDeadSpaces` comparison is consistent. |

No critical defensive violations found.

## Issues

None.
