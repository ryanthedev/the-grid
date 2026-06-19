# Discovery + Design: Phase 4 - Driver + flock mutex

## Files Found
- `grid-notify/Sources/GridNotify/ScriptManager.swift` — Process spawn/terminate pattern (exists)
- `grid-notify/Sources/GridNotify/NotifyConfig.swift` — `NotifyConfig.Tmux` struct (exists, complete)
- `grid-notify/Sources/GridNotify/NotificationFileWatcher.swift` — DispatchSource + fd + serial queue (exists)
- `grid-notify/Sources/GridNotify/XDG.swift` — stateHome path helper (exists)
- `.claude/skills/tmux-status/SKILL.md` — invocation recipe + lockfile path + notification names (exists)
- `grid-notify/Sources/GridNotify/TmuxStatusDriver.swift` — DOES NOT EXIST (to be created)
- `grid-notify/Tests/GridNotifyTests/` — AnimationEngineTests, NotificationStoreTests, TmuxDashboardTests, TmuxStatusTests (exist)

## Current State

P1–P3 are committed. 47 tests pass. The data layer (P2) and view layer (P3) are in place.
`NotifyConfig.Tmux` is complete with `enabled`, `interval` (clamped ≥1), `repoDir`, `model?`.
`TmuxDashboardViewModel.onRefreshRequested` is the P4→P5 seam (P5 wires the callback).
The real claude binary is confirmed at `/Users/r/.local/bin/claude` — a Mach-O arm64 executable.

## Gaps

None. All prerequisites are met. The file contract, config struct, and spawn pattern are well-established.

## Code Standards

Applied from `docs/code-standards.md`:
- `jlog` only — no `print`
- No inline trailing comments (comments on own line above code)
- `[weak self]` + `guard let self else { return }` in escaping closures
- Per-module `Error, LocalizedError` enum
- `_test_` prefix for test-only hooks
- Comments-first; `PascalCase.swift` per primary type
- XCTest, `test_DW_<phase>_<item>_<descriptor>` naming
- 3-5 targeted tests, prove the approach

## Test Infrastructure

XCTest in `grid-notify/Tests/GridNotifyTests/`. Run via `swift test` from the `grid-notify/` directory.
Test pattern: inject the injectable command builder; test flock by opening two fds to the same temp lockfile.
Tests must NOT spawn a real `claude` (use injectable stub with `/usr/bin/true`, `/bin/false`, `/bin/sleep`).

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|---------------|--------|------------|
| DW-4.1 | While a run holds the lock, a second attempt is skipped and logs `tmux.driver.skip` | COVERED | `test_DW_4_1_lock_held_second_attempt_skipped` — opens lockfile fd, acquires flock, calls `attemptRun()` on a second driver, asserts it returns without spawning + logs `tmux.driver.skip` |
| DW-4.2 | `start()` performs immediate run then repeats on interval; `stop()` halts and terminates in-flight | COVERED | `test_DW_4_2_start_runs_immediately`, `test_DW_4_2_stop_terminates_inflight` — use injectable `/bin/sleep 60` stub; assert first spawn within 0.5s; assert process terminated on stop() |
| DW-4.3 | `refreshNow()` triggers when idle; no-op while running | COVERED | `test_DW_4_3_refresh_when_idle_spawns`, `test_DW_4_3_refresh_while_running_noop` — count spawns with a counting stub |
| DW-4.4 | Missing/failed claude spawn is logged and does not crash or restart-storm | COVERED | `test_DW_4_4_missing_binary_logs_error_no_crash` — point the command builder at `/nonexistent/claude`; assert `err.tmux.driver.spawn` logged, driver still healthy, only 1 attempt per trigger |

**All items COVERED:** YES

## Design Decisions

### Interface (Deep Module — 3 public methods hiding timer + process + flock)

```swift
struct TmuxDriverCommand {
    let executable: URL
    let arguments: [String]
}

class TmuxStatusDriver {
    init(config: NotifyConfig.Tmux, command: TmuxDriverCommand = .claude(config:))
    func start()        // immediate run + interval timer
    func stop()         // cancel timer, terminate in-flight, release lock
    func refreshNow()   // immediate run if idle; no-op while running
    // _test_ hooks
    var _test_spawnCount: Int
    var _test_isRunning: Bool
}
```

**Design-It-Twice:** Three approaches were considered:
- A (chosen): injectable `TmuxDriverCommand` value type — simple to stub in tests, no protocol conformances, args array enforced at definition site
- B: `ProcessLauncher` protocol — adds interface ceremony for tests, no advantage over A
- C: test subclass hook — awkward in Swift (no `protected`), leaks implementation details

**Depth check:** 3 public methods hide timer lifecycle, fd management, `flock(2)` syscalls, `Process` spawn/terminate/timeout, serial queue. Common case (start/stop) requires zero knowledge of internals.

### Security: argument list
All arguments are constants defined at one call site (`TmuxDriverCommand.claudeDefault(repoDir:model:)`). `repoDir` goes to `process.currentDirectoryURL` only (never interpolated into an argument). `model` becomes a discrete `--model <value>` argument pair, never shell-interpolated.

### flock strategy
- Open lockfile at `XDG.stateHome + "/thegrid/tmux-status.lock"`, `O_CREAT | O_RDWR`, 0644
- `flock(fd, LOCK_EX | LOCK_NB)` before each spawn
- Hold fd for the spawned process's lifetime; close in terminationHandler (releases flock)
- In-process `isRunning: Bool` guards rapid `refreshNow()` without a syscall

### Timeout
Hung process kill timeout: 5 minutes (`hunglRunTimeout: TimeInterval = 300`). Enforced via a `DispatchWorkItem` scheduled at spawn; cancelled on normal termination.

### Queue
Single serial `DispatchQueue(label: "com.thegrid.notify.tmuxdriver")` protects `isRunning`, `lockFd`, `process`, timer — mirrors `ScriptManager` and `NotificationFileWatcher`.

## Prerequisites
- [x] `NotifyConfig.Tmux` exists with all required fields
- [x] `ScriptManager.swift` pattern available to mirror
- [x] `/Users/r/.local/bin/claude` confirmed as Mach-O arm64 executable
- [x] `jlog` available project-wide
- [x] XCTest infrastructure in place (47 tests passing)

## Recommendation
BUILD
