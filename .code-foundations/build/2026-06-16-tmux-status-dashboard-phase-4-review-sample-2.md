# Review: Phase 4 - TmuxStatusDriver

## Executed Results (Step 0)

- **Test suite**: `swift build && swift test`
  - Result: **64 tests passed** (17 TmuxStatusDriver tests + 47 others)
  - Duration: 8.644s
  - Status: ✓ PASS
- **Typecheck**: Swift compiler (no errors or warnings)
  - Status: ✓ PASS
- **Build**: `swift build`
  - Status: ✓ PASS (0.15s)

## Requirement Fulfillment

### DW-4.1

**PREMISE:** While a run holds the lock, a second attempt is skipped and logs `tmux.driver.skip` (single-instance proven).

**EVIDENCE:** TmuxStatusDriver.swift:256–261

**TRACE:** External process holds flock on lockfile → Driver calls `attemptRun()` → Line 256 calls `flock(fd, LOCK_EX | LOCK_NB)` → flock returns non-zero (EWOULDBLOCK) → Line 259 logs `tmux.driver.skip` with message "lock already held" → Line 258 closes fd → returns without spawning.

**VERDICT:** PASS
- Test: `test_DW_4_1_lock_held_second_attempt_skipped` (0.306s) — external lock held, spawnCount remains 0
- Test: `test_DW_4_1_two_drivers_same_lockfile_second_skips` (0.808s) — driver1 holds lock, driver2 refreshNow() is skipped
- Test: `test_flock_advisory_lock_excludes_second_fd` (0.001s) — POSIX flock semantics verified

### DW-4.2

**PREMISE:** `start()` performs an immediate run then repeats on the configured interval; `stop()` halts further runs and terminates any in-flight process.

**EVIDENCE:** TmuxStatusDriver.swift:145–171 (`start()` and `stop()` public API)

**TRACE:** 
- **start()** (lines 145–157): Line 148 guards isStarted (idempotent). Line 154 validates binary. Line 155 calls `attemptRun()` for immediate spawn. Line 156 schedules timer for repeating runs at config.interval.
- **stop()** (lines 162–171): Line 168 cancels timer. Line 169 calls `terminateInFlight()` which (a) terminates process (line 364), (b) closes lock fd immediately (line 370, releasing flock), (c) cancels timeout workitem (line 372), (d) resets isRunning to false (line 375).

**VERDICT:** PASS
- Test: `test_DW_4_2_start_runs_immediately` (0.506s) — spawnCount=1 within 0.5s of start()
- Test: `test_DW_4_2_start_is_idempotent` (0.505s) — calling start() twice produces 1 spawn
- Test: `test_DW_4_2_stop_terminates_inflight` (0.812s) — process running after start(), not running after stop()
- Test: `test_DW_4_2_stop_when_idle_is_safe` (0.001s) — no crash when stop() called on idle driver
- Test: `test_DW_4_2_timer_repeats` (1.103s) — 0.3s interval yields ≥2 spawns in 1.1s
- Test: `test_DW_4_2_stop_releases_lock_for_next_run` (0.510s) — after stop(), external flock can acquire lock

### DW-4.3

**PREMISE:** `refreshNow()` triggers an immediate run when idle and is a no-op while one is running.

**EVIDENCE:** TmuxStatusDriver.swift:174–184

**TRACE:** Line 177 checks `guard !self.isRunning else`. If isRunning=true, logs "run already in flight" at line 178 and returns (no-op). If isRunning=false, logs "tmux.driver.refresh" at line 181 and calls `attemptRun()` at line 182 (spawn triggered).

**VERDICT:** PASS
- Test: `test_DW_4_3_refresh_when_idle_spawns` (0.504s) — idle driver, refreshNow() spawns exactly 1
- Test: `test_DW_4_3_refresh_while_running_noop` (0.611s) — while run in flight, refreshNow() does not increment spawn count
- Test: `test_DW_4_3_rapid_refresh_deduplicates` (0.505s) — 5 rapid calls while first running = 1 spawn total

### DW-4.4

**PREMISE:** A missing/failed `claude` spawn is logged and does not crash or restart-storm.

**EVIDENCE:** TmuxStatusDriver.swift:191–202 (binary validation), 312–325 (spawn error handling)

**TRACE:** 
- **start() with missing binary**: Line 154 calls `validateBinary()`. Lines 194–195 check FileManager.fileExists(). If false, logs `err.tmux.driver.spawn` with "binary not found". Returns false. Line 155 `attemptRun()` is not called. Line 156 timer is not scheduled. No spawn, no restart-storm.
- **refreshNow() with missing binary**: No validateBinary() check (called only in start()). Line 268 calls `spawnProcess()`. Line 313 `proc.run()` throws. Caught at line 320, logs `err.tmux.driver.spawn`, calls `releaseRun(fd)`. No crash, isRunning reset to false.

