import XCTest
@testable import GridServer

/// `@window float`: the user floats one tiled window, and toggles it back.
final class FloatOverrideTests: XCTestCase {

    override func tearDown() {
        FloatOverrides._test_reset()
        super.tearDown()
    }

    private func standardWindow(id: UInt32 = 700, pid: pid_t = 51, space: UInt64 = 100) -> WindowState {
        var w = WindowState(id: id)
        w.pid = pid
        w.appName = "Editor"
        w.role = "AXWindow"
        w.subrole = "AXStandardWindow"
        w.hasCloseButton = true
        w.hasFullscreenButton = true
        w.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        w.spaces = [space]
        return w
    }

    private func makeReconciler(window: WindowState) async -> (GridReconciler, GridState, MockStateProvider) {
        var wmState = WindowManagerState()
        wmState.metadata.activeSpaceID = 100
        wmState.windows[String(window.id)] = window
        var d = DisplayState(uuid: "display-1", currentSpaceID: 100, spaces: [100])
        d.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        d.visibleFrame = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        wmState.displays = [d]
        wmState.spaces["100"] = SpaceState(id: 100, uuid: "u", type: "user", displayUUID: "display-1")
        wmState.applications[String(window.pid)] = ApplicationState._test_make(pid: window.pid, name: "Editor")

        let mock = MockStateProvider(state: wmState)
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "100", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "100", cellIDs: ["left", "right"])

        let reconciler = GridReconciler()
        reconciler._test_setup(stateProvider: mock, gridState: gridState)
        let wid = window.id
        reconciler._test_setAXWindowIDs { pid in pid == window.pid ? [wid] : [] }
        return (reconciler, gridState, mock)
    }

    func test_toggle_floats_then_restores_classification() {
        let w = standardWindow()
        XCTAssertEqual(classifyWindow(window: w, appName: "Editor"), .standard)

        XCTAssertTrue(FloatOverrides.toggle(w.id))
        XCTAssertEqual(classifyWindow(window: w, appName: "Editor"), .floating)

        XCTAssertFalse(FloatOverrides.toggle(w.id))
        XCTAssertEqual(classifyWindow(window: w, appName: "Editor"), .standard)
    }

    func test_floated_minimized_window_is_still_popup() {
        var w = standardWindow()
        w.isMinimized = true
        _ = FloatOverrides.toggle(w.id)
        XCTAssertEqual(classifyWindow(window: w, appName: "Editor"), .popup)
    }

    // A floated window stays out of the grid through adoption passes, and
    // comes back on the next pass once toggled off and unrejected (what
    // `@window float` does), even if a pass rejected it while floated.
    func test_floated_window_is_not_adopted_until_toggled_back() async {
        let w = standardWindow()
        let (reconciler, gridState, mock) = await makeReconciler(window: w)

        _ = FloatOverrides.toggle(w.id)
        await reconciler._test_adoptUntrackedTileables()
        let whileFloated = await gridState.findSpaceContaining(windowID: w.id)
        XCTAssertNil(whileFloated, "floated window must not be adopted")

        await gridState.rejectWindow(w.id)
        _ = FloatOverrides.toggle(w.id)
        await gridState.unrejectWindow(w.id)
        await reconciler._test_adoptUntrackedTileables()
        let afterToggle = await gridState.findSpaceContaining(windowID: w.id)
        XCTAssertEqual(afterToggle, "100", "toggled back: adopted on the next pass")
        withExtendedLifetime(mock) {}
    }

    // Window IDs can be reused after a window dies; the override must not
    // outlive the window it was set on.
    func test_destroyed_window_drops_its_override() async {
        let w = standardWindow()
        let (reconciler, _, mock) = await makeReconciler(window: w)

        _ = FloatOverrides.toggle(w.id)
        await reconciler._test_handle(.windowDestroyed(windowID: w.id))
        XCTAssertFalse(FloatOverrides.contains(w.id))
        withExtendedLifetime(mock) {}
    }
}
