# Review: Phase 4 — TmuxStatusDriver

## Executed Results (Step 0)

- **Test suite**: `swift test` (TmuxStatusDriverTests, 17 tests)
  - Result: **PASS** — All 17 tests passing (7.683s)
  - Full suite: 64 tests total across all test classes, 0 failures
- **Build**: `swift build` — **PASS** (0.16s)
- **Typecheck/Lint**: Implicit via `swift build` — no warnings or errors

## Requirement Fulfillment

### DW-4.1
**PREMISE**: While a run holds the lock, a second attempt is skipped and logs `tmux.driver.skip` (single-instance proven).

**EVIDENCE**: 
- Implementation: `TmuxStatusDriver.swift:256–261` (flock attempt with LOCK_EX|LOCK_NB, on failure logs skip)
- Test: `test_DW_4_1_lock_held_second_attempt_skipped` (lines 68–86) — external flock simulation
- Test: `test_DW_4_1_two_drivers_same_lockfile_second_skips` (lines 90–109) — two drivers competing

**TRACE**: 
1. Driver 1 calls `refreshNow()` → `queue.async { attemptRun() }`
2. Opens lockfile, `flock(fd, LOCK_EX | LOCK_NB)` succeeds, sets `isRunning=true`, spawns process
3. Driver 2 calls `refreshNow()` while Driver 1 holds lock
4. Opens lockfile, `flock(fd, LOCK_EX | LOCK_NB)` returns non-zero (EWOULDBLOCK)
5. Logs `tmux.driver.skip` (line 259), closes fd, returns without spawn
6. Result: Driver 1 spawnCount=1, Driver 2 spawnCount=0

**VERDICT**: **PASS** — Requirement met with execution evidence (two passing tests demonstrating single-instance proof)

---

### DW-4.2
**PREMISE**: `start()` performs an immediate run then repeats on the configured interval; `stop()` halts further runs and terminates any in-flight process.

**EVIDENCE**:
- Implementation: `start()` at lines 145–157 → validates binary, calls `attemptRun()` (immediate), schedules timer
- Implementation: `stop()` at lines 162–171 → cancels timer, calls `terminateInFlight()`
- Implementation: `terminateInFlight()` at lines 361–376 → calls `proc.terminate()`, closes lockFd immediately, resets state
- Tests: `test_DW_4_2_start_runs_immediately` (immediate spawn), `test_DW_4_2_timer_repeats` (≥2 spawns at 0.3s interval in 1.1s), `test_DW_4_2_stop_terminates_inflight` (running flag reset), `test_DW_4_2_stop_releases_lock_for_next_run` (external flock succeeds post-stop)

**TRACE** (start):
1. `start()` called → queue async
2. Check `isStarted` flag (guard), set true
3. Call `validateBinary()` (guards against missing binary)
4. Call `attemptRun()` immediately → spawns process
5. Call `scheduleTimer()` with `config.interval`
6. Timer fires at `deadline: .now() + interval`, repeating every `interval`

**TRACE** (stop):
1. `stop()` called → queue async
2. Check `isStarted` flag (guard), set false
3. Call `cancelTimer()` → timer.cancel(), timer = nil
4. Call `terminateInFlight()` → proc.terminate(), close lockFd, reset isRunning, cancel timeout workitem
5. On next refreshNow/timer tick: guard against isRunning or isStarted prevents new spawns

**VERDICT**: **PASS** — All sub-requirements demonstrated via passing tests and trace

---

### DW-4.3
**PREMISE**: `refreshNow()` triggers an immediate run when idle and is a no-op while one is running.

**EVIDENCE**:
- Implementation: `refreshNow()` at lines 174–184 → checks `isRunning` guard, logs skip if true, calls `attemptRun()` if false
- Test: `test_DW_4_3_refresh_when_idle_spawns` (idle spawn count = 1)
- Test: `test_DW_4_3_refresh_while_running_noop` (in-flight guard prevents second spawn)
- Test: `test_DW_4_3_rapid_refresh_deduplicates` (5 rapid calls while first is sleeping → 1 spawn)

**TRACE**:
1. `refreshNow()` called → queue async
2. Guard: `isRunning` is false → proceed
3. Call `attemptRun()` → spawns (spawnCount incremented)
4. Process runs for 5+ seconds
5. Second `refreshNow()` called → queue async
6. Guard: `isRunning` is true → logs `tmux.driver.refresh.skip`, returns (no increment to spawnCount)

