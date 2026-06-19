# Review: Phase 4 - Tmux Status Driver

## Executed Results (Step 0)

Command: `cd /Users/r/repos/theGrid/.claude/worktrees/tmux-status-dashboard/grid-notify && swift build && swift test`

Result: **All tests passed**
- Build: 0.15s, complete
- Test suite: 64 tests total, 17 TmuxStatusDriver tests
- Result: **0 failures, 0 unexpected**
- Duration: 8.718s total

Test names for TmuxStatusDriver phase 4 coverage:
- `test_DW_4_1_lock_held_second_attempt_skipped` ✓ (0.306s)
- `test_DW_4_1_two_drivers_same_lockfile_second_skips` ✓ (0.816s)
- `test_DW_4_2_start_runs_immediately` ✓ (0.505s)
- `test_DW_4_2_start_is_idempotent` ✓ (0.506s)
- `test_DW_4_2_stop_terminates_inflight` ✓ (0.808s)
- `test_DW_4_2_stop_when_idle_is_safe` ✓ (0.001s)
- `test_DW_4_2_timer_repeats` ✓ (1.106s)
- `test_DW_4_2_stop_releases_lock_for_next_run` ✓ (0.510s)
- `test_DW_4_3_refresh_when_idle_spawns` ✓ (0.506s)
- `test_DW_4_3_refresh_while_running_noop` ✓ (0.622s)
- `test_DW_4_3_rapid_refresh_deduplicates` ✓ (0.508s)
- `test_DW_4_4_missing_binary_logs_error_no_crash` ✓ (0.509s)
- `test_DW_4_4_refresh_missing_binary_no_crash` ✓ (0.511s)
- `test_DW_4_4_no_restart_storm_on_bad_binary` ✓ (0.505s)
- `test_claudeDefault_arguments_are_constants` ✓ (0.000s)
- `test_claudeDefault_with_model_adds_discrete_pair` ✓ (0.000s)
- `test_flock_advisory_lock_excludes_second_fd` ✓ (0.002s)

---

## Requirement Fulfillment

### DW-4.1

**PREMISE:** While a run holds the lock, a second attempt is skipped and logs `tmux.driver.skip` (single-instance proven).

**EVIDENCE:** 
- TmuxStatusDriver.swift:238–269 (attemptRun method)
- TmuxStatusDriver.swift:256–260 (flock failure handling)
- TmuxStatusDriver.swift:178–179 (in-process guard in refreshNow)
- TmuxStatusDriverTests.swift:68–86 (test_DW_4_1_lock_held_second_attempt_skipped)
- TmuxStatusDriverTests.swift:90–109 (test_DW_4_1_two_drivers_same_lockfile_second_skips)

**TRACE:**
1. **External flock test:** Process 1 opens lockfile, acquires `LOCK_EX|LOCK_NB`, holds fd open. Driver attempts run: `attemptRun()` calls `flock(fd, LOCK_EX|LOCK_NB)` → returns -1 (EWOULDBLOCK). Code logs `tmux.driver.skip` and closes the fd without marking `isRunning=true`. `_test_spawnCount` remains 0. ✓

2. **Two drivers test:** Driver1 spawns (sleep 10s), holds lock. Driver2 calls `refreshNow()` → goes to `attemptRun()` → calls `open()` and `flock(LOCK_EX|LOCK_NB)` → fails with errno=EWOULDBLOCK → logs `tmux.driver.skip` → closes fd → returns. `driver2._test_spawnCount` = 0; driver1._test_spawnCount = 1. ✓

**VERDICT:** **PASS**

Tests prove: (a) external lock contention is detected, (b) multiple drivers sharing a lockfile exclude each other, (c) `tmux.driver.skip` is logged on contention, (d) the flock operation is non-blocking and synchronous.

---

### DW-4.2

**PREMISE:** `start()` performs an immediate run then repeats on the configured interval; `stop()` halts further runs and terminates any in-flight process.

**EVIDENCE:**
- TmuxStatusDriver.swift:145–157 (start method)
- TmuxStatusDriver.swift:162–170 (stop method)
- TmuxStatusDriver.swift:209–223 (scheduleTimer method)
- TmuxStatusDriver.swift:227–230 (cancelTimer method)
- TmuxStatusDriver.swift:361–376 (terminateInFlight method)
- TmuxStatusDriverTests.swift:114–136 (lifecycle tests: immediate run, idempotence, timer repeats, stop)

