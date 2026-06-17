import XCTest
@testable import GridNotify

// Tests for TmuxStatusDriver — Phase 4 done-when items.
//
// Strategy:
//   - All tests use injectable TmuxDriverCommand stubs (/usr/bin/true, /bin/sleep, etc.)
//   - Each test gets a unique temp lockfile via _test_lockfilePath to avoid cross-test
//     flock contention on the global tmux-status.lock.
//   - No real claude process is spawned in any test.
//   - _test_spawnCount tracks how many times a spawn was attempted.
final class TmuxStatusDriverTests: XCTestCase {

    // MARK: - Helpers

    // Creates a unique temp lockfile for test isolation.
    private func makeTempLockfile() -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("driver-test-\(UUID().uuidString).lock")
            .path
        FileManager.default.createFile(atPath: path, contents: nil)
        return path
    }

    private func makeConfig(
        interval: TimeInterval = 60,
        repoDir: String = "/tmp",
        model: String? = nil
    ) -> NotifyConfig.Tmux {
        NotifyConfig.Tmux(enabled: true, interval: interval, repoDir: repoDir, model: model)
    }

    // Builds a driver wired to a unique temp lockfile + injectable command.
    private func makeDriver(
        config: NotifyConfig.Tmux? = nil,
        command: TmuxDriverCommand,
        lockfile: String? = nil
    ) -> TmuxStatusDriver {
        let cfg = config ?? makeConfig()
        let d = TmuxStatusDriver(config: cfg, command: command)
        d._test_lockfilePath = lockfile ?? makeTempLockfile()
        return d
    }

    // Command stubs.
    private var trueCommand: TmuxDriverCommand {
        TmuxDriverCommand(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
    }

    private func sleepCommand(seconds: Int = 30) -> TmuxDriverCommand {
        TmuxDriverCommand(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["\(seconds)"]
        )
    }

    private var missingCommand: TmuxDriverCommand {
        TmuxDriverCommand(
            executable: URL(fileURLWithPath: "/nonexistent/no-such-binary"),
            arguments: []
        )
    }

    // MARK: - DW-4.1: flock single-instance proof

    // DW-4.1: When an external flock holds the lockfile, the driver skips the run
    // (spawnCount stays 0).
    func test_DW_4_1_lock_held_second_attempt_skipped() throws {
        let lockPath = makeTempLockfile()
        defer { try? FileManager.default.removeItem(atPath: lockPath) }

        // Simulate another process holding the lock.
        let externalFd = open(lockPath, O_RDWR)
        XCTAssertGreaterThanOrEqual(externalFd, 0, "Could not open test lockfile")
        defer { close(externalFd) }
        XCTAssertEqual(flock(externalFd, LOCK_EX | LOCK_NB), 0, "Could not acquire external lock")

        // Driver pointed at the same (locked) file.
        let driver = makeDriver(command: trueCommand, lockfile: lockPath)

        driver.refreshNow()
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertEqual(driver._test_spawnCount, 0,
            "Expected 0 spawns: lock is held by another fd")
    }

    // DW-4.1: Verify the skip-and-log path via two drivers sharing a lockfile.
    // First driver (with sleep) holds the lock; second driver's refreshNow is a no-op.
    func test_DW_4_1_two_drivers_same_lockfile_second_skips() throws {
        let lockPath = makeTempLockfile()
        defer { try? FileManager.default.removeItem(atPath: lockPath) }

        let driver1 = makeDriver(command: sleepCommand(seconds: 10), lockfile: lockPath)
        let driver2 = makeDriver(command: trueCommand, lockfile: lockPath)

        // driver1 acquires the lock.
        driver1.refreshNow()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(driver1._test_spawnCount, 1, "driver1 should have spawned")

        // driver2 attempts to acquire the same lock — should be skipped.
        driver2.refreshNow()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(driver2._test_spawnCount, 0, "driver2 should be skipped (lock held)")

        driver1.stop()
        Thread.sleep(forTimeInterval: 0.2)
    }

    // MARK: - DW-4.2: start/stop lifecycle

    // DW-4.2a: start() spawns immediately (within a short timeout).
    func test_DW_4_2_start_runs_immediately() throws {
        let driver = makeDriver(command: trueCommand)

        driver.start()
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertEqual(driver._test_spawnCount, 1,
            "Expected 1 spawn immediately after start()")
        driver.stop()
    }

    // DW-4.2b: start() is idempotent — calling twice must not double-spawn.
    func test_DW_4_2_start_is_idempotent() throws {
        let driver = makeDriver(command: trueCommand)

        driver.start()
        driver.start()
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertEqual(driver._test_spawnCount, 1,
            "Calling start() twice must not produce more than 1 initial spawn")
        driver.stop()
    }

    // DW-4.2c: stop() terminates an in-flight process.
    func test_DW_4_2_stop_terminates_inflight() throws {
        let driver = makeDriver(command: sleepCommand(seconds: 30))

        driver.start()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(driver._test_isRunning, "Should be running after start()")

        driver.stop()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(driver._test_isRunning, "Should not be running after stop()")
    }

    // DW-4.2d: stop() when idle is safe (no crash, no runaway).
    func test_DW_4_2_stop_when_idle_is_safe() throws {
        let driver = makeDriver(command: trueCommand)
        driver.stop()
        XCTAssertFalse(driver._test_isRunning)
    }

    // DW-4.2e: timer fires repeating runs. 0.3s interval → ≥2 spawns in 1.1s.
    func test_DW_4_2_timer_repeats() throws {
        let config = makeConfig(interval: 0.3)
        let driver = makeDriver(config: config, command: trueCommand)

        driver.start()
        Thread.sleep(forTimeInterval: 1.1)
        driver.stop()

        XCTAssertGreaterThanOrEqual(driver._test_spawnCount, 2,
            "Expected >= 2 spawns (immediate + >= 1 timer tick) over 1.1s at 0.3s interval")
    }

    // DW-4.2f: stop() while a run is in flight releases the lock (next run can acquire it).
    func test_DW_4_2_stop_releases_lock_for_next_run() throws {
        let lockPath = makeTempLockfile()
        defer { try? FileManager.default.removeItem(atPath: lockPath) }

        let driver = makeDriver(command: sleepCommand(seconds: 10), lockfile: lockPath)
        driver.start()
        Thread.sleep(forTimeInterval: 0.3)

        driver.stop()
        Thread.sleep(forTimeInterval: 0.2)

        // Verify the lock is now free (we can acquire it externally).
        let fd = open(lockPath, O_RDWR)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0,
            "Lock should be released after stop()")
    }

    // MARK: - DW-4.3: refreshNow

    // DW-4.3a: refreshNow() while idle triggers one run.
    func test_DW_4_3_refresh_when_idle_spawns() throws {
        let driver = makeDriver(command: trueCommand)

        driver.refreshNow()
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertEqual(driver._test_spawnCount, 1,
            "refreshNow() while idle should spawn exactly 1 run")
    }

    // DW-4.3b: refreshNow() while a run is in flight is a no-op.
    func test_DW_4_3_refresh_while_running_noop() throws {
        let driver = makeDriver(command: sleepCommand(seconds: 10))

        driver.refreshNow()
        Thread.sleep(forTimeInterval: 0.3)

        let countAfterFirst = driver._test_spawnCount
        XCTAssertEqual(countAfterFirst, 1, "First refreshNow should spawn once")
        XCTAssertTrue(driver._test_isRunning, "Driver should be running after first refresh")

        driver.refreshNow()
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertEqual(driver._test_spawnCount, countAfterFirst,
            "refreshNow() while running should be a no-op (spawn count unchanged)")
        driver.stop()
    }

    // DW-4.3c: rapid refreshNow() calls while first is in-flight — only 1 spawn total.
    func test_DW_4_3_rapid_refresh_deduplicates() throws {
        let driver = makeDriver(command: sleepCommand(seconds: 5))

        for _ in 0..<5 { driver.refreshNow() }
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertEqual(driver._test_spawnCount, 1,
            "Rapid refreshNow() calls should result in exactly 1 spawn")
        driver.stop()
    }

    // MARK: - DW-4.4: missing/failed binary

    // DW-4.4a: start() with missing binary logs the error; no spawn, no crash.
    func test_DW_4_4_missing_binary_logs_error_no_crash() throws {
        let driver = makeDriver(command: missingCommand)

        driver.start()
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertEqual(driver._test_spawnCount, 0,
            "Missing binary should result in 0 spawns (validateBinary blocks)")
        XCTAssertFalse(driver._test_isRunning,
            "isRunning must be false when binary is missing")
        driver.stop()
    }

    // DW-4.4b: refreshNow() with missing binary also doesn't crash.
    // refreshNow() skips validateBinary (that's start()-only), so the error
    // surfaces through Process.run() failing in spawnProcess.
    func test_DW_4_4_refresh_missing_binary_no_crash() throws {
        let driver = makeDriver(command: missingCommand)

        driver.refreshNow()
        Thread.sleep(forTimeInterval: 0.5)

        // Process.run() throws → releaseRun is called → isRunning = false.
        XCTAssertFalse(driver._test_isRunning,
            "isRunning must be false after a failed spawn via refreshNow()")
    }

    // DW-4.4c: start() must not restart-storm — assert at most 1 spawn attempt per call.
    func test_DW_4_4_no_restart_storm_on_bad_binary() throws {
        let driver = makeDriver(command: missingCommand)

        driver.start()
        Thread.sleep(forTimeInterval: 0.5)

        // validateBinary() blocks once; timer is not scheduled because start() returns early.
        XCTAssertEqual(driver._test_spawnCount, 0,
            "Should be 0 spawns — no restart-storm")
        driver.stop()
    }

    // MARK: - Additional: flock POSIX semantics (the lock the driver relies on)

    // Verify LOCK_EX|LOCK_NB excludes a second fd from the same file.
    func test_flock_advisory_lock_excludes_second_fd() throws {
        let path = makeTempLockfile()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let fd1 = open(path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd1, 0)
        defer { close(fd1) }

        let fd2 = open(path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd2, 0)
        defer { close(fd2) }

        XCTAssertEqual(flock(fd1, LOCK_EX | LOCK_NB), 0, "First lock should succeed")

        let result = flock(fd2, LOCK_EX | LOCK_NB)
        XCTAssertNotEqual(result, 0, "Second lock should fail")
        XCTAssertEqual(errno, EWOULDBLOCK, "errno should be EWOULDBLOCK")

        // Closing fd1 releases the lock; a fresh fd3 should succeed.
        close(fd1)
        let fd3 = open(path, O_RDWR)
        defer { close(fd3) }
        XCTAssertEqual(flock(fd3, LOCK_EX | LOCK_NB), 0,
            "Lock should be acquirable after holder closes fd")
    }

    // MARK: - Additional: TmuxDriverCommand constant validation

    func test_claudeDefault_arguments_are_constants() {
        let cmd = TmuxDriverCommand.claudeDefault()
        XCTAssertEqual(cmd.executable.path, TmuxDriverCommand.claudeBinaryPath)
        XCTAssertTrue(cmd.arguments.contains("-p"), "Must include -p flag")
        XCTAssertTrue(cmd.arguments.contains("/tmux-status"), "Must include /tmux-status prompt")
        XCTAssertTrue(cmd.arguments.contains("--permission-mode"), "Must include permission mode")
        XCTAssertTrue(cmd.arguments.contains("bypassPermissions"))
        XCTAssertFalse(cmd.arguments.contains("--model"), "No --model when model is nil")
    }

    func test_claudeDefault_with_model_adds_discrete_pair() {
        let cmd = TmuxDriverCommand.claudeDefault(model: "claude-sonnet-4-5")
        let args = cmd.arguments
        guard let idx = args.firstIndex(of: "--model") else {
            XCTFail("--model flag not found in arguments")
            return
        }
        XCTAssertLessThan(idx + 1, args.count, "--model must be followed by a value")
        XCTAssertEqual(args[idx + 1], "claude-sonnet-4-5",
            "--model value must be a discrete argv element")
    }
}
