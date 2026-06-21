import XCTest
@testable import GridNotify

// MARK: - TmuxStatusTests

final class TmuxStatusTests: XCTestCase {

    // MARK: - Helpers

    // Full canonical JSON sample from the P1 skill file.
    private let canonicalJSON = """
    {
      "generatedAt": 1718500000,
      "sessions": [
        {
          "name": "work",
          "attached": true,
          "windows": [
            {
              "index": 0,
              "name": "nvim",
              "command": "nvim",
              "active": true,
              "statusKind": "active",
              "summary": "editing api.go — cursor in handleRequest() function",
              "target": "work:0"
            },
            {
              "index": 1,
              "name": "server",
              "command": "npm",
              "active": false,
              "statusKind": "running",
              "summary": "npm run dev watching on port 3000 — no recent changes",
              "target": "work:1"
            }
          ]
        },
        {
          "name": "claude-mux",
          "attached": false,
          "windows": [
            {
              "index": 0,
              "name": "claude",
              "command": "claude",
              "active": true,
              "statusKind": "waiting",
              "summary": "claude waiting for input at prompt",
              "target": "claude-mux:0"
            }
          ]
        }
      ]
    }
    """

    private func makeTempPath(_ suffix: String = ".json") -> String {
        return NSTemporaryDirectory() + "tmux-test-\(UUID().uuidString)\(suffix)"
    }