**TRACE:**

1. **Immediate run:** `start()` queued async. Guards isStarted, logs "tmux.driver.start", calls `validateBinary()` (passes), calls `attemptRun()` which acquires lock, spawns process, increments `_test_spawnCount` to 1. Meanwhile, `scheduleTimer()` is called to schedule the next tick at `config.interval`. Test sleeps 0.5s; spawn count is 1. ✓

2. **Idempotence:** Two consecutive `start()` calls. First sets `isStarted = true` and proceeds. Second guard checks `!isStarted` → already true → returns immediately. Only 1 spawn attempt total over 0.5s. ✓

3. **Timer repeats:** Config interval = 0.3s. `start()` spawns immediately. Timer fires at 0.3s, 0.6s, 0.9s. Test duration 1.1s yields ≥2 spawns. Actual count ≥2. ✓

4. **Stop terminates in-flight:** `start()` with sleep 30s. After 0.5s, driver.`_test_isRunning` = true (process spawned and running). `stop()` queued async → sets `isStarted = false` → calls `cancelTimer()` (timer.cancel()) → calls `terminateInFlight()` which calls `proc.terminate()`, closes lockFd immediately, resets state. After 0.3s more, `_test_isRunning` = false. ✓

5. **Stop when idle:** `stop()` called with no running process. Guard `isRunning` fails immediately, no-op. No crash. ✓

6. **Stop releases lock:** Driver1 spawns sleep 10s, acquires lock. After 0.3s, lock fd is held by driver1's process. `stop()` closes lockFd immediately (line 370). External flock() call on the same file now succeeds with `LOCK_EX|LOCK_NB`. ✓

**VERDICT:** **PASS**

Tests prove: (a) start() runs immediately, (b) start() is idempotent, (c) timer fires at configured interval, (d) stop() terminates in-flight processes, (e) stop() is safe when idle, (f) lock is released synchronously on stop().

---

### DW-4.3

**PREMISE:** `refreshNow()` triggers an immediate run when idle and is a no-op while one is running.

**EVIDENCE:**
- TmuxStatusDriver.swift:173–183 (refreshNow method)
- TmuxStatusDriver.swift:177–179 (in-process isRunning guard)
- TmuxStatusDriverTests.swift:192–232 (DW-4.3 tests)

**TRACE:**

1. **Idle trigger:** `refreshNow()` called on idle driver. Guard `!isRunning` passes (isRunning = false). Logs "tmux.driver.refresh". Calls `attemptRun()` → acquires lock, spawns process, `_test_spawnCount` = 1. ✓

2. **Running no-op:** `refreshNow()` with sleep 5s process in flight. After 0.3s, isRunning = true. Second `refreshNow()` call → guard `!isRunning` fails → logs "tmux.driver.refresh.skip" → returns immediately. Spawn count unchanged from 1. ✓

3. **Rapid deduplication:** Five rapid `refreshNow()` calls on sleep 5s process. After 0.5s, first call spawned (count=1), remaining 4 calls hit the `isRunning` guard and returned. Total spawn count = 1. ✓

**VERDICT:** **PASS**

Tests prove: (a) refreshNow() runs immediately when idle, (b) refreshNow() skips while a process is in flight, (c) rapid calls are deduplicated by the in-process guard.

---

### DW-4.4

**PREMISE:** A missing/failed `claude` spawn is logged and does not crash or restart-storm.

**EVIDENCE:**
- TmuxStatusDriver.swift:191–203 (validateBinary method)
- TmuxStatusDriver.swift:194–200 (logging for missing/non-executable binary)
- TmuxStatusDriver.swift:312–325 (spawnProcess try-catch, error logging on spawn failure)
- TmuxStatusDriver.swift:154–157 (start() terminates early if validateBinary() returns false)
- TmuxStatusDriverTests.swift:236–275 (DW-4.4 tests)

**TRACE:**

