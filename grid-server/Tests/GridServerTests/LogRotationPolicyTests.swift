import XCTest

@testable import GridServer

// Rotation tests for the JSONL server log.
//
// The server shipped with no rotation of any kind — thegrid-server.json
// reached 411 MB on the dev machine. These cover the size decision, the
// rename sequence, and the env knobs; the on-disk test drives the real
// FileManager path against a temp directory.
final class LogRotationPolicyTests: XCTestCase {

    // MARK: - shouldRotate

    func test_shouldRotate_whenBatchWouldCrossCeiling() {
        XCTAssertTrue(
            LogRotationPolicy.shouldRotate(currentBytes: 900, incomingBytes: 200, maxBytes: 1000)
        )
    }

    func test_shouldRotate_notWhenBatchFits() {
        XCTAssertFalse(
            LogRotationPolicy.shouldRotate(currentBytes: 700, incomingBytes: 200, maxBytes: 1000)
        )
    }

    // Exactly at the ceiling is still under it; the write lands and the next
    // batch rotates.
    func test_shouldRotate_notWhenBatchLandsExactlyOnCeiling() {
        XCTAssertFalse(
            LogRotationPolicy.shouldRotate(currentBytes: 800, incomingBytes: 200, maxBytes: 1000)
        )
    }

    // An empty file must never rotate. Without this guard a single batch larger
    // than maxBytes rotates on every write, shifting the archive chain each
    // time until every archive is empty and nothing was ever stored.
    func test_shouldRotate_neverOnEmptyFileEvenWhenBatchExceedsCeiling() {
        XCTAssertFalse(
            LogRotationPolicy.shouldRotate(currentBytes: 0, incomingBytes: 50_000, maxBytes: 1000)
        )
    }

    func test_shouldRotate_disabledWhenMaxBytesIsZeroOrNegative() {
        XCTAssertFalse(
            LogRotationPolicy.shouldRotate(currentBytes: 10_000, incomingBytes: 1, maxBytes: 0)
        )
        XCTAssertFalse(
            LogRotationPolicy.shouldRotate(currentBytes: 10_000, incomingBytes: 1, maxBytes: -1)
        )
    }

    // MARK: - rotationRenames

    // Oldest first, so no rename clobbers a file a later rename still needs.
    func test_rotationRenames_shiftChainOldestFirst() {
        let renames = LogRotationPolicy.rotationRenames(base: "/l/app.json", keep: 3)
        XCTAssertEqual(renames.count, 3)
        XCTAssertEqual(renames[0].from, "/l/app.json.2")
        XCTAssertEqual(renames[0].to, "/l/app.json.3")
        XCTAssertEqual(renames[1].from, "/l/app.json.1")
        XCTAssertEqual(renames[1].to, "/l/app.json.2")
        XCTAssertEqual(renames[2].from, "/l/app.json")
        XCTAssertEqual(renames[2].to, "/l/app.json.1")
    }

    func test_rotationRenames_keepOneJustArchivesTheLiveFile() {
        let renames = LogRotationPolicy.rotationRenames(base: "/l/app.json", keep: 1)
        XCTAssertEqual(renames.count, 1)
        XCTAssertEqual(renames[0].from, "/l/app.json")
        XCTAssertEqual(renames[0].to, "/l/app.json.1")
    }

    func test_rotationRenames_emptyWhenKeepIsZeroOrNegative() {
        XCTAssertTrue(LogRotationPolicy.rotationRenames(base: "/l/app.json", keep: 0).isEmpty)
        XCTAssertTrue(LogRotationPolicy.rotationRenames(base: "/l/app.json", keep: -2).isEmpty)
    }

    // No rename may point at the file another rename is about to write, and no
    // target may exceed the archive count the caller pre-deletes.
    func test_rotationRenames_targetsStayWithinKeep() {
        let keep = 5
        let renames = LogRotationPolicy.rotationRenames(base: "/l/app.json", keep: keep)
        for rename in renames {
            XCTAssertNotEqual(rename.to, "/l/app.json.\(keep + 1)")
        }
        XCTAssertEqual(renames.first?.to, "/l/app.json.\(keep)")
    }

    // MARK: - performRotation (real filesystem)

    func test_performRotation_shiftsArchivesAndDropsTheOldest() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let base = dir.appendingPathComponent("app.json").path
        try "live".write(toFile: base, atomically: true, encoding: .utf8)
        try "one".write(toFile: "\(base).1", atomically: true, encoding: .utf8)
        try "two".write(toFile: "\(base).2", atomically: true, encoding: .utf8)

        LogRotationPolicy.performRotation(base: base, keep: 2)