**VERDICT**: **PASS** — Requirement demonstrated via 3 passing tests

---

### DW-4.4
**PREMISE**: A missing/failed `claude` spawn is logged and does not crash or restart-storm.

**EVIDENCE**:
- Implementation: `validateBinary()` at lines 191–202 → checks file exists and is executable, logs `err.tmux.driver.spawn` on failure, returns false, `start()` returns early without scheduling timer (no restart-storm)
- Implementation: `spawnProcess()` at lines 320–324 → catches Process.run() exception, logs `err.tmux.driver.spawn`, calls `releaseRun()` (no crash)
- Test: `test_DW_4_4_missing_binary_logs_error_no_crash` (start() with missing binary: spawnCount=0, isRunning=false, no timer scheduled)
- Test: `test_DW_4_4_refresh_missing_binary_no_crash` (refreshNow() with missing binary: isRunning reset to false post-error)
- Test: `test_DW_4_4_no_restart_storm_on_bad_binary` (validateBinary blocks start(), timer not scheduled, only 0 spawns over 0.5s)

**TRACE**:
1. `start()` called with missingCommand (non-existent binary path)
2. Call `validateBinary()` → FileManager.fileExists() returns false
3. Log `err.tmux.driver.spawn` with `msg: "binary not found"` (line 195)
4. Return false → `start()` returns early without calling `scheduleTimer()` (no timer)
5. No restart-storm because timer is never scheduled
6. spawnCount remains 0, isRunning remains false

**VERDICT**: **PASS** — All three sub-requirements demonstrated via passing tests

---

## Test-DW Coverage

| Requirement | Test Name(s) | Status |
|-------------|------------|--------|
| DW-4.1 Single-instance flock | `test_DW_4_1_lock_held_second_attempt_skipped`, `test_DW_4_1_two_drivers_same_lockfile_second_skips` | ✓ COVERED |
| DW-4.2 start() immediate + repeat | `test_DW_4_2_start_runs_immediately`, `test_DW_4_2_timer_repeats` | ✓ COVERED |
| DW-4.2 stop() halts and terminates | `test_DW_4_2_stop_terminates_inflight`, `test_DW_4_2_stop_releases_lock_for_next_run` | ✓ COVERED |
| DW-4.2 start() idempotent | `test_DW_4_2_start_is_idempotent` | ✓ COVERED |
| DW-4.2 stop() when idle safe | `test_DW_4_2_stop_when_idle_is_safe` | ✓ COVERED |
| DW-4.3 refreshNow() when idle | `test_DW_4_3_refresh_when_idle_spawns` | ✓ COVERED |
| DW-4.3 refreshNow() while running | `test_DW_4_3_refresh_while_running_noop`, `test_DW_4_3_rapid_refresh_deduplicates` | ✓ COVERED |
| DW-4.4 missing binary logged | `test_DW_4_4_missing_binary_logs_error_no_crash` | ✓ COVERED |
| DW-4.4 no restart-storm | `test_DW_4_4_no_restart_storm_on_bad_binary` | ✓ COVERED |
| DW-4.4 refresh missing binary safe | `test_DW_4_4_refresh_missing_binary_no_crash` | ✓ COVERED |

**Coverage Level**: 100% — All DW items have automated tests with execution evidence.

---

## Dead Code

No unused imports, unreachable code, debug statements, or commented-out blocks detected.

---

## Correctness Dimensions

