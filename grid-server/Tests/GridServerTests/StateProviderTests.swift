import XCTest
@testable import GridServer

// MockStateProvider: test fake that returns a canned WindowManagerState.
// Conforms to StateProvider so it can be injected into Grid* consumers.
// @unchecked Sendable: tests are single-threaded; no real concurrency.
final class MockStateProvider: StateProvider, @unchecked Sendable {
    var state: WindowManagerState

    // Fresh AX state returned by refreshWindowAXProperties, keyed by window id.
    // Lets a test make getState() (stale snapshot) and the AX re-query disagree,
    // simulating an app whose window buttons populate after creation (#41).
    var refreshStates: [String: WindowState] = [:]

    // Window ids passed to refreshWindowAXProperties, in call order.
    var refreshCalls: [UInt32] = []

    init(state: WindowManagerState = WindowManagerState()) {
        self.state = state
    }

    func getState() async -> WindowManagerState {
        return state
    }

    func refreshWindowAXProperties(_ windowID: UInt32) async -> WindowState? {
        refreshCalls.append(windowID)
        if let fresh = refreshStates[String(windowID)] {
            // Mirror StateManager: the refresh writes back to the cache.
            state.windows[String(windowID)] = fresh
            return fresh
        }
        return state.windows[String(windowID)]
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

    // DW-E2: notStandardGraceSweep re-queries AX and re-classifies the FRESH
    // state. A Chrome torn-tab reads AXStandardWindow + hasFullscreenButton=false
    // (PIP heuristic -> floating) at creation, so it lands in the grace map.
    // After the AX query un-races, hasFullscreenButton becomes true (-> standard).
    // The sweep must route it to tiling, not re-bail off the stale snapshot.
    func test_DW_E2_grace_sweep_requeries_ax_and_tiles() async {
        var wmState = WindowManagerState()
        wmState.metadata.activeSpaceID = 100

        // STALE snapshot: AXStandardWindow but no fullscreen button -> floating.
        var staleWindow = WindowState(id: 11277)
        staleWindow.pid = 7
        staleWindow.role = "AXWindow"
        staleWindow.subrole = "AXStandardWindow"
        staleWindow.hasCloseButton = true
        staleWindow.hasFullscreenButton = false
        staleWindow.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        staleWindow.spaces = [100]
        staleWindow.appName = "Google Chrome"
        wmState.windows["11277"] = staleWindow

        var display = DisplayState(uuid: "display-1", currentSpaceID: 100, spaces: [100])
        display.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        display.visibleFrame = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        wmState.displays = [display]
        wmState.spaces["100"] = SpaceState(
            id: 100, uuid: "space-uuid", type: "user", displayUUID: "display-1"
        )
        wmState.applications["7"] = makeApplicationState(pid: 7, name: "Google Chrome")

        let mock = MockStateProvider(state: wmState)

        // FRESH AX state: fullscreen button now present -> classifies standard.
        var freshWindow = staleWindow
        freshWindow.hasFullscreenButton = true
        mock.refreshStates["11277"] = freshWindow

        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "100", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "100", cellIDs: ["left", "right"])

        let reconciler = GridReconciler()
        reconciler._test_setup(stateProvider: mock, gridState: gridState)

        // Creation classifies floating (stale) -> tracked in the grace map.
        await reconciler._test_triggerWindowCreated(windowID: 11277, pid: 7)
        let graceCountAfterCreate = reconciler._test_notStandardGraceCount
        XCTAssertEqual(graceCountAfterCreate, 1, "Window should be grace-tracked after floating bail")

        // Run the grace sweep: it must re-query AX (fresh -> standard) and tile.
        await reconciler._test_notStandardGraceSweep()

        XCTAssertTrue(mock.refreshCalls.contains(11277), "Sweep must re-query the window's AX props")

        let graceCountAfterSweep = reconciler._test_notStandardGraceCount
        XCTAssertEqual(graceCountAfterSweep, 0, "Re-classified-standard window must leave the grace map")

        let leftWindows = await gridState.getCellWindows(spaceID: "100", cellID: "left")
        let rightWindows = await gridState.getCellWindows(spaceID: "100", cellID: "right")
        let assigned = leftWindows.contains(11277) || rightWindows.contains(11277)
        XCTAssertTrue(assigned, "Window reporting fresh standard AX must be routed to a cell")
    }

    // DW-E3: the not_standard grace window is long enough for an app to populate
    // window buttons after creation (>= ~3s, several sweep ticks).
    func test_DW_E3_grace_window_at_least_3s() {
        XCTAssertGreaterThanOrEqual(NotStandardGracePolicy.defaultGraceWindow, 3.0)

        let firstSeen: CFAbsoluteTime = 1000.0
        // At the exact boundary, still re-evaluate.
        XCTAssertTrue(NotStandardGracePolicy.shouldReevaluate(
            now: firstSeen + NotStandardGracePolicy.defaultGraceWindow,
            firstSeen: firstSeen
        ))
        // Just past the boundary, give up.
        XCTAssertFalse(NotStandardGracePolicy.shouldReevaluate(
            now: firstSeen + NotStandardGracePolicy.defaultGraceWindow + 0.001,
            firstSeen: firstSeen
        ))
    }

    // MARK: - Helpers

    private func makeApplicationState(pid: pid_t, name: String) -> ApplicationState {
        // Build a minimal ApplicationState without NSRunningApplication
        return ApplicationState._test_make(pid: pid, name: name)
    }
}
