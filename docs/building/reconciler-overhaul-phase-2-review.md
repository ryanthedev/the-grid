# Review: Phase 2 - Command Fencing

## Verdict: PASS

## Spec Match
- [x] All pseudocode sections implemented
- [x] No unplanned additions
- [x] Test coverage verified (plan specifies "Minimal validation"; no unit tests required)

### Section-by-section mapping

| Pseudocode Section | Implementation | Match |
|---------------------|----------------|-------|
| Remove old properties (moveTargetWindowID, moveEndTime, moveCooldownSeconds, isInMoveCooldown, beginMove, endMove, clearMoveCooldown) | All removed from GridReconciler.swift. Zero grep hits across entire server codebase (only a comment in GridWindowMove.swift step 8 referencing `beginMove` for context). | Exact |
| Add fence properties (fencedWindows, fenceTimeoutSeconds) | GridReconciler.swift:48-51. `[UInt32: CFAbsoluteTime]` dictionary, 5.0s timeout. | Exact |
| acquireFence method | GridReconciler.swift:81-94. Includes empty-set guard with warning log per defensive programming spec. | Exact |
| releaseFence method | GridReconciler.swift:97-104. Dictionary removal, sorted wids logged. | Exact |
| isWindowFenced query | GridReconciler.swift:127-140. Lazy expiry cleanup, warning log on expired fence. | Exact |
| Modify handleFocusChanged (suppression check -> fence check -> normal) | GridReconciler.swift:386-455. Three-tier: suppressReconciliation, isWindowFenced, normal processing. Order matches pseudocode. | Exact |
| Remove clearMoveCooldown usage | GridCommandRouter.swift: zero grep hits for `clearMoveCooldown`. No replacement needed per pseudocode (user commands bypass handleFocusChanged). | Exact |
| moveWindowToCell: acquire fence, await border sync, release fence | GridWindowMove.swift:253-254 (acquire), 337-339 (await sync), 341-342 (release). Fire-and-forget `Task{}` replaced with direct `await`. | Exact |
| moveWindowCrossDisplay: acquire fence before SLS, release after both syncs | GridWindowMove.swift:426-427 (acquire before SLS at step 6), 508-509 (both syncs awaited), 512 (release). Fence acquired earlier than old beginMove (was step 8, now step 6). | Exact |
| findSpaceContaining deterministic (sorted keys) | GridState.swift:522-532. Iterates `spaces.keys.sorted()`. | Exact |
| findSpaceContaining with preferredSpaceIDs overload | GridState.swift:537-560. Two-pass: preferred spaces first, then remaining sorted. Uses `Set` for O(1) lookup on second pass. | Exact |
| Keep setSuppressed for non-move callers | GridReconciler.swift:60-76. suppressionDepth retained. Used by GridApply, PickerManager, GridTerminalManager, GridCommandRouter (confirmed via grep). | Exact |

### Deviations from plan

The plan says "remove `suppressionDepth`" but the discovery file (Gap 1) and pseudocode explicitly document keeping it for non-move callers. The implementation follows the pseudocode, which is the binding spec. This is a documented and justified deviation from the original plan text.

## Dead Code
None found. No print statements, no commented-out code blocks, no unused imports. The comment at GridWindowMove.swift:458 referencing `beginMove` is explanatory context for the step numbering, not dead code.

## Correctness Verification
| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | PASS | All 6 "done when" items verified: (1) fences acquired in both move paths, (2) fences release after border sync not time-based, (3) 5s safety timeout on fencedWindows, (4) findSpaceContaining uses sorted keys, (5) same-display sync awaited not fire-and-forget, (6) moveCooldownSeconds fully removed, suppressionDepth retained per discovery |
| Concurrency | PASS | GridReconciler is a class (not actor) but is only accessed from within GridState actor context or from the EventRouter's serial dispatch. fencedWindows dictionary accessed only within GridReconciler methods. GridState is an actor providing isolation for findSpaceContaining. No TOCTOU gaps: fence is acquired before state mutation and released after sync. |
| Error Handling | PASS | acquireFence guards empty set with warning log. releaseFence on unfenced window is a no-op (dictionary removeValue returns nil silently). Fence expiry logs warning. suppressionDepth underflow guarded with max(0, depth-1) and warning log. No empty catch blocks. |
| Resource Mgmt | PASS | fencedWindows entries are bounded by window count and cleaned lazily on expiry check. No file handles, sockets, or connections acquired. Safety timeout prevents unbounded growth of stale entries. |
| Boundaries | PASS | Empty windowIDs set handled with early return. Single-window fencing (the common case) works correctly. Multiple concurrent fences supported naturally by per-window timestamps (each window gets independent expiry). |
| Security | N/A | No untrusted external input. Window IDs come from OS accessibility framework. |

## Defensive Programming

### Crisis invariants checked
- **No empty catch blocks**: Confirmed. No catch blocks in any changed code.
- **No executable code in assertions**: No assertions used; fence expiry is runtime safety logic, not assert.
- **External input validated**: Window IDs from OS are validated at barricade (handleFocusChanged checks guard for windowID existence before fence check).

### Barricade design
handleFocusChanged serves as the barricade between OS events and grid state. Check order: (1) suppressReconciliation blocks all events during bulk ops, (2) isWindowFenced blocks per-window during moves, (3) normal processing. This is correct layering.

### Fence release on error paths
In both moveWindowToCell (line 330) and moveWindowCrossDisplay (line 494), `try await gridFocus.focusWindowByID(windowID)` can throw between fence acquire and release. If it throws, releaseFence is skipped. The 5-second safety timeout handles this case -- the fence expires and logs a warning. This matches the pseudocode error handling analysis which explicitly defines fence expiry as "not an error" but a "safety net." The window is at most blocked from OS focus events for 5 seconds. Acceptable given the design intent.

### Pattern consistency
Fence acquire/release pattern is consistent between both move paths. Logging events use `fence.acquire`, `fence.release`, `fence.expired`, `reconcile.focus.fenced` -- all follow existing JSONL conventions.

## Observations
1. Fence release is not wrapped in `defer` -- if focusWindowByID throws, the fence leaks for up to 5 seconds. The safety timeout mitigates this. The pseudocode explicitly specifies this pattern and the error handling analysis defines fence expiry out of existence as a safety mechanism. Not a FAIL, but worth noting for future hardening.
2. The `findSpaceContaining` overload with `preferredSpaceIDs` is defined but not called in Phase 2. It is intended for use in later phases (Phase 3 focus tracking). This is forward-compatible API, not dead code.
