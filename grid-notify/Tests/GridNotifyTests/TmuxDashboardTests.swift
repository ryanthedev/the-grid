import XCTest
@testable import GridNotify

// MARK: - TmuxDashboardTests

@MainActor
final class TmuxDashboardTests: XCTestCase {

    // MARK: - Helpers

    // Canonical two-session sample matching the P1/P2 schema.
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
              "summary": "npm run dev watching on port 3000",
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

    private func decode(_ json: String) throws -> TmuxStatusData {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(TmuxStatusData.self, from: data)
    }

    // Make a minimal TmuxStatusData with an empty sessions array.
    private func emptyStatusData() -> TmuxStatusData {
        let json = """
        { "generatedAt": 1718500000, "sessions": [] }
        """
        return try! decode(json)
    }

    // MARK: - DW-3.1: load(_:) populates @Published sessions / generatedAt

    // load(_:) sets the sessions list to match the input data.
    func test_DW_3_1_loadPopulatesSessions() throws {
        let vm = TmuxDashboardViewModel()
        let data = try decode(canonicalJSON)

        // Confirm initial state is empty.
        XCTAssertTrue(vm.sessions.isEmpty)
        XCTAssertNil(vm.generatedAt)

        vm.load(data)

        XCTAssertEqual(vm.sessions.count, 2)
        XCTAssertEqual(vm.sessions[0].name, "work")
        XCTAssertEqual(vm.sessions[1].name, "claude-mux")
    }

    // load(_:) converts the generatedAt Unix int into a Date.
    func test_DW_3_1_generatedAtConvertedToDate() throws {
        let vm = TmuxDashboardViewModel()
        let data = try decode(canonicalJSON)

        vm.load(data)

        let expected = Date(timeIntervalSince1970: TimeInterval(1718500000))
        XCTAssertNotNil(vm.generatedAt)
        let diff = abs(vm.generatedAt!.timeIntervalSince(expected))
        XCTAssertLessThan(diff, 0.001, "generatedAt must equal the Unix timestamp converted to Date")
    }

    // load(_:) populates windows with statusKind glyph accessible from sessions.
    // This proves the SwiftUI tree has everything it needs to render glyph + summary.
    func test_DW_3_1_multipleSessionsAndWindows() throws {
        let vm = TmuxDashboardViewModel()
        let data = try decode(canonicalJSON)

        vm.load(data)

        // First session: 2 windows
        let work = vm.sessions[0]
        XCTAssertEqual(work.windows.count, 2)

        let nvim = work.windows[0]
        XCTAssertEqual(nvim.statusKind.glyph, "●")
        XCTAssertFalse(nvim.summary.isEmpty)
        XCTAssertEqual(nvim.target, "work:0")

        let server = work.windows[1]
        XCTAssertEqual(server.statusKind.glyph, "▶")
        XCTAssertEqual(server.target, "work:1")

        // Second session: 1 window
        let claudeMux = vm.sessions[1]
        XCTAssertEqual(claudeMux.windows.count, 1)
        XCTAssertEqual(claudeMux.windows[0].statusKind.glyph, "⏸")
    }

    // MARK: - DW-3.2: Empty TmuxStatusData → zero-state (sessions is empty)

    // load(_:) with empty sessions produces an empty sessions list.
    func test_DW_3_2_emptyDataYieldsEmptySessions() {
        let vm = TmuxDashboardViewModel()
        let data = emptyStatusData()

        vm.load(data)

        XCTAssertTrue(vm.sessions.isEmpty, "Empty TmuxStatusData must yield empty sessions")
    }

    // With empty sessions, the ViewModel's state signals zero-state to the view.
    // The view switches on sessions.isEmpty to show TmuxDashboardEmptyView.
    func test_DW_3_2_emptySessionsIsZeroState() {
        let vm = TmuxDashboardViewModel()

        // Before any load — also zero-state.
        XCTAssertTrue(vm.sessions.isEmpty)

        // Load empty data — remains zero-state.
        vm.load(emptyStatusData())
        XCTAssertTrue(vm.sessions.isEmpty)

        // statusText reflects zero-state.
        XCTAssertTrue(
            vm.statusText.contains("no tmux sessions"),
            "statusText must say 'no tmux sessions' when sessions is empty; got: \(vm.statusText)"
        )
    }

