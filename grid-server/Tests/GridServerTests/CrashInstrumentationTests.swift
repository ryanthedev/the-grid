import XCTest
@testable import GridServer

/// Subprocess-based tests for crash-exit instrumentation.
///
/// Each test spawns the built grid-server binary with:
///   - HOME overridden to a temp dir so log writes land in an isolated file
///   - a unique --socket path to avoid collision with a real running server
///   - a --crash-test mode that triggers the relevant fault path after
///     crash reporter install
///
/// We then read the isolated log file and assert the expected lines are present.
final class CrashInstrumentationTests: XCTestCase {

    // MARK: - Helpers

    /// Path to the built grid-server binary. Tests require `swift build` to have
    /// produced it at the standard SwiftPM location relative to Package root.
    private func grigdServerPath() -> String {
        // Walk up from the test bundle to find the package root's .build dir.
        // In practice `swift test` builds the main target first, so debug/ is fresh.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CrashInstrumentationTests.swift's dir
            .deletingLastPathComponent() // GridServerTests
            .deletingLastPathComponent() // Tests
        let candidates = [
            packageRoot.appendingPathComponent(".build/debug/grid-server").path,
            packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/grid-server").path,
            packageRoot.appendingPathComponent(".build/x86_64-apple-macosx/debug/grid-server").path,
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return c
        }
        XCTFail("grid-server binary not found; expected one of: \(candidates)")
        return candidates[0]
    }

    /// Spawn grid-server in an isolated HOME with the given args. Returns the
    /// temp dir (caller reads log file from there) and the exit status.
    @discardableResult
    private func runIsolated(args: [String], timeout: TimeInterval = 10.0) throws -> (tmpHome: URL, status: Int32) {
        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grid-crash-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: grigdServerPath())
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        // CFFIXED_USER_HOME overrides FileManager.homeDirectoryForCurrentUser on
        // macOS, which is what JSONLogger uses to build its log path. $HOME alone
        // does not redirect — the home dir is resolved from the passwd record.
        env["CFFIXED_USER_HOME"] = tmpHome.path
        env["HOME"] = tmpHome.path
        proc.environment = env
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()

        try proc.run()

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if proc.isRunning {
            proc.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            XCTFail("grid-server did not exit within \(timeout)s for args \(args)")
        }