| Dimension | Status | Evidence |
|-----------|--------|----------|
| **Concurrency** | PASS | Queue protection: all mutable state (`isRunning`, `lockFd`, `process`, `timer`) accessed only via private serial DispatchQueue. Weak self in termination handler (line 290, 304) prevents use-after-free. Lock release in both termination handler path (line 308) and immediate path (stop(), line 370). No data races detected in tests. |
| **Error Handling** | PASS | Defensive barricade at entry: `validateBinary()` blocks spawn on missing/non-executable binary (lines 191–202). Spawn failures caught and logged (line 322), cleanup via `releaseRun()`. Lock open fails logged (line 249). flock failures logged (line 259). No empty catch blocks. |
| **Resources** | PASS | Lock fd lifecycle: open at line 247, held in `lockFd`, released in `releaseRun()` (line 350) or `terminateInFlight()` (line 370). Both paths close fd. terminationHandler captures fd (line 288) to release even if self deallocated (lines 292–293). Timeout workitem cancelled at lines 344, 372. Process reference held in `process` var, cleared post-termination. No fd leaks detected in tests. |
| **Boundaries** | PASS | Arguments built as discrete array (lines 36–44), never shell-interpolated. Binary path is absolute URL (line 46), verified at line 192 FileManager API (safe). Config values (model, interval, repoDir) used correctly: model as discrete argv pair (lines 42–44), interval as TimeInterval for DispatchSourceTimer, repoDir as Process.currentDirectoryURL. No string formatting or injection vectors. |
| **Security** | PASS | Binary resolved to absolute path, verified executable before spawn (lines 191–202). No shell invocation (Process API used directly). Arguments hardcoded or derived from config without interpolation. flock(2) advisory lock prevents concurrent spawns from same or different processes. MCP config JSON is a constant (lines 25–27), allowedTools hardcoded (line 30). Command executable verified before each spawn attempt in `validateBinary()`. No untrusted input flows to spawn arguments. |

---

## Notes (non-blocking)

1. **Test lockfile cleanup**: Tests use temp lockfiles (`makeTempLockfile()`) and defer cleanup. Good isolation; no cross-test flock contention.

2. **Weak self discipline**: Excellent use of `[weak self]` in async contexts (lines 146, 176, 216, 290, 303). Prevents cycles and handles deallocation during async ops. Captured fd in termination handler ensures cleanup even if self is nil.

3. **Timer leeway**: 5-second leeway (line 214) is appropriate for a status refresh timer; reduces scheduling jitter.

4. **Timeout enforcement**: 300-second hung-run timeout (line 99) is reasonable for a headless status run (can take minutes for large repo). Timeout workitem scheduled post-spawn (line 319), properly cancelled in `releaseRun()` and `terminateInFlight()`.

5. **Command stubs**: Tests inject `/usr/bin/true` and `/bin/sleep` instead of spawning real Claude. Excellent for deterministic testing without side effects.

6. **Error messages**: Logged errors include context (path, errno, pid). Sufficient for debugging without leaking security-sensitive info.

7. **Argument validation test**: `test_claudeDefault_arguments_are_constants` (lines 308–316) and `test_claudeDefault_with_model_adds_discrete_pair` (lines 318–328) verify command construction. Model correctly added as discrete argv pair, not interpolated.

---

## Issues (if FAIL)

None identified.

---

## Edge Cases (All Handled)

| Edge Case | Handling | Location |
|-----------|----------|----------|
| Binary not found | validateBinary() logs `err.tmux.driver.spawn`, returns false, start() returns early. No timer scheduled. | 191–202 |
| Binary not executable | Same as above (isExecutableFile check). | 198–200 |
| Lock already held (external process) | flock(LOCK_EX\|LOCK_NB) fails, logs `tmux.driver.skip`, fd closed, returns. | 256–260 |
| Lock already held (in-process guard) | isRunning check at line 239 short-circuits before open syscall. | 239–241 |
| Process spawn fails | Exception caught, `releaseRun()` called, fd released. | 320–324 |
| Self deallocated during termination | Captured fd (line 288) released anyway (lines 292–293). | 288–295 |
| Hung run (timeout) | scheduleHungRunTimeout() at line 319; timeout workitem calls proc.terminate() (line 335). | 329–339 |
| Lockfile dir missing | ensureLockfileDir() creates with intermediate dirs (lines 381–391). createDirectory errors logged as warnings (line 388), do not crash. | 246, 381–391 |
| stop() while idle | terminateInFlight() guards `isRunning` (line 362), returns if false. Safe no-op. | 152, 362 |
| start() called twice | isStarted guard (lines 148–149) prevents double init, timer, or double spawn. | 148–149 |
| refreshNow() while running | isRunning guard (line 177) returns early with skip log. | 177–180 |
| refreshNow() rapid calls | isRunning prevents all but first from spawning. In-process guard faster than lock syscall. | 239–241 |

All prompt-listed edge cases are handled correctly.

---

**Verdict: PASS**

All DW items satisfied with execution evidence. 100% test coverage. No defensive programming violations. Concurrency, error handling, resources, boundaries, and security all PASS. All edge cases handled. 17/17 tests passing.
