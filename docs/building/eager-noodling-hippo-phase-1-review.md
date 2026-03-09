# Review: Phase 1 - GridTerminalManager Actor + Frame Persistence

## Verdict: PASS

## Spec Match
- [x] All pseudocode sections implemented (21/21 sections mapped)
- [x] No unplanned additions
- [x] Test coverage verified (plan specifies per-phase manual verification; no unit tests required)

Deviations (all acceptable):
1. `loadFramesFromDisk()` implemented as top-level `private func loadTerminalFramesFromDisk()` instead of actor method. This avoids Swift actor isolation warnings in `init` where async/isolated methods cannot be called. Functionally identical.
2. Return values from MSSClient/WindowManipulator calls are discarded with `_ =` (not in pseudocode). Correct -- these return Bool success flags that are not actionable in the toggle flow.

## Dead Code
None found. All private methods are called. All constants are referenced. No commented-out blocks, debug statements, or unreachable code paths.

## Correctness Verification
| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | PASS | All plan requirements implemented: 4-tier resolution, MSS alpha + off-screen hide, per-display frame persistence, toggling guard, reconciler suppression, Ghostty launch with correct args, layer setting, PID liveness via kill(pid,0) |
| Concurrency | PASS | Actor isolation protects all mutable state (savedWindowID, savedPID, isHidden, toggling, displayFrames). Toggling guard at line 112 prevents re-entrant interleaving across async suspension points. GridReconciler is a plain class stored as `let` -- its `setSuppressed` is synchronous and documented as thread-safe. Build compiles clean. |
| Error Handling | PASS | Process.run() wrapped in do/catch returning `.error()` (line 292-297). Frame load from disk catches and logs, returns empty dict (line 32-34). Frame flush catches and logs (line 423-424). Poll timeout returns `.error()` with message (line 312-313). No empty catch blocks. No swallowed exceptions. |
| Resource Mgmt | PASS | `Process` object is fire-and-forget (launched via `open -na` which returns immediately). No file handles held open -- reads and writes are scoped. No sockets, locks, or long-lived resources. `defer` blocks ensure toggling flag and reconciler suppression are always restored. |
| Boundaries | PASS | Empty displayFrames dict handled (returns `[:]` on missing file). Nil savedPID/savedWindowID handled (falls through tiers). Missing display info falls back to 1920x1080 default frame. Poll loop bounded at 50 attempts. Single-window PID fallback in `findGhosttyWindow` handles title mismatch edge case. |
| Security | N/A | No untrusted external input. All data comes from OS state (StateManager), internal actor state, or controlled Ghostty launch args. Shell path from environment is used in a controlled context (passed as arg to `open`). |

## Defensive Programming
Checked items:
- **No empty catch blocks**: All catch blocks either log errors and return graceful results, or log and continue with safe defaults.
- **No assertions with side effects**: No assertions used (correct -- all conditions are anticipated runtime states, not programmer bugs).
- **External input validated**: No external input enters this actor. StateManager data is from OS queries (trusted barricade). File data (terminal-frames.json) is decoded with try/catch, corrupt files produce empty dict.
- **Error strategy consistency**: Follows codebase pattern -- log via `jlog()`, return `CommandResult.error()` or degrade gracefully.
- **Toggling guard with defer**: Lines 117-118 ensure `toggling = false` even if an error is thrown during toggle. Same pattern for reconciler suppression at lines 121-122.
- **PID liveness check**: `Darwin.kill(pid, 0)` correctly returns 0 only if process exists and caller has permission (covers the Ghostty case since both run as same user).

No violations found.

## Issues
None.