**VERDICT:** PASS
- Test: `test_DW_4_4_missing_binary_logs_error_no_crash` (0.505s) — missing binary, spawnCount=0, no crash
- Test: `test_DW_4_4_refresh_missing_binary_no_crash` (0.506s) — refreshNow() with missing binary, isRunning=false after error
- Test: `test_DW_4_4_no_restart_storm_on_bad_binary` (0.506s) — validateBinary() blocks start(), no timer, no restart-storm

## Test-DW Coverage

| DW Item | Test(s) | Coverage | Status |
|---------|---------|----------|--------|
| DW-4.1 | test_DW_4_1_lock_held_second_attempt_skipped, test_DW_4_1_two_drivers_same_lockfile_second_skips | Automated | ✓ PASS |
| DW-4.2 | test_DW_4_2_start_runs_immediately, test_DW_4_2_start_is_idempotent, test_DW_4_2_stop_terminates_inflight, test_DW_4_2_stop_when_idle_is_safe, test_DW_4_2_timer_repeats, test_DW_4_2_stop_releases_lock_for_next_run | Automated | ✓ PASS |
| DW-4.3 | test_DW_4_3_refresh_when_idle_spawns, test_DW_4_3_refresh_while_running_noop, test_DW_4_3_rapid_refresh_deduplicates | Automated | ✓ PASS |
| DW-4.4 | test_DW_4_4_missing_binary_logs_error_no_crash, test_DW_4_4_refresh_missing_binary_no_crash, test_DW_4_4_no_restart_storm_on_bad_binary | Automated | ✓ PASS |

**Coverage Level:** 100% — All DW items have automated tests; all tests passed in Step 0.

## Dead Code

**Scan for unreachable code:**
- Line 154: `guard self.validateBinary() else { return }` — guard allows forward flow, no unreachable code
- Line 239: `guard !isRunning else { ... return }` — early return reachable, no dead code after
- Lines 291–310: Termination handler covers self-present and self-deallocated paths (lines 292–294, 305–306)
- Lines 320–324: Catch block always calls releaseRun, all paths reachable

**Result:** None found. ✓

## Correctness Dimensions

| Dimension | Status | Evidence |
|-----------|--------|----------|
| **Concurrency** | PASS | All mutable state (isRunning, lockFd, process, timer, timeoutWorkItem) protected by serial DispatchQueue (line 117). [weak self] in all closures (lines 146, 216, 290, 303, 330). Lock fd captured before async terminationHandler to prevent use-after-free. isRunning flag gates concurrent spawns. |
| **Error Handling** | PASS | Binary validation at entry (lines 191–202). Spawn failures caught and logged (lines 320–324). Flock contention logged as skip, not error (line 259). All error paths call releaseRun() to reset state. No silent failures; all errors logged to jlog with context data. |
| **Resources** | PASS | Lock fd lifecycle: opened (line 247), held via flock, closed on termination (line 350) or stop (line 370). Timer scheduled (line 220) and cancelled (line 228). Timeout workitem scheduled (line 337) and cancelled (line 345, 372). Process lifecycle managed via terminationHandler (lines 290–310). fd closed on self deallocation (lines 293, 306) to prevent fd leak. |
| **Boundaries** | PASS | Config interval clamped to min 1s (NotifyConfig.swift:208). Lock fd checked >= 0 before use (line 348). Process existence checked before access (line 332). spawn count incremented only when lock is held (line 266). |
| **Security** | PASS | Binary path is absolute constant (line 22). Arguments built as discrete array, never shell-interpolated (lines 35–49). repoDir used only as cwd, not interpolated into args (line 281). flock(LOCK_EX \| LOCK_NB) used correctly for advisory locking. No command injection vectors. Missing/failed spawn logged and does not restart-storm. |

## Notes (non-blocking)

1. **Test isolation**: Each test gets a unique temp lockfile via `_test_lockfilePath` (line 122) to avoid cross-test contention. Good defensive testing practice.

2. **Process termination**: Uses `proc.terminate()` (SIGTERM), not SIGKILL. This allows graceful shutdown; hung runs are killed after 300s timeout (lines 329–339).

3. **Lock fd management**: The design captures `lockFd` in the terminationHandler closure (line 288) to ensure it remains valid even if `self` is deallocated mid-run. This prevents use-after-free and fd leaks.

4. **Idempotency**: Both `start()` and `stop()` are idempotent (guards at lines 148, 165), safe for repeated calls.

5. **APOSD module depth**: The class successfully hides timer lifecycle, flock management, Process lifecycle, and timeout enforcement behind three simple public methods (start, stop, refreshNow). Callers need not understand advisory locking, dispatch queues, or fd management.

6. **Logging integration**: All events logged via `jlog()` with structured data (event code, pid, path, errno, etc.), enabling observability without exposing implementation details.

## Issues (if FAIL)

None. All DW items satisfied with execution evidence.

**Verdict: PASS** — All 4 DW requirements met; 100% test coverage; no security/concurrency defects; defensive programming checklist clear.
