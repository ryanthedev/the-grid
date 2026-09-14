import XCTest
@testable import GridServer

// BUG B: windows permanently lost to a cached transient subrole.
//
// isTileable answers from cached AX properties, and updateWindowFromPoll
// re-queries them only when role == nil. A window whose app reported a
// transient "AXUnknown" subrole during startup has that cached WITH a real
// role, so the guard skips it forever and isTileable rejects it for the life
// of the window. 445 AXWindow/AXUnknown bails in one archived log; 16 windows
// confirmed never tiled yet still emitting real focus/move/resize events.
// Documented as confirmed-and-deferred at StateManager.swift:1650.
final class StaleSubroleRecoveryTests: XCTestCase {

    private func window(
        id: UInt32, pid: pid_t, subrole: String?, w: CGFloat = 1900, h: CGFloat = 1060
    ) -> WindowState {
        var s = WindowState(id: id)
        s.pid = pid
        s.role = "AXWindow"
        s.subrole = subrole
        s.hasCloseButton = true
        s.hasFullscreenButton = true
        s.frame = CGRect(x: 0, y: 0, width: w, height: h)
        s.spaces = [100]
        s.appName = "Chrome"
        return s
    }

    private func wire(
        _ poisoned: WindowState
    ) async -> (GridReconciler, GridState, MockStateProvider) {
        var wmState = WindowManagerState()
        wmState.metadata.activeSpaceID = 100
        wmState.windows[String(poisoned.id)] = poisoned
        var d = DisplayState(uuid: "display-1", currentSpaceID: 100, spaces: [100])
        d.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        d.visibleFrame = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        wmState.displays = [d]
        wmState.spaces["100"] = SpaceState(id: 100, uuid: "u", type: "user", displayUUID: "display-1")
        wmState.applications[String(poisoned.pid)] =
            ApplicationState._test_make(pid: poisoned.pid, name: "Chrome")

        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "100", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "100", cellIDs: ["left", "right"])
        let mock = MockStateProvider(state: wmState)
        let reconciler = GridReconciler()
        reconciler._test_setup(stateProvider: mock, gridState: gridState)
        reconciler._test_setAXWindowIDs { pid in pid == poisoned.pid ? [poisoned.id] : [] }
        return (reconciler, gridState, mock)
    }

    // The recovery: AX now reports a standard subrole, so the window tiles.
    func testWindowWithSettledSubroleIsRecovered() async {
        let poisoned = window(id: 2884, pid: 91674, subrole: "AXUnknown")
        let (reconciler, gridState, mock) = await wire(poisoned)
        await gridState.rejectWindow(2884)
        mock.refreshStates["2884"] = window(id: 2884, pid: 91674, subrole: "AXStandardWindow")

        await reconciler._test_rejectedWindowSweep()

        let rejected = await gridState.isWindowRejected(2884)
        XCTAssertFalse(rejected, "a settled subrole must release the window")
        let space = await gridState.findSpaceContaining(windowID: 2884)
        XCTAssertEqual(space, "100", "and it must reach a cell")
    }

    // A window that really is AXUnknown stays out, and stops costing AX calls.
    func testGenuinelyUnknownWindowStopsBeingRequeried() async {
        let poisoned = window(id: 2884, pid: 91674, subrole: "AXUnknown")
        let (reconciler, gridState, mock) = await wire(poisoned)
        await gridState.rejectWindow(2884)
        mock.refreshStates["2884"] = poisoned   // AX keeps saying AXUnknown

        for _ in 0..<6 { await reconciler._test_rejectedWindowSweep() }

        let rejected = await gridState.isWindowRejected(2884)
        XCTAssertTrue(rejected, "still not tileable")
        XCTAssertEqual(
            mock.refreshCalls.filter { $0 == 2884 }.count,
            StaleSubrolePolicy.maxAttempts,
            "requeries must stop at the budget, not run every 300ms sweep forever"
        )
    }

    // The predicate must not drag popups and tooltips into the requery path.
    func testOnlyRealWindowsRejectedSolelyOnSubroleQualify() {
        // The 445-bail population: real role, real size, AXUnknown subrole.
        XCTAssertTrue(StaleSubrolePolicy.looksStale(
            role: "AXWindow", subrole: "AXUnknown", width: 1900, height: 1060, minDimension: 100
        ))
        // A tooltip -- wrong role.
        XCTAssertFalse(StaleSubrolePolicy.looksStale(
            role: "AXHelpTag", subrole: "AXUnknown", width: 296, height: 22, minDimension: 100
        ))
        // Too small to tile regardless of subrole.
        XCTAssertFalse(StaleSubrolePolicy.looksStale(
            role: "AXWindow", subrole: "AXUnknown", width: 80, height: 60, minDimension: 100
        ))
        // A system dialog is correctly excluded, not a latch victim.
        XCTAssertFalse(StaleSubrolePolicy.looksStale(
            role: "AXWindow", subrole: "AXSystemDialog", width: 900, height: 600, minDimension: 100
        ))
    }

    // A window AX no longer exposes must not burn requeries -- the ghost case.
    func testGhostIsNotRequeried() async {
        let poisoned = window(id: 1130, pid: 39899, subrole: "AXUnknown")
        var wmState = WindowManagerState()
        wmState.metadata.activeSpaceID = 100
        wmState.windows["1130"] = poisoned
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "100", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "100", cellIDs: ["left", "right"])
        let mock = MockStateProvider(state: wmState)
        let reconciler = GridReconciler()
        reconciler._test_setup(stateProvider: mock, gridState: gridState)
        reconciler._test_setAXWindowIDs { _ in [] }   // alive, zero AX windows
        await gridState.rejectWindow(1130)

        await reconciler._test_rejectedWindowSweep()

        XCTAssertTrue(mock.refreshCalls.isEmpty, "no AX requery for a window AX does not expose")
    }
}
