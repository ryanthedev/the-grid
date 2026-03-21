# Review: Phase 4 - Border-Per-Cell Model

## Verdict: PASS

## Spec Match
- [x] All pseudocode sections implemented
- [x] No unplanned additions
- [x] Test coverage verified (plan specifies "Minimal validation" -- no unit tests required for Phase 4; plan's unit tests are scoped to Phases 1-2)

### Section Mapping

| Pseudocode Section | Implementation | Status |
|---|---|---|
| Change 1: Mode-Aware `rebuildBorderPool` | SimpleBorderManager.swift:611-672 | MATCH |
| Change 2: Mode-Aware `reassignBorders` | SimpleBorderManager.swift:565-606 | MATCH |
| Change 3: Eliminate `atomic-positionRefresh` | SimpleBorderManager.swift:183-188 (call site), 677-704 (`refreshBorderPositions`) | MATCH |
| Change 4: Completion Signaling | SimpleBorderManager.swift:133 (parameter), 138-139 (invocation) | MATCH |
| Change 5: Display Disconnect | No change (pseudocode says "No change needed") | MATCH |
| GridReconciler Change 1: Awaitable `syncBordersForSpace` | GridReconciler.swift:614-617, 673-685 | MATCH |

### Pseudocode Edge Cases Verified
- Tabbed mode with no focused window: falls back to `windowsInCell.first` (line 636)
- Tabbed reassign with no active border: acquires one (line 577)
- Split reassign with missing border: acquires and logs warning (line 596-603)
- `simpleBorderManager` nil in reconciler: `if let` guard skips continuation, returns immediately (lines 614, 673)

## Dead Code
None found. The `atomic-positionRefresh` string was fully removed. No commented-out blocks, no TODO/FIXME/HACK markers in changed files. No unused imports introduced.

## Correctness Verification

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | PASS | All 5 plan acceptance criteria mapped: (1) tabbed cells get 1 border via mode-aware rebuild, (2) retarget within cell via mode-aware reassign, (3) pool evictions reduced since tabbed mode bypasses pool, (4) `atomic-positionRefresh` replaced with `refreshBorderPositions`, (5) display disconnect unchanged and correct |
| Concurrency | PASS | All `SimpleBorderManager` mutations run on `DispatchQueue.main` (enforced by `dispatchPrecondition` in pool ops). `withCheckedContinuation` correctly bridges async/main-queue boundary. Completion closure always fires (either `completion?()` after impl, or `if let` guard prevents entering continuation when manager is nil). No new shared mutable state introduced. |
| Error Handling | PASS | `refreshBorderPositions` handles `SLSGetWindowBounds` failure by skipping the border (no crash). `acquireBorder` handles bounds failure by destroying the border and logging. Pre-existing silent `catch { return }` at GridReconciler.swift:626 is not a Phase 4 change. |
| Resource Mgmt | PASS | No new resource acquisition. Borders continue to be released to pool (bounded by `maxPoolSize = 10`) or destroyed. `withCheckedContinuation` always resumes: the completion closure is always called after `setCellAssignmentsImpl` completes (line 138-139), and when `simpleBorderManager` is nil the code path skips the continuation entirely (no dangling continuation). |
| Boundaries | PASS | Empty cell (`windowsInCell` empty): tabbed path sets `targetWindow = nil`, no border acquired. Single window: works correctly (1 border, tabbed or split). Zero focused window: `focusedWID != 0 ? focusedWID : nil` guard at line 678 handles this. |
| Security | N/A | No untrusted input processing. Window IDs come from SkyLight/AX APIs. |

## Defensive Programming

| Check | Status | Evidence |
|-------|--------|----------|
| No empty catch blocks (in Phase 4 changes) | PASS | No catch blocks introduced by Phase 4. Pre-existing one at GridReconciler:626 is unchanged. |
| No swallowed exceptions | PASS | Completion closure always invoked via `completion?()` after `setCellAssignmentsImpl`. |
| No assertions with side effects | PASS | `dispatchPrecondition` is diagnostic only (no side effects). |
| External input validated | N/A | No new external input entry points. |
| Continuation always resumed | PASS | Two `withCheckedContinuation` sites: both are inside `if let borderManager` guards, so the continuation is only created when `borderManager` is non-nil. Within the continuation, `completion: { continuation.resume() }` is passed to `setCellAssignments`, which always calls `completion?()` on the main queue dispatch path. The weak self capture in the dispatch block means `self?` could be nil, in which case `setCellAssignmentsImpl` is skipped but `completion?()` still fires because it is on a separate line after the optional chain. |

### Pre-existing Observation (Not a Phase 4 Issue)
The `catch { return }` at GridReconciler.swift:626 silently swallows layout lookup errors. This predates Phase 4 and is outside this review's scope, but worth noting for Phase 5 or a future pass.

## Issues
None.