1. **Missing binary via start():** `start()` with missingCommand (path: /nonexistent/no-such-binary). Queued on queue. `validateBinary()` checks `fm.fileExists(atPath: path)` → false → logs "err.tmux.driver.spawn" with msg "binary not found" → returns false. `start()` returns early; `scheduleTimer()` never called. Spawn count = 0. No restart-storm (timer not scheduled). ✓

2. **Missing binary via refreshNow():** `refreshNow()` with missingCommand. `attemptRun()` succeeds (no validation at this level), acquires lock, calls `spawnProcess()`. `proc.run()` throws (executable does not exist). Catch block logs "err.tmux.driver.spawn" with error string. Calls `releaseRun(fd: capturedFd)` which resets isRunning = false. No spawn count increment (spawnProcess doesn't increment on error). No crash. ✓

3. **No restart-storm:** Start with bad binary. Spawn count = 0 after 0.5s. Timer is not scheduled because `start()` returns early after `validateBinary()` returns false. Proof: spawn count stays at 0 over the full 0.5s window; if timer were scheduled, subsequent ticks would attempt spawns. ✓

**VERDICT:** **PASS**

Tests prove: (a) missing binary is detected and logged, (b) spawn failure doesn't crash, (c) no restart-storm occurs, (d) failed spawn is logged but does not cascade.

---

## Test-DW Coverage

All 4 DW items have corresponding automated test coverage:

| DW Item | Test Names | Coverage |
|---------|-----------|----------|
| DW-4.1  | test_DW_4_1_lock_held_second_attempt_skipped, test_DW_4_1_two_drivers_same_lockfile_second_skips | ✓ Ran (0.306s, 0.816s) |
| DW-4.2  | test_DW_4_2_start_runs_immediately, test_DW_4_2_start_is_idempotent, test_DW_4_2_timer_repeats, test_DW_4_2_stop_terminates_inflight, test_DW_4_2_stop_when_idle_is_safe, test_DW_4_2_stop_releases_lock_for_next_run | ✓ Ran (6x tests, total 3.738s) |
| DW-4.3  | test_DW_4_3_refresh_when_idle_spawns, test_DW_4_3_refresh_while_running_noop, test_DW_4_3_rapid_refresh_deduplicates | ✓ Ran (3x tests, total 1.636s) |
| DW-4.4  | test_DW_4_4_missing_binary_logs_error_no_crash, test_DW_4_4_refresh_missing_binary_no_crash, test_DW_4_4_no_restart_storm_on_bad_binary | ✓ Ran (3x tests, total 1.525s) |

**Coverage matches declared level (100%):** All 4 DW items have multiple dedicated automated tests, each exercising different facets.

---

## Dead Code

**Scan results:**

- No unreachable code after early returns.
- No debug statements or commented-out code.
- No empty catch blocks.
- Unused imports: None detected.

Test hooks (`_test_lockfilePath`, `_test_spawnCount`, `_test_isRunning`) are correctly scoped as test-only properties; they are never invoked in production paths.

**Verdict: None found**

---

## Correctness Dimensions

### Concurrency

**Status: PASS**

**Evidence:**

1. **Shared state protection:** All mutable state (isRunning, lockFd, process, timer, timeoutWorkItem, isStarted) is declared private and accessed only within closures dispatched to a private serial queue (`com.thegrid.notify.tmuxdriver`).

   - Public methods (start, stop, refreshNow) dispatch async closures to the queue.
   - Private methods (attemptRun, spawnProcess, scheduleTimer, etc.) run on the queue and are marked "Must be called on queue."
   - No mutations happen off-queue.

2. **Termination handler weak self:** Line 290 uses `[weak self]` in the Process terminationHandler closure. Even if self is deallocated, the closure captures the lockFd and releases it (lines 293, 305). No dangling references.

3. **Lock-free synchronization:** The `isRunning` bool short-circuits `refreshNow()` (line 177) without a syscall. It's protected by the serial queue dispatch, so reads and writes are sequential.

4. **Timeout work item:** Scheduled via `queue.asyncAfter()` (line 338). If self is deallocated before the timeout fires, the `[weak self]` guard (line 331) exits early. Work items are cancelled in `releaseRun()` (line 344) to prevent dangling timeouts.

**Defects demonstrated: None**

### Error Handling

**Status: PASS**

**Evidence:**

1. **Binary validation:** `validateBinary()` checks existence and executability before spawn (lines 194–200). Logs `err.tmux.driver.spawn` and returns false; caller can react (start() returns early).

2. **Lock acquisition failure:** `flock()` returns -1 on EWOULDBLOCK (line 256). Code logs `tmux.driver.skip` and closes the fd (line 258), then returns. No exception, no re-throw.

3. **Spawn failure:** `proc.run()` can throw on executable not found or permission issues (line 312). Catch block (lines 320–324) logs `err.tmux.driver.spawn` and calls `releaseRun()` to reset state. No swallowing; logging provides observability.

4. **Lockfile creation:** `ensureLockfileDir()` attempts to create parent directory. On error (line 386–390), logs `warn.tmux.driver.lockdir` and returns. Does not throw; the subsequent `open()` will fail gracefully or succeed.

5. **No empty catch blocks:** All catch blocks log and take corrective action (reset state, release locks).

**Defensive programming checklist (from checklists.md):**
- **EC-3** (No empty catch blocks): ✓ Spawn error is caught and logged with context.
- **GC-1** (Protect from bad input): ✓ Binary path is validated before spawn; lockfile path from config is used only as-is (not interpolated).
- **EH-2** (Considered alternatives): ✓ flock() is non-blocking; no retry-loop.

**Defects demonstrated: None**

### Resources

**Status: PASS**

**Evidence:**

1. **File descriptor management:**
   - `open()` returns fd (line 247). If flock fails, fd is closed immediately (line 258).
   - If flock succeeds, fd is stored in `lockFd` (line 264) and held for the process lifetime.
   - Termination handler closes `capturedFd` (lines 293, 305, 350).
   - `terminateInFlight()` closes `lockFd` immediately (line 370) and sets it to -1 (line 352).
   - Guard `if fd >= 0` before every close() call (lines 348, 370).

2. **Process management:**
   - Process is stored in `process` (line 314) and set to nil in `releaseRun()` (line 346).
   - `terminateInFlight()` calls `proc.terminate()` (line 364), then clears process = nil (line 374).
   - Termination handler ensures process reference is cleared (line 346).

3. **Timeout enforcement:**
   - Timeout work item is scheduled (line 338) and stored (line 337).
   - Timeout is cancelled in `releaseRun()` (line 344) before it can fire.
   - Timeout is also cancelled in `terminateInFlight()` (line 372).
   - No orphaned timeouts.

4. **Timer lifecycle:**
   - Timer is created and scheduled (line 210–220), stored in `timer` (line 221).
   - `cancelTimer()` calls `timer?.cancel()` and sets `timer = nil` (lines 228–229).
   - Called in `stop()` (line 168).
   - No dangling timer references.

5. **Lock semantics:** flock is advisory. When fd is closed, the lock is automatically released (line 349 comment). This is guaranteed by the OS.

**Defects demonstrated: None**

### Boundaries

**Status: PASS**

**Evidence:**

1. **Integer boundaries:** hungRunTimeout is 300 seconds (TimeInterval, valid unsigned range). Config.interval is clamped in NotifyConfig.Tmux to >= 1.0 (no zero/negative risk). Process exit codes are read safely via terminationReason enum.

2. **String boundaries:** Binary path from TmuxDriverCommand.claudeBinaryPath is a string literal (hardcoded, no buffer overflow). repoDir is passed as a URL(fileURLWithPath:) which is safe. Arguments are a [String] array built with hardcoded constants and at most one model string (discrete argv element, no shell interpolation).

3. **Collection boundaries:** arguments array is fixed-size or one element larger (if model is present). No out-of-bounds indexing.

4. **Optional handling:** process, timer, timeoutWorkItem, command are all safely unwrapped with guards or optional chaining.

**Defects demonstrated: None**

### Security

**Status: PASS**

**Evidence:**

1. **Command injection prevention:**
   - Binary path: hardcoded constant `/Users/r/.local/bin/claude` (line 22), not derived from config.
   - Arguments: fixed constant array (lines 35–44), never shell-interpolated.
   - Model override: added as a discrete argv pair `["--model", model]` (lines 42–44), not as a string concatenation.
   - No `/bin/sh -c` or shell execution; Process API spawns the binary directly.
   - Verification: test_claudeDefault_with_model_adds_discrete_pair (line 318) confirms model is a separate argv element, not interpolated.

2. **Path traversal prevention:**
   - lockfilePath: hardcoded default `XDG.stateHome/thegrid/tmux-status.lock` (line 103).
   - repoDir: passed from config, used as currentDirectoryURL. Not validated, but is a working directory (not a file read/write path), so traversal risk is low.
   - Lockfile directory creation: uses FileManager.createDirectory() safely (line 386).

3. **Process privilege control:**
   - qualityOfService = .utility (line 277): process runs at background priority, not elevated.
   - --permission-mode bypassPermissions (line 40) is explicitly set by this driver; it's intentional for the tmux-status skill.

4. **Input validation at barricade:**
   - Binary path is validated (exists, executable) before spawn (lines 194–200).
   - Config values (interval, repoDir, model) are passed from NotifyConfig.Tmux, which is parsed from config file by caller. This layer assumes the config has been loaded safely.
   - If model is nil, it's not added to arguments; if present, it's treated as a string literal.

**Defensive programming checklist items:**
- **SM-3** (Command injection / shell commands): ✓ No string concatenation; Process API with discrete args.
- **SO-1** (Malicious input): ✓ Binary path is hardcoded; args are constants or validated strings.
- **SO-4** (Error messages): ✓ Logs contain file paths and errno, safe for internal logs (no stack traces to user).

**Defects demonstrated: None**

---

## Notes (non-blocking)

1. **Weak self discipline:** Termination handler uses `[weak self]` correctly, with fallback fd cleanup. Consistent with defensive programming (no dangling refs).

2. **Lock fd -1 sentinel:** Uses -1 as "no lock held" state. Checked before every close() and guarded with `if fd >= 0`. Safe pattern.

3. **Logging granularity:** Separate logs for skip (in-process guard vs. lock contention), refresh request, driver start/stop, timer schedule. Good observability for debugging single-instance behavior.

4. **Test isolation:** Each test gets a unique temp lockfile via `makeTempLockfile()`. Prevents cross-test flock contention. Well-designed test architecture.

5. **APOSD principles (deep modules):**
   - **Interface size:** 3 public methods (start, stop, refreshNow) + 1 init. Small, cohesive API.
   - **Hidden information:** Timer lifecycle, flock mechanics, process spawning, timeout enforcement are all internal. Caller only calls start/stop/refreshNow.
   - **Common case:** `refreshNow()` while running → single in-process bool check, no syscall. Simple.
   - **Information hiding:** Caller does not know about queue, fd, or flock semantics; they're encapsulated.

6. **Code Complete defensive programming (cc-defensive-programming skill):**
   - GC-1: Binary is validated at entry (start()).
   - GC-2: Assertions are not present (Python-style assert would be out of scope for Swift runtime checks). Preconditions are documented in comments ("Must be called on queue").
   - GC-3: No assertions used for normal error handling (flock failure, spawn failure are error-handled, not asserted).
   - EH-1: Error-handling strategy is consistent: validate at boundaries (binary), catch at sources (spawn), log failures, reset state.
   - EH-3: Errors handled locally (releaseRun closes the fd immediately; spawn error resets isRunning).

---

## Issues

**No issues found.**

---

## Summary

All 4 DW items are implemented correctly and verified by passing automated tests. The code follows defensive programming principles:
- Binary existence/executability is validated before spawn.
- flock(LOCK_EX|LOCK_NB) provides single-instance guarantee without blocking.
- Process termination and lock release are synchronous on stop().
- Spawn failures are caught, logged, and do not cascade.
- All mutable state is protected by a serial queue; no race conditions.
- File descriptors and timeouts are cleaned up in all exit paths.
- Command construction is safe: no shell interpolation, no path traversal, discrete argv elements.

**All requirements met:** YES

---

**Verdict: PASS**

All 4 DW items have execution evidence from passing tests. No correctness defects detected. Error handling is consistent and observability is strong. Single-instance enforcement via flock is proven. Process lifecycle is correctly managed with resource cleanup in all paths.
