import XCTest
import CoreGraphics
@testable import GridServer

// Phase 3 integration tests against the faked Ports/ (MockWindowController,
// MockStateProvider) and real GridState/GridReconciler. These cover the DW
// items whose contract is behavioral rather than a single pure predicate.
final class FocusOwnershipIntegrationTests: XCTestCase {

    // MARK: - DW-3.1 (#21): focus failure propagates; no spurious double-raise.

    // When the WindowController port reports failure, focusWindowByID throws
    // (state focus is NOT set on a failed focus).
    func test_DW_3_1_focus_failure_throws_and_does_not_set_focus() async {
        let mockWC = MockWindowController()
        mockWC.focusResult = false  // simulate AX/CG/SLPS failure
        let gridState = GridState()

        var wmState = WindowManagerState()
        var window = WindowState(id: 400)
        window.pid = 77
        window.spaces = [100]
        wmState.windows["400"] = window
        let mockState = MockStateProvider(state: wmState)

        let gridFocus = GridFocus()
        gridFocus._test_setup(gridState: gridState, stateProvider: mockState, windowController: mockWC)

        do {
            _ = try await gridFocus.focusWindowByID(400)
            XCTFail("focusWindowByID should throw when the port reports failure")
        } catch GridFocusError.focusFailed(let wid) {
            XCTAssertEqual(wid, 400)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - DW-3.2 (#7): stale-cache scenario does not trigger a second raise.

    // The event-fed cache still names a DIFFERENT (older) window, but the port
    // reported success for our requested window. The fix trusts the successful
    // raise: exactly ONE focusWindow call, no second raise, returns requested.
    func test_DW_3_2_no_double_raise_when_cache_stale() async {
        let mockWC = MockWindowController()
        mockWC.focusResult = true
        let gridState = GridState()

        var wmState = WindowManagerState()
        var target = WindowState(id: 500)
        target.pid = 11
        target.spaces = [100]
        wmState.windows["500"] = target
        // Cache lags: still reports the PREVIOUS window 999 as focused.
        wmState.metadata.focusedWindowID = 999
        let mockState = MockStateProvider(state: wmState)

        let gridFocus = GridFocus()
        gridFocus._test_setup(gridState: gridState, stateProvider: mockState, windowController: mockWC)

        let result = try? await gridFocus.focusWindowByID(500)
        XCTAssertEqual(result, 500, "should return the requested window, not the stale cache value")

        let focusCalls = mockWC.calls.filter {
            if case .focusWindow(let wid, _) = $0 { return wid == 500 }
            return false
        }
        XCTAssertEqual(focusCalls.count, 1, "must NOT issue a second raise off the stale cache")
    }

    // MARK: - DW-3.4 (#13): a window action suppresses the sweep.

    // executeAction is the mechanism the router now wraps "window" commands in.
    // While the action runs, suppression is active — and shouldSweepCorrect
    // therefore returns false (the sweep cannot revert focus mid-move).
    func test_DW_3_4_window_action_suppresses_sweep() async {
        let reconciler = GridReconciler()
        let gridState = GridState()
        let mockState = MockStateProvider()
        reconciler._test_setup(stateProvider: mockState, gridState: gridState)

        var depthDuringAction = -1
        await reconciler.executeAction(label: "window.move") {
            depthDuringAction = reconciler._test_suppressionDepth
        }

        XCTAssertEqual(depthDuringAction, 1, "window action must suppress reconciliation while it runs")
        // With suppression active, the sweep guard refuses to correct.
        XCTAssertFalse(shouldSweepCorrect(
            osWindowFenced: false, cellMateFenced: false,
            genAtStart: 0, genNow: 0, suppressed: true))
        // Action ended -> suppression released.
        XCTAssertEqual(reconciler._test_suppressionDepth, 0)
    }

    // MARK: - DW-3.8 (#42): dead-window prune is awaited before setFocus.

    // Cell has [dead, live]; dead is absent from wmState. cycleFocus must prune
    // dead BEFORE computing the focus index, so GridState focus lands on live.
    func test_DW_3_8_prune_awaited_before_setFocus_picks_live_successor() async {
        let mockWC = MockWindowController()
        let gridState = GridState()

        // Seed GridState: space 100, layout, one cell "main" with [dead, live].
        await gridState._test_setLayout(spaceID: "100", layoutID: "one")
        await gridState._test_setCells(spaceID: "100", cellIDs: ["main"])
        await gridState._test_assignWindow(spaceID: "100", cellID: "main", windowID: 111)  // dead
        await gridState._test_assignWindow(spaceID: "100", cellID: "main", windowID: 222)  // live

        // wmState: only the LIVE window exists; active space 100.
        var wmState = WindowManagerState()
        wmState.metadata.activeSpaceID = 100
        var live = WindowState(id: 222)
        live.pid = 9
        live.spaces = [100]
        wmState.windows["222"] = live
        wmState.metadata.focusedWindowID = 222
        let mockState = MockStateProvider(state: wmState)

        let gridFocus = GridFocus()
        gridFocus._test_setup(gridState: gridState, stateProvider: mockState, windowController: mockWC)

        // cycleFocus forward from the cell — dead must be pruned, live focused.
        let result = try? await gridFocus.cycleFocus(forward: true)
        XCTAssertEqual(result, 222, "should focus the live successor, not the dead window")

        // GridState focus must resolve to the live window (index computed on the
        // pruned list). If the prune raced setFocus, this would be 111 or stale.
        let focused = await gridState.getFocusedWindow(spaceID: "100")
        XCTAssertEqual(focused, 222, "GridState focus must index the pruned list")

        // Dead window removed from the cell.
        let cellWindows = await gridState.getCellWindows(spaceID: "100", cellID: "main")
        XCTAssertFalse(cellWindows.contains(111), "dead window should be pruned from GridState")
    }

    // MARK: - DW-3.9 (#30): minimize frees the slot on the window's tracked space.

    // Window 700 is tracked on space 200 (a NON-active space); active space is
    // 100. Minimizing it must free its slot on space 200, not no-op on 100.
    func test_DW_3_9_minimize_frees_slot_on_nonfocused_space() async {
        let gridState = GridState()

        // Space 200 holds the window in cell "c"; space 100 is the active one.
        await gridState._test_setLayout(spaceID: "200", layoutID: "one")
        await gridState._test_setCells(spaceID: "200", cellIDs: ["c"])
        await gridState._test_assignWindow(spaceID: "200", cellID: "c", windowID: 700)

        // Active space is 100 (a DIFFERENT space/display).
        var wmState = WindowManagerState()
        wmState.metadata.activeSpaceID = 100
        var win = WindowState(id: 700)
        win.pid = 5
        win.spaces = [200]
        wmState.windows["700"] = win
        let mockState = MockStateProvider(state: wmState)

        let reconciler = GridReconciler()
        reconciler._test_setup(stateProvider: mockState, gridState: gridState)

        // Pre-check: window is assigned on space 200.
        let before = await gridState.getCellWindows(spaceID: "200", cellID: "c")
        XCTAssertTrue(before.contains(700))

        // Drive the minimize event.
        await reconciler._test_handle(.windowMinimized(windowID: 700))

        // The slot on the TRACKED space (200) must be freed, regardless of the
        // active space being 100.
        let after = await gridState.getCellWindows(spaceID: "200", cellID: "c")
        XCTAssertFalse(after.contains(700), "minimize must free the slot on the window's tracked space")
    }
}