        return (tmpHome, proc.terminationStatus)
    }

    /// Read the log file that grid-server wrote under the isolated HOME.
    private func readLog(tmpHome: URL) -> String {
        let logPath = tmpHome.appendingPathComponent(".local/state/thegrid/thegrid-server.json").path
        return (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
    }

    /// Pick a unique tmp socket path so tests don't collide with each other or
    /// a running server.
    private func uniqueSocket() -> String {
        return "/tmp/grid-crash-test-\(UUID().uuidString.prefix(8)).sock"
    }

    // MARK: - DW-1.1

    func test_DW_1_1_SIGSEGV_writes_srv_fatal() throws {
        let (tmp, status) = try runIsolated(args: [
            "--socket-path", uniqueSocket(),
            "--crash-test", "SIGSEGV",
        ])

        // SIGSEGV handler calls _exit(128+11) = 139.
        XCTAssertEqual(status, 128 + SIGSEGV, "unexpected exit status: \(status)")

        let log = readLog(tmpHome: tmp)
        XCTAssertTrue(log.contains("\"ev\":\"srv.fatal\""), "missing srv.fatal in log:\n\(log)")
        XCTAssertTrue(log.contains("\"sig\":\"SIGSEGV\""), "missing SIGSEGV sig in log:\n\(log)")
        XCTAssertTrue(log.contains("\"pid\":"), "missing pid in log:\n\(log)")
        XCTAssertTrue(log.contains("\"uptime\":"), "missing uptime in log:\n\(log)")
    }

    // MARK: - DW-1.2

    func test_DW_1_2_SIGABRT_writes_srv_fatal() throws {
        let (tmp, status) = try runIsolated(args: [
            "--socket-path", uniqueSocket(),
            "--crash-test", "SIGABRT",
        ])

        XCTAssertEqual(status, 128 + SIGABRT, "unexpected exit status: \(status)")
        let log = readLog(tmpHome: tmp)
        XCTAssertTrue(log.contains("\"ev\":\"srv.fatal\""), "missing srv.fatal in log:\n\(log)")
        XCTAssertTrue(log.contains("\"sig\":\"SIGABRT\""), "missing SIGABRT sig in log:\n\(log)")
    }

    // MARK: - DW-1.3

    func test_DW_1_3_uncaught_exception_writes_srv_fatal_exception() throws {
        let (tmp, _) = try runIsolated(args: [
            "--socket-path", uniqueSocket(),
            "--crash-test", "NSException",
        ], timeout: 15.0)
        // ObjC uncaught terminates via abort() after running our handler, so
        // the exit status is not deterministic across macOS versions. We only
        // assert the log content.
        let log = readLog(tmpHome: tmp)
        XCTAssertTrue(log.contains("\"ev\":\"srv.fatal.exception\""),
                      "missing srv.fatal.exception in log:\n\(log)")
        XCTAssertTrue(log.contains("\"name\":\"CrashTestException\""),
                      "missing exception name in log:\n\(log)")
        XCTAssertTrue(log.contains("\"reason\":\"synthetic\""),
                      "missing exception reason in log:\n\(log)")
    }

    // MARK: - DW-1.5 (no regression + prev_exit classification)

    func test_DW_1_5_graceful_shutdown_emits_done_and_next_run_sees_graceful() throws {
        // Run 1: exit cleanly via the test-only exit-after-startlog mode, which
        // writes srv.shutdown.done on the graceful path.
        let (tmp, status1) = try runIsolated(args: [
            "--socket-path", uniqueSocket(),
            "--crash-test", "exit-after-startlog",
        ])
        XCTAssertEqual(status1, 0, "run 1 did not exit cleanly: \(status1)")
        let log1 = readLog(tmpHome: tmp)
        XCTAssertTrue(log1.contains("\"ev\":\"srv.shutdown.done\""),
                      "run 1 missing srv.shutdown.done:\n\(log1)")
        XCTAssertTrue(log1.contains("\"ev\":\"srv.atexit\""),
                      "run 1 missing srv.atexit (atexit hook):\n\(log1)")

        // Run 2: start a second server against the SAME tmp HOME, so it reads
        // run 1's tail from the log. It should classify prev_exit=graceful
        // before writing its own srv.start. We again use exit-after-startlog
        // so the test doesn't hang; the prev_exit line is written by install
        // path which runs before the crash-test branch.
        let proc2 = Process()
        proc2.executableURL = URL(fileURLWithPath: grigdServerPath())
        proc2.arguments = [
            "--socket-path", uniqueSocket(),
            "--crash-test", "exit-after-startlog",
        ]
        var env = ProcessInfo.processInfo.environment
        env["CFFIXED_USER_HOME"] = tmp.path
        env["HOME"] = tmp.path
        proc2.environment = env
        proc2.standardOutput = Pipe()
        proc2.standardError = Pipe()
        try proc2.run()
        let deadline = Date().addingTimeInterval(10.0)
        while proc2.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if proc2.isRunning { proc2.terminate(); XCTFail("run 2 hung") }

        let log2 = readLog(tmpHome: tmp)
        // Find the last srv.prev_exit line — that's run 2's classification.
        let lastPrevExit = log2.components(separatedBy: "\n")
            .last(where: { $0.contains("\"ev\":\"srv.prev_exit\"") })
        XCTAssertNotNil(lastPrevExit, "run 2 did not emit srv.prev_exit:\n\(log2)")
        XCTAssertTrue(lastPrevExit?.contains("\"exit\":\"graceful\"") ?? false,
                      "run 2 did not classify previous exit as graceful; line: \(lastPrevExit ?? "nil")\nfull log:\n\(log2)")
    }

    // Bonus: verify fatal path also classifies correctly on the next run.
    func test_DW_1_4_fatal_run_then_next_run_classifies_fatal() throws {
        let (tmp, _) = try runIsolated(args: [
            "--socket-path", uniqueSocket(),
            "--crash-test", "SIGSEGV",
        ])
        // Now a second run in the same HOME should see prev_exit=fatal.
        let proc2 = Process()
        proc2.executableURL = URL(fileURLWithPath: grigdServerPath())
        proc2.arguments = [
            "--socket-path", uniqueSocket(),
            "--crash-test", "exit-after-startlog",
        ]
        var env = ProcessInfo.processInfo.environment
        env["CFFIXED_USER_HOME"] = tmp.path
        env["HOME"] = tmp.path
        proc2.environment = env
        proc2.standardOutput = Pipe()
        proc2.standardError = Pipe()
        try proc2.run()
        let deadline = Date().addingTimeInterval(10.0)
        while proc2.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if proc2.isRunning { proc2.terminate(); XCTFail("run 2 hung") }

        let log = readLog(tmpHome: tmp)
        let lastPrevExit = log.components(separatedBy: "\n")
            .last(where: { $0.contains("\"ev\":\"srv.prev_exit\"") })
        XCTAssertNotNil(lastPrevExit)
        XCTAssertTrue(lastPrevExit?.contains("\"exit\":\"fatal\"") ?? false,
                      "expected prev_exit=fatal after SIGSEGV; got: \(lastPrevExit ?? "nil")\nlog:\n\(log)")
    }
}
