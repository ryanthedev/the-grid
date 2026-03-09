# Review: Phase 1 - GridReconciler pending launch target + layout/focus deps

## Verdict: PASS

## Spec Match
- [x] All pseudocode sections implemented
- [x] No unplanned additions
- [x] Test coverage verified (manual per plan)

### Section-by-section mapping

| Pseudocode Section | Implementation | Match |
|---|---|---|
| `PendingLaunchTarget` struct (spaceID, cellID, createdAt) | Lines 12-16 | Exact match |
| `gridApply` weak ref | Line 27 | Exact match |
| `gridFocus` weak ref | Line 28 | Exact match |
| `pendingLaunchTarget` property | Line 31 | Exact match |
| `pendingLaunchTimeout = 15.0` | Line 34 | Exact match |
| `setPendingLaunchTarget` with logging | Lines 79-84 | Exact match |
| `setApply` setter | Lines 86-88 | Exact match |
| `setFocus` setter | Lines 90-92 | Exact match |
| `handle()` pre-suppression intercept for windowCreated | Lines 129-134 | Exact match -- checks `pendingLaunchTarget != nil` before suppression guard |
| `handle()` fall-through to suppression + switch | Lines 137-166 | Exact match -- windowCreated still handled at line 145-146 when no pending target |
| `handlePendingLaunchWindow` guard + race safety | Lines 222-227 | Exact match -- falls through to handleWindowCreated |
| One-shot clear at top | Line 230 | Exact match -- cleared before any validation |
| Timeout check | Lines 233-238 | Exact match |
| stateManager + window state lookup | Lines 241-246 | Exact match -- falls through on missing window |
| isTileable validation | Lines 249-252 | Exact match |
| classifyWindow + standard check | Lines 255-260 | Exact match |
| Space match validation | Lines 263-271 | Exact match -- logs mismatch with expected/actual |
| Layout existence check | Lines 274-279 | Exact match |
| prependWindow to target cell | Line 282 | Exact match |
| setFocus with windowIndex 0 | Line 283 | Exact match |
| try? applyCellLayout | Line 286 | Exact match -- uses optional chaining on weak ref |
| try? focusWindowByID | Line 289 | Exact match -- uses optional chaining on weak ref |
| syncBordersForCurrentSpace | Line 292 | Exact match |
| Log reconcile.win.create.picker | Line 294 | Exact match |

No deviations found. No unplanned additions.

## Dead Code
None found. All new code paths are reachable:
- `setPendingLaunchTarget`, `setApply`, `setFocus` are public API for Phase 3/4 wiring
- `handlePendingLaunchWindow` is called from `handle()` when pending target exists
- No unused imports, no debug statements, no commented-out blocks

## Correctness Verification

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | PASS | All 8 plan checklist items for Phase 1 mapped to implementation (struct, properties, 3 public methods, handle() restructuring, handlePendingLaunchWindow with full validation chain) |
| Concurrency | PASS | GridReconciler events arrive via EventRouter (serial async). `pendingLaunchTarget` is set from main thread (PickerManager callback in Phase 3) and read in async event handler. Swift actor isolation via async/await prevents data races. Follows existing pattern for `suppressReconciliation` and `moveTargetWindowID`. |
| Error Handling | PASS | Every validation failure in `handlePendingLaunchWindow` falls through to `handleWindowCreated` (7 fall-through paths). `try?` on applyCellLayout/focusWindowByID is intentional -- window is already assigned, layout/focus are best-effort. Two bare `guard ... else { return }` paths (stateManager nil at line 241, gridState nil at line 274) match existing patterns in handleWindowCreated. |
| Resource Mgmt | N/A | No resources acquired -- only state mutations and method calls |
| Boundaries | PASS | Empty/nil handled: nil pendingLaunchTarget (guard at line 223), nil stateManager (guard at line 241), missing window in wmState (guard at line 243), nil actualSpaceID (line 264), empty layoutID (line 276). Timeout boundary: `elapsed > pendingLaunchTimeout` correctly handles the 15s edge. |
| Security | N/A | No untrusted external input -- all data from internal OS event system |

## Defensive Programming

### Crisis invariants checked:
- **No empty catch blocks**: No catch blocks at all. `try?` is used intentionally for non-fatal operations where the window is already assigned.
- **No executable code in assertions**: No assertions used (correct for Swift runtime code).
- **External input validated**: windowID comes from OS events (trusted). All state lookups are guarded.
- **Silent failures**: Two `guard ... else { return }` paths (lines 241, 274) silently return without falling through to `handleWindowCreated`. These match the existing pattern in `handleWindowCreated` (lines 186, 193) where nil stateManager/gridState means the system is in a broken state and no assignment is possible. Acceptable -- these represent "system not initialized" conditions, not recoverable errors.

### CRITICAL check: suppression bypass
Verified at lines 129-134: `.windowCreated` with a pending target is handled BEFORE the `if suppressReconciliation { return }` guard at line 137. This is the key requirement from the plan -- picker-launched windows are claimed even during move suppression. The implementation matches the exact pattern from the plan's code snippet.

### Fall-through chain completeness
Every validation failure path in `handlePendingLaunchWindow` calls `await handleWindowCreated(windowID, pid)` except the two nil-dependency guards (stateManager, gridState). This ensures windows are never silently dropped -- they get default assignment on failure.

## Issues
None.