        XCTAssertFalse(FileManager.default.fileExists(atPath: base), "live file moved aside")
        XCTAssertEqual(try String(contentsOfFile: "\(base).1", encoding: .utf8), "live")
        XCTAssertEqual(try String(contentsOfFile: "\(base).2", encoding: .utf8), "one")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: "\(base).3"),
            "keep=2 must not grow a third archive"
        )
    }

    // A gap in the chain (no .1 yet) must not abort the rest of the sequence.
    func test_performRotation_toleratesMissingArchives() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let base = dir.appendingPathComponent("app.json").path
        try "live".write(toFile: base, atomically: true, encoding: .utf8)

        LogRotationPolicy.performRotation(base: base, keep: 3)

        XCTAssertEqual(try String(contentsOfFile: "\(base).1", encoding: .utf8), "live")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base))
    }

    func test_performRotation_keepZeroDiscardsWithoutArchiving() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let base = dir.appendingPathComponent("app.json").path
        try "live".write(toFile: base, atomically: true, encoding: .utf8)

        LogRotationPolicy.performRotation(base: base, keep: 0)

        XCTAssertFalse(FileManager.default.fileExists(atPath: base))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(base).1"))
    }

    // Repeated rotation must stay bounded at keep + 1 files.
    func test_performRotation_boundsFileCountAcrossManyRotations() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let base = dir.appendingPathComponent("app.json").path
        for i in 0..<10 {
            try "batch\(i)".write(toFile: base, atomically: true, encoding: .utf8)
            LogRotationPolicy.performRotation(base: base, keep: 3)
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 3, "keep=3 archives, live file consumed: \(files)")
        XCTAssertEqual(try String(contentsOfFile: "\(base).1", encoding: .utf8), "batch9")
        XCTAssertEqual(try String(contentsOfFile: "\(base).3", encoding: .utf8), "batch7")
    }

    // MARK: - JSONLogWriter wiring (real writes, temp file)

    // End-to-end: the writer must actually rotate on the batch path, not just
    // own a policy that could. Drives a writer against a temp file rather than
    // the shared singleton so the real server log is never touched.
    func test_writer_rotatesLiveLogAndAnnouncesItInTheFreshFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let base = dir.appendingPathComponent("srv.json").path
        let writer = JSONLogWriter(filePath: base, maxBytes: 400, keep: 2)

        // ~64 bytes per line; 20 lines crosses 400 bytes several times over.
        for i in 0..<20 {
            writer.enqueue("{\"ev\":\"test.event\",\"data\":{\"i\":\(i),\"pad\":\"\(String(repeating: "x", count: 30))\"}}")
            writer.flushSync()
        }

        let live = try String(contentsOfFile: base, encoding: .utf8)
        XCTAssertTrue(live.contains("\"ev\":\"log.rotate\""), "fresh file explains the gap: \(live)")
        XCTAssertLessThanOrEqual(live.utf8.count, 400 + 200, "live file stays near its ceiling")

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(base).1"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(base).2"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: "\(base).3"),
            "keep=2 bounds the chain"
        )
    }

    func test_writer_neverRotatesWhenDisabled() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let base = dir.appendingPathComponent("srv.json").path
        let writer = JSONLogWriter(filePath: base, maxBytes: 0, keep: 2)

        for i in 0..<20 {
            writer.enqueue("{\"ev\":\"test.event\",\"data\":{\"i\":\(i)}}")
            writer.flushSync()
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(base).1"))
        let live = try String(contentsOfFile: base, encoding: .utf8)
        XCTAssertEqual(live.split(separator: "\n").count, 20)
    }

    // MARK: - resolveLogPath
    //
    // Regression guard: before this, `swift test` appended to the real server
    // log, and after rotation landed a test run rotated the user's live 411 MB
    // log out from under the running server.

    func test_resolveLogPath_underTestsGoesToTempNotStateHome() {
        let path = JSONLogWriter.resolveLogPath(
            stateHome: "/Users/r/.local/state",
            environment: [:],
            xctestLoaded: true,
            temporaryDirectory: "/var/tmp/"
        )
        XCTAssertFalse(path.contains("/.local/state"), "must not touch the real log: \(path)")
        XCTAssertEqual(path, "/var/tmp/thegrid-tests/thegrid-server.json")
    }

    func test_resolveLogPath_inProductionUsesStateHome() {
        XCTAssertEqual(
            JSONLogWriter.resolveLogPath(
                stateHome: "/Users/r/.local/state",
                environment: [:],
                xctestLoaded: false,
                temporaryDirectory: "/var/tmp/"
            ),
            "/Users/r/.local/state/thegrid/thegrid-server.json"
        )
    }

    func test_resolveLogPath_explicitOverrideWinsOverBoth() {
        for loaded in [true, false] {
            XCTAssertEqual(
                JSONLogWriter.resolveLogPath(
                    stateHome: "/Users/r/.local/state",
                    environment: ["THEGRID_LOG_PATH": "/somewhere/else.json"],
                    xctestLoaded: loaded,
                    temporaryDirectory: "/var/tmp/"
                ),
                "/somewhere/else.json"
            )
        }
    }

    func test_resolveLogPath_emptyOverrideIsIgnored() {
        XCTAssertEqual(
            JSONLogWriter.resolveLogPath(
                stateHome: "/state",
                environment: ["THEGRID_LOG_PATH": ""],
                xctestLoaded: false,
                temporaryDirectory: "/var/tmp/"
            ),
            "/state/thegrid/thegrid-server.json"
        )
    }

    // This process IS a test process, so the live singleton must already be
    // pointed away from the real log.
    func test_sharedWriterInThisProcessIsNotTheRealServerLog() {
        let live = JSONLogWriter.shared.logPath
        XCTAssertFalse(
            live.hasSuffix("/.local/state/thegrid/thegrid-server.json"),
            "the suite is writing to the real server log: \(live)"
        )
    }

    // MARK: - envInt

    func test_envInt_readsValue() {
        XCTAssertEqual(
            LogRotationPolicy.envInt("X", default: 10, environment: ["X": "42"]),
            42
        )
    }

    func test_envInt_fallsBackWhenUnsetEmptyOrUnparseable() {
        XCTAssertEqual(LogRotationPolicy.envInt("X", default: 10, environment: [:]), 10)
        XCTAssertEqual(LogRotationPolicy.envInt("X", default: 10, environment: ["X": "  "]), 10)
        XCTAssertEqual(LogRotationPolicy.envInt("X", default: 10, environment: ["X": "big"]), 10)
    }

    // Zero must survive the fallback so THEGRID_LOG_MAX_BYTES=0 can disable
    // rotation rather than silently restoring the default.
    func test_envInt_zeroIsAValueNotAFallback() {
        XCTAssertEqual(LogRotationPolicy.envInt("X", default: 10, environment: ["X": "0"]), 0)
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("logrot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
