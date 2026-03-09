# Review: Phase 6 - Cell Ops + Window Move + Layout Apply

## Verdict: FAIL

## Spec Match
- [x] All pseudocode sections implemented (GridCellOps, GridWindowMove, GridApply)
- [x] Prerequisite modifications done (GridFocus private->internal, GridReconciler syncBordersForSpace internal)
- [x] No unplanned additions
- [x] Test coverage: plan says "manual verification" for Phase 6 -- no unit tests required, none added. Matches.

### Deviations

1. **bundleIDLookup returns appName instead of bundleIdentifier (BUG)**
   - Pseudocode (line 737): `bundleIDLookup: { pid in wmState.windows.values.first(where: { $0.pid == pid })?.bundleID }`
   - Implementation (GridApply.swift line 139): `bundleIDLookup: { pid in wmState.windows.values.first(where: { $0.pid == pid })?.appName }`
   - `matchesAppRule` in GridAssignment.swift compares `rule.app == (bundleID ?? "")`. App rules using bundle identifiers (e.g., `com.apple.Safari`) will never match because `appName` ("Safari") is passed where `bundleIdentifier` is expected.
   - `WindowState` has no `bundleID` field; the correct lookup is `wmState.applications[String(pid)]?.bundleIdentifier`.

2. **buildCellModesAndRatios visibility**: Pseudocode specifies `private` in GridWindowMove. Implementation makes it `func` (internal). This is acceptable -- GridApply inlines the same logic rather than sharing the helper, so the broader visibility is harmless. Not a failure.

3. **filterTileableFromState space matching**: Pseudocode uses `String(windowState.spaceID ?? 0) == spaceID`. Implementation uses `windowState.spaces.contains(spaceIDInt)` which is more correct (windows can be on multiple spaces). This is an improvement over pseudocode. Not a failure.

4. **findClosestCellToPoint return type**: Pseudocode says `String?`. Implementation returns `String` (empty string for no match). GridWindowMove handles this correctly with `guard !targetCell.isEmpty`. Not a failure.

## Dead Code
None found. All imports used, no debug statements, no commented-out blocks, no unreachable code after early returns.

## Correctness Verification
| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | FAIL | bundleIDLookup closure provides wrong data type -- app rule matching by bundleID is broken |
| Concurrency | PASS | TaskGroup used for parallel placement; each task operates on different window/AX element; weak self captured in closures; GridState actor serializes state access |
| Error Handling | PASS | All operations that can fail throw typed errors with descriptive messages; guard-let chains at entry points; no empty catch blocks; try? used only for optional config lookups (intentional fallthrough) |
| Resource Mgmt | N/A | No file handles, sockets, or long-lived resources acquired |
| Boundaries | PASS | Empty arrays handled (placements.isEmpty early return, candidates.isEmpty branching); zero windowID checked; index clamping with max(0, min(idx, count-1)); empty cellWindows returns early in applyCellLayout |
| Security | N/A | No untrusted external input; all data from in-process StateManager |

## Defensive Programming
- No empty catch blocks found
- No swallowed exceptions -- all errors either thrown or logged via jlog
- External input (StateManager state) validated at entry points with guard-let chains
- Assertion-worthy conditions handled via guard/throw (no assertions with side effects)
- Weak reference nil checks done consistently before use
- `defer { gridReconciler?.setSuppressed(false) }` ensures suppression is always cleared even on error paths -- correct resource management pattern

## Issues (if FAIL)
1. **bundleIDLookup closure passes appName instead of bundleIdentifier**
   - File: `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Grid/GridApply.swift:138-140`
   - Fix: Change the closure to look up the actual bundle identifier from ApplicationState:
     ```swift
     bundleIDLookup: { pid in
         wmState.applications[String(pid)]?.bundleIdentifier
     }
     ```
   - Impact: App rules that match by bundle identifier (e.g., `com.apple.Safari`, `com.googlecode.iterm2`) will fail to pin windows to preferred cells. Rules matching by app name still work because `matchesAppRule` also checks `rule.app == appName`.