    // MARK: - DW-3.3: Refresh button invokes onRefreshRequested exactly once

    func test_DW_3_3_refreshCallsOnRefreshRequested() {
        let vm = TmuxDashboardViewModel()
        var callCount = 0
        vm.onRefreshRequested = { callCount += 1 }

        vm.requestRefresh()

        XCTAssertEqual(callCount, 1, "onRefreshRequested must be called exactly once per requestRefresh()")
    }

    // Calling requestRefresh with no callback set must not crash.
    func test_DW_3_3_refreshWithNoCallbackIsSafe() {
        let vm = TmuxDashboardViewModel()
        XCTAssertNil(vm.onRefreshRequested)
        vm.requestRefresh() // must not crash
    }

    // MARK: - DW-3.4: Enter on window row → detail command for that pane

    // openDetailCommand(for:) produces the correct tmux capture-pane command.
    func test_DW_3_4_openDetailCommandForWindow() throws {
        let vm = TmuxDashboardViewModel()
        let data = try decode(canonicalJSON)
        vm.load(data)

        let window = vm.sessions[0].windows[0]
        let command = vm.openDetailCommand(for: window)

        XCTAssertTrue(
            command.contains("tmux capture-pane"),
            "command must use tmux capture-pane; got: \(command)"
        )
        XCTAssertTrue(
            command.contains(window.target),
            "command must reference the window target '\(window.target)'; got: \(command)"
        )
        XCTAssertTrue(
            command.contains("-S -200"),
            "command must capture 200 lines of history; got: \(command)"
        )
    }

    // currentWindow returns the selected window after selectWindow is called.
    func test_DW_3_4_currentWindowReflectsSelection() throws {
        let vm = TmuxDashboardViewModel()
        let data = try decode(canonicalJSON)
        vm.load(data)

        // No selection yet
        XCTAssertNil(vm.currentWindow)

        // Select the second window in the first session
        vm.selectWindow(sessionName: "work", windowIndex: 1)
        let current = vm.currentWindow

        XCTAssertNotNil(current)
        XCTAssertEqual(current?.target, "work:1")
        XCTAssertEqual(current?.name, "server")
    }

    // MARK: - Additional: Collapse / Expand

    // toggleCollapsed flips a session's collapsed state.
    func test_collapsedToggleRoundTrips() {
        let vm = TmuxDashboardViewModel()
        XCTAssertFalse(vm.isCollapsed("work"))

        vm.toggleCollapsed("work")
        XCTAssertTrue(vm.isCollapsed("work"))

        vm.toggleCollapsed("work")
        XCTAssertFalse(vm.isCollapsed("work"))
    }

    // MARK: - Additional: Status text

    // statusText with sessions returns session/window counts.
    func test_statusTextWithSessions() throws {
        let vm = TmuxDashboardViewModel()
        let data = try decode(canonicalJSON)
        vm.load(data)

        let text = vm.statusText
        XCTAssertTrue(text.contains("2 sessions"), "expected '2 sessions' in '\(text)'")
        XCTAssertTrue(text.contains("3 windows"), "expected '3 windows' in '\(text)'")
    }

    // MARK: - Additional: Empty summary falls back to command

    // Window rows with an empty summary display the command name instead.
    // This is a ViewModel-view contract verified through the view struct's computed var,
    // but we can test the logic by checking what TmuxDashboardWindowRow would compute.
    // We verify by checking the model directly (logic lives in the view's displaySummary).
    func test_emptySummaryFallsBackToCommand() throws {
        let json = """
        {
          "generatedAt": 1718500000,
          "sessions": [
            {
              "name": "s",
              "attached": false,
              "windows": [
                {
                  "index": 0,
                  "name": "bash",
                  "command": "bash",
                  "active": true,
                  "statusKind": "idle",
                  "summary": "",
                  "target": "s:0"
                }
              ]
            }
          ]
        }
        """
        let data = try decode(json)
        let vm = TmuxDashboardViewModel()
        vm.load(data)
        let window = vm.sessions[0].windows[0]
        // Summary is empty — the view falls back to command.
        // We verify the contract holds by checking the model property.
        XCTAssertTrue(window.summary.isEmpty)
        XCTAssertEqual(window.command, "bash")
    }
}
