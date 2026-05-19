import XCTest
@testable import GridServer

// MockStateProvider: test fake that returns a canned WindowManagerState.
// Conforms to StateProvider so it can be injected into Grid* consumers.
// @unchecked Sendable: tests are single-threaded; no real concurrency.
final class MockStateProvider: StateProvider, @unchecked Sendable {
    var state: WindowManagerState

    init(state: WindowManagerState = WindowManagerState()) {
        self.state = state
    }

    func getState() async -> WindowManagerState {
        return state
    }
}

// Tests for the StateProvider port protocol and its integration with
// GridReconciler's handleWindowCreated path.
final class StateProviderTests: XCTestCase {

    // DW-1.5: MockStateProvider returns the canned state it was configured with.
    func test_DW_1_5_mock_returns_canned_state() async {
        var cannedState = WindowManagerState()
        cannedState.metadata.activeSpaceID = 42
        let mock = MockStateProvider(state: cannedState)
        let result = await mock.getState()
        XCTAssertEqual(result.metadata.activeSpaceID, 42)
    }

    // DW-1.6a: A tileable window (AXWindow, AXStandardWindow, large frame)
    // gets assigned to a cell when handleWindowCreated runs.
    func test_DW_1_6a_tileable_window_assigned_to_cell() async {
        // Build a canned wmState with one tileable window on space 100
        var wmState = WindowManagerState()
        wmState.metadata.activeSpaceID = 100

        var window = WindowState(id: 500)
        window.pid = 1
        window.role = "AXWindow"
        window.subrole = "AXStandardWindow"
        window.hasCloseButton = true
        window.hasFullscreenButton = true
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        window.spaces = [100]
        window.appName = "TestApp"
        wmState.windows["500"] = window

        var display = DisplayState(
            uuid: "display-1",
            currentSpaceID: 100,
            spaces: [100]
        )
        display.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        display.visibleFrame = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        wmState.displays = [display]

        wmState.spaces["100"] = SpaceState(
            id: 100, uuid: "space-uuid", type: "user", displayUUID: "display-1"
        )

        let app = makeApplicationState(pid: 1, name: "TestApp")
        wmState.applications["1"] = app

        let mock = MockStateProvider(state: wmState)
        let gridState = GridState()

        // Seed GridState: space 100 with layout "two-col" and two empty cells
        await gridState._test_setLayout(spaceID: "100", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "100", cellIDs: ["left", "right"])

        // Wire up a reconciler with the mock
        let reconciler = GridReconciler()
        reconciler._test_setup(stateProvider: mock, gridState: gridState)

        // Trigger window creation
        await reconciler._test_triggerWindowCreated(windowID: 500, pid: 1)

        // Window should be assigned to a cell
        let leftWindows = await gridState.getCellWindows(spaceID: "100", cellID: "left")
        let rightWindows = await gridState.getCellWindows(spaceID: "100", cellID: "right")
        let assigned = leftWindows.contains(500) || rightWindows.contains(500)
        XCTAssertTrue(assigned, "Tileable window should be assigned to a cell")
    }

    // DW-1.6b: A non-tileable window (zero-size frame) gets rejected.
    func test_DW_1_6b_non_tileable_window_rejected() async {
        var wmState = WindowManagerState()
        wmState.metadata.activeSpaceID = 100

        // Window with zero-size frame -- not tileable
        var window = WindowState(id: 600)
        window.pid = 2
        window.role = "AXWindow"
        window.subrole = "AXStandardWindow"
        window.frame = CGRect(x: 0, y: 0, width: 0, height: 0)
        window.spaces = [100]
        window.appName = "PhantomApp"
        wmState.windows["600"] = window

        var display = DisplayState(
            uuid: "display-1",
            currentSpaceID: 100,
            spaces: [100]
        )
        display.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        wmState.displays = [display]
        wmState.spaces["100"] = SpaceState(
            id: 100, uuid: "space-uuid", type: "user", displayUUID: "display-1"
        )

        let app = makeApplicationState(pid: 2, name: "PhantomApp")
        wmState.applications["2"] = app

        let mock = MockStateProvider(state: wmState)
        let gridState = GridState()

        await gridState._test_setLayout(spaceID: "100", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "100", cellIDs: ["left", "right"])

        let reconciler = GridReconciler()
        reconciler._test_setup(stateProvider: mock, gridState: gridState)

        await reconciler._test_triggerWindowCreated(windowID: 600, pid: 2)

        // Window should NOT be in any cell
        let leftWindows = await gridState.getCellWindows(spaceID: "100", cellID: "left")
        let rightWindows = await gridState.getCellWindows(spaceID: "100", cellID: "right")
        XCTAssertFalse(leftWindows.contains(600), "Non-tileable window should not be assigned")
        XCTAssertFalse(rightWindows.contains(600), "Non-tileable window should not be assigned")
    }

    // DW-1.6c: A window matching a locked app rule routes to the locked cell.
    func test_DW_1_6c_locked_cell_routing() async {
        var wmState = WindowManagerState()
        wmState.metadata.activeSpaceID = 100

        var window = WindowState(id: 700)
        window.pid = 3
        window.role = "AXWindow"
        window.subrole = "AXStandardWindow"
        window.hasCloseButton = true
        window.hasFullscreenButton = true
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        window.spaces = [100]
        window.appName = "Terminal"
        wmState.windows["700"] = window

        var display = DisplayState(
            uuid: "display-1",
            currentSpaceID: 100,
            spaces: [100]
        )
        display.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        display.visibleFrame = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        wmState.displays = [display]

        wmState.spaces["100"] = SpaceState(
            id: 100, uuid: "space-uuid", type: "user", displayUUID: "display-1"
        )

        let app = makeApplicationState(pid: 3, name: "Terminal")
        wmState.applications["3"] = app

        let mock = MockStateProvider(state: wmState)
        let gridState = GridState()

        await gridState._test_setLayout(spaceID: "100", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "100", cellIDs: ["left", "right"])

        // Configure a locked app rule: Terminal -> right cell
        let reconciler = GridReconciler()
        reconciler._test_setup(
            stateProvider: mock,
            gridState: gridState,
            lockedRules: [GridAppRule(app: "Terminal", preferredCell: "right", float: false, locked: true)]
        )

        await reconciler._test_triggerWindowCreated(windowID: 700, pid: 3)

        // Window should be in the "right" cell (locked target)
        let rightWindows = await gridState.getCellWindows(spaceID: "100", cellID: "right")
        XCTAssertTrue(rightWindows.contains(700), "Window matching locked rule should go to locked cell")
    }

    // MARK: - Helpers

    private func makeApplicationState(pid: pid_t, name: String) -> ApplicationState {
        // Build a minimal ApplicationState without NSRunningApplication
        return ApplicationState._test_make(pid: pid, name: name)
    }
}