    private func cleanup(_ paths: String...) {
        for path in paths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func decode(_ json: String) throws -> TmuxStatusData {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(TmuxStatusData.self, from: data)
    }

    // MARK: - DW-2.1: Full decode with all fields populated

    func test_DW_2_1_fullSampleDecodesAllFields() throws {
        let result = try decode(canonicalJSON)

        // generatedAt
        XCTAssertEqual(result.generatedAt, 1718500000)

        // Two sessions
        XCTAssertEqual(result.sessions.count, 2)

        // First session
        let work = result.sessions[0]
        XCTAssertEqual(work.name, "work")
        XCTAssertTrue(work.attached)
        XCTAssertEqual(work.windows.count, 2)

        // First window — active
        let nvim = work.windows[0]
        XCTAssertEqual(nvim.index, 0)
        XCTAssertEqual(nvim.name, "nvim")
        XCTAssertEqual(nvim.command, "nvim")
        XCTAssertTrue(nvim.active)
        XCTAssertEqual(nvim.statusKind, .active)
        XCTAssertEqual(nvim.summary, "editing api.go — cursor in handleRequest() function")
        XCTAssertEqual(nvim.target, "work:0")

        // Second window — running
        let server = work.windows[1]
        XCTAssertEqual(server.index, 1)
        XCTAssertEqual(server.statusKind, .running)
        XCTAssertFalse(server.active)

        // Second session — not attached
        let claudeMux = result.sessions[1]
        XCTAssertEqual(claudeMux.name, "claude-mux")
        XCTAssertFalse(claudeMux.attached)
        XCTAssertEqual(claudeMux.windows[0].statusKind, .waiting)
    }

    // MARK: - Activity field (session ranking source)

    func test_activity_decodesWhenPresent() throws {
        let json = """
        { "generatedAt": 100, "sessions": [
          { "name": "a", "attached": true, "activity": 1718499990, "windows": [] }
        ] }
        """
        let result = try decode(json)
        XCTAssertEqual(result.sessions[0].activity, 1718499990)
    }

    func test_activity_defaultsToZeroWhenAbsent() throws {
        // Back-compat: status files written before the activity field omit it.
        // Absent must decode to 0, not throw.
        let json = """
        { "generatedAt": 100, "sessions": [
          { "name": "a", "attached": true, "windows": [] }
        ] }
        """
        let result = try decode(json)
        XCTAssertEqual(result.sessions[0].activity, 0)
    }

    // MARK: - DW-2.1 (Phase 2): per-window activity field

    // A window object that carries activity decodes it into TmuxWindow.activity.
    func test_DW_2_1_windowDecodesActivityWhenPresent() throws {
        let json = """
        { "generatedAt": 100, "sessions": [
          { "name": "s", "attached": false, "windows": [
            { "index": 0, "name": "w", "command": "zsh", "active": true,
              "statusKind": "idle", "summary": "x", "target": "s:0",
              "activity": 1718499994 }
          ] }
        ] }
        """
        let result = try decode(json)
        XCTAssertEqual(result.sessions[0].windows[0].activity, 1718499994)
    }

    // Back-compat: a window object written before the activity field omits it.
    // Absent activity must decode to 0 (not throw), so the row shows no age.
    func test_DW_2_1_windowActivityDefaultsToZeroWhenAbsent() throws {
        let result = try decode(canonicalJSON)
        for session in result.sessions {
            for window in session.windows {
                XCTAssertEqual(window.activity, 0,
                    "window \(window.target) without an activity key must default to 0")
            }
        }
    }

    func test_DW_2_1_allStatusKindGlyphsDistinct() {
        // All five status kinds have distinct, non-empty glyphs.
        let kinds: [TmuxStatusKind] = [.active, .running, .waiting, .idle, .error]
        let glyphs = kinds.map { $0.glyph }
        let unique = Set(glyphs)
        XCTAssertEqual(unique.count, kinds.count, "Each statusKind must have a unique glyph")
        for glyph in glyphs {
            XCTAssertFalse(glyph.isEmpty, "Glyph must not be empty")
        }
    }

    func test_DW_2_1_allStatusKindColorsNonNil() {
        // All five status kinds return a non-nil, distinct color.
        let kinds: [TmuxStatusKind] = [.active, .running, .waiting, .idle, .error]
        // Verify each kind returns its color without crashing (NSColor is always non-nil).
        for kind in kinds {
            // Access color — if it crashes we'll know.
            let color = kind.color
            _ = color
        }
        // Verify active != idle (spot check for distinctness).
        XCTAssertNotEqual(TmuxStatusKind.active.color, TmuxStatusKind.idle.color)
    }

    func test_DW_2_1_emptySessions() throws {
        let json = """
        { "generatedAt": 1718500000, "sessions": [] }
        """
        let result = try decode(json)
        XCTAssertEqual(result.generatedAt, 1718500000)
        XCTAssertTrue(result.sessions.isEmpty)
    }

    // MARK: - DW-2.2: Malformed JSON, unknown statusKind, truncated JSON

    func test_DW_2_2_malformedJSONSkipped() {
        // Malformed JSON must not crash — it should throw a DecodingError.
        let malformed = "{ this is not valid JSON }"
        XCTAssertThrowsError(try decode(malformed)) { error in
            // Must be a Swift DecodingError or underlying JSON parse error.
            // The watcher catches this and logs; here we verify it throws correctly.
            XCTAssertNotNil(error)
        }
    }

    func test_DW_2_2_unknownStatusKindDecodesToIdle() throws {
        // An unknown statusKind string (e.g. from a future skill version) must
        // decode leniently to .idle rather than throwing.
        let json = """
        {
          "generatedAt": 1718500000,
          "sessions": [
            {
              "name": "test",
              "attached": false,
              "windows": [
                {
                  "index": 0,
                  "name": "win",
                  "command": "zsh",
                  "active": true,
                  "statusKind": "future_unknown_kind",
                  "summary": "something",
                  "target": "test:0"
                }
              ]
            }
          ]
        }
        """
        let result = try decode(json)
        XCTAssertEqual(result.sessions[0].windows[0].statusKind, .idle)
    }

    func test_DW_2_2_truncatedJSONSkipped() {
        // Truncated/partial JSON must throw, not crash.
        let truncated = """
        {
          "generatedAt": 1718500000,
          "sessions": [
            { "name": "work",
        """
        XCTAssertThrowsError(try decode(truncated)) { error in
            XCTAssertNotNil(error)
        }
    }

    func test_DW_2_2_missingRequiredField() {
        // Missing required field (e.g. generatedAt) must throw.
        let missing = """
        { "sessions": [] }
        """
        XCTAssertThrowsError(try decode(missing)) { error in
            XCTAssertNotNil(error)
        }
    }

    // MARK: - DW-2.3: Watcher fires onChange on write and atomic rename

    func test_DW_2_3_writeFiresOnChange() throws {
        let path = makeTempPath()
        defer { cleanup(path) }

        // Write initial file.
        let initialJSON = """
        { "generatedAt": 1718500000, "sessions": [] }
        """
        try initialJSON.write(toFile: path, atomically: true, encoding: .utf8)

        let watcher = TmuxStatusWatcher(path: path)
        let expectation = XCTestExpectation(description: "onChange fires on start")

        watcher.onChange = { data in
            XCTAssertEqual(data.generatedAt, 1718500000)
            expectation.fulfill()
        }
        watcher.start()

        wait(for: [expectation], timeout: 3)
        watcher.stop()
    }

    func test_DW_2_3_atomicRenameFiresOnChange() throws {
        let path = makeTempPath()
        let tmpPath = path + ".tmp"
        defer { cleanup(path, tmpPath) }

        // Write initial file so watcher can open it.
        let initialJSON = """
        { "generatedAt": 1000, "sessions": [] }
        """
        try initialJSON.write(toFile: path, atomically: true, encoding: .utf8)

        let watcher = TmuxStatusWatcher(path: path)

        // We expect two calls: once on start (initial read), once after the rename.
        var callCount = 0
        var lastGeneratedAt = 0
        let expectRename = XCTestExpectation(description: "onChange fires after atomic rename")

        watcher.onChange = { data in
            callCount += 1
            lastGeneratedAt = data.generatedAt
            if data.generatedAt == 9999 {
                expectRename.fulfill()
            }
        }
        watcher.start()

        // Brief pause to let the watcher open and do its initial read.
        Thread.sleep(forTimeInterval: 0.5)

        // Simulate atomic rename: write to .tmp, then rename over the real path.
        // Use Darwin rename(2) directly — FileManager.moveItem fails when the destination
        // exists, but rename(2) is atomic and replaces the destination (POSIX rename semantics).
        let updatedJSON = """
        { "generatedAt": 9999, "sessions": [] }
        """
        try updatedJSON.write(toFile: tmpPath, atomically: false, encoding: .utf8)
        let renameResult = rename(tmpPath, path)
        XCTAssertEqual(renameResult, 0, "rename(2) must succeed: \(String(cString: strerror(errno)))")

        wait(for: [expectRename], timeout: 5)
        watcher.stop()

        XCTAssertEqual(lastGeneratedAt, 9999, "Last onChange must carry the renamed file's value")
    }

    func test_DW_2_3_missingFileAtStartDoesNotCrash() {
        // Watcher must not crash if the file does not exist yet — it retries silently.
        let path = makeTempPath()
        // Do NOT create the file.
        defer { cleanup(path) }

        let watcher = TmuxStatusWatcher(path: path)
        // No onChange set — watcher should survive gracefully.
        watcher.start()
        Thread.sleep(forTimeInterval: 0.2)
        watcher.stop()
        // If we get here without crashing, the test passes.
    }

    // MARK: - DW-2.4: NotifyConfig tmux: YAML parsing

    func test_DW_2_4_tmuxBlockParsesCorrectly() throws {
        let yamlPath = makeTempPath(".yaml")
        defer { cleanup(yamlPath) }

        let yaml = """
        tmux:
          enabled: true
          interval: 120
          repo_dir: ~/repos/theGrid
          model: claude-sonnet-4-5
        """
        try yaml.write(toFile: yamlPath, atomically: true, encoding: .utf8)

        // Temporarily redirect the XDG config path via environment.
        // loadNotifyConfig() reads from "\(XDG.configHome)/thegrid/notify.yaml".
        // We can't easily intercept that, so we test the YAML parsing logic
        // by constructing the config using NotifyConfig defaults and verifying
        // the struct shape. Instead, call the internal parse path via a helper
        // that accepts a raw YAML string.
        let config = try loadNotifyConfigFromYAML(yamlString: yaml)
        XCTAssertTrue(config.tmux.enabled)
        XCTAssertEqual(config.tmux.interval, 120)
        XCTAssertTrue(config.tmux.repoDir.hasSuffix("repos/theGrid"), "~ should be expanded")
        XCTAssertEqual(config.tmux.model, "claude-sonnet-4-5")
    }

    func test_DW_2_4_absentTmuxBlockUsesDefaults() throws {
        // A notify.yaml without a tmux: block must yield the default Tmux config.
        let yaml = """
        pipe:
          path: /tmp/test.pipe
        """
        let config = try loadNotifyConfigFromYAML(yamlString: yaml)
        XCTAssertFalse(config.tmux.enabled, "Default: disabled")
        XCTAssertEqual(config.tmux.interval, 60, "Default interval: 60s")
        XCTAssertNil(config.tmux.model, "Default model: nil")
    }

    func test_DW_2_4_negativeIntervalClampsToOne() throws {
        // A negative or zero interval must be clamped to 1 (prevent restart-storm).
        let yaml = """
        tmux:
          enabled: true
          interval: -5
          repo_dir: /tmp/repo
        """
        let config = try loadNotifyConfigFromYAML(yamlString: yaml)
        XCTAssertGreaterThanOrEqual(config.tmux.interval, 1,
            "Negative interval must be clamped to at least 1")
    }

    func test_DW_2_4_zeroIntervalClampsToOne() throws {
        let yaml = """
        tmux:
          enabled: false
          interval: 0
          repo_dir: /tmp/repo
        """
        let config = try loadNotifyConfigFromYAML(yamlString: yaml)
        XCTAssertGreaterThanOrEqual(config.tmux.interval, 1,
            "Zero interval must be clamped to at least 1")
    }
}
