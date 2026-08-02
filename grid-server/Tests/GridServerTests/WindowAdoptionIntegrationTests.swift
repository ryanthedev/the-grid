import XCTest
import CoreGraphics
@testable import GridServer

// Phase 4 integration tests against the faked Ports/ (MockWindowController,
// MockStateProvider) and real GridState/GridReconciler. These cover the DW
// items whose contract is behavioral rather than a single pure predicate.
final class WindowAdoptionIntegrationTests: XCTestCase {

    // Build a tileable window state.
    private func makeTileable(id: UInt32, pid: pid_t, space: UInt64, app: String) -> WindowState {
        var w = WindowState(id: id)
        w.pid = pid
        w.role = "AXWindow"
        w.subrole = "AXStandardWindow"
        w.hasCloseButton = true
        w.hasFullscreenButton = true
        w.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        w.spaces = [space]
        w.appName = app
        return w
    }

    private func makeDisplay(uuid: String, space: UInt64) -> DisplayState {
        var d = DisplayState(uuid: uuid, currentSpaceID: space, spaces: [space])
        d.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        d.visibleFrame = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        return d
    }

    // MARK: - DW-4.2 (#18): pending consumed before first await.

    // Two interleaved pending-launch invocations (event path + sweep) must not
    // both claim the cell: the second observes a nil target (consume-before-await).
    func test_DW_4_2_consume_before_await_single_claim() async {
        var wmState = WindowManagerState()
        wmState.metadata.activeSpaceID = 100
        var win = makeTileable(id: 500, pid: 9, space: 100, app: "PickedApp")
        win.isModal = false
        wmState.windows["500"] = win
        wmState.displays = [makeDisplay(uuid: "display-1", space: 100)]
        wmState.spaces["100"] = SpaceState(id: 100, uuid: "u", type: "user", displayUUID: "display-1")
        wmState.applications["9"] = ApplicationState._test_make(pid: 9, name: "PickedApp")

        let mock = MockStateProvider(state: wmState)
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "100", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "100", cellIDs: ["left", "right"])

        let reconciler = GridReconciler()
        reconciler._test_setup(stateProvider: mock, gridState: gridState)
        reconciler._test_setPendingLaunchTarget(
            PendingLaunchTarget(spaceID: "100", cellID: "left",
                                createdAt: CFAbsoluteTimeGetCurrent(), bundleID: nil, pid: 9)
        )

        // First invocation consumes the target.
        await reconciler._test_handlePendingLaunchWindow(windowID: 500, pid: 9)
        // Target must be nil now — a second invocation cannot re-claim.
        XCTAssertNil(reconciler._test_pendingLaunchTarget(),
                     "target must be consumed before the first await")

        await reconciler._test_handlePendingLaunchWindow(windowID: 500, pid: 9)

        // Window appears exactly once in the left cell.
        let left = await gridState.getCellWindows(spaceID: "100", cellID: "left")
        XCTAssertEqual(left.filter { $0 == 500 }.count, 1, "exactly one placement")
    }

    // MARK: - DW-4.3 (#31): pid-less target rejects a foreign window by bundle id.

    func test_DW_4_3_pidless_target_rejects_foreign_window() async {
        var wmState = WindowManagerState()
        wmState.metadata.activeSpaceID = 100
        // Foreign window from a DIFFERENT app appears during launch latency.
        let foreign = makeTileable(id: 600, pid: 42, space: 100, app: "ForeignApp")
        wmState.windows["600"] = foreign
        wmState.displays = [makeDisplay(uuid: "display-1", space: 100)]
        wmState.spaces["100"] = SpaceState(id: 100, uuid: "u", type: "user", displayUUID: "display-1")
        wmState.applications["42"] = ApplicationState._test_make(
            pid: 42, name: "ForeignApp", bundleID: "com.foreign.app")

        let mock = MockStateProvider(state: wmState)
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "100", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "100", cellIDs: ["left", "right"])

        let reconciler = GridReconciler()
        reconciler._test_setup(stateProvider: mock, gridState: gridState)
        // Target armed for a DIFFERENT bundle id, pid still unknown.
        reconciler._test_setPendingLaunchTarget(
            PendingLaunchTarget(spaceID: "100", cellID: "left",
                                createdAt: CFAbsoluteTimeGetCurrent(),
                                bundleID: "com.picked.app", pid: nil)
        )

        await reconciler._test_handlePendingLaunchWindow(windowID: 600, pid: 42)

        // The target must remain armed (re-armed) for the real picked window —
        // a foreign window may not consume a pid-less bundle-matched target.
        // (The foreign window itself falls through to ordinary auto-assign.)
        let target = reconciler._test_pendingLaunchTarget()
        XCTAssertNotNil(target, "target must stay armed after rejecting a foreign window")
        XCTAssertEqual(target?.cellID, "left", "the original reserved cell is preserved")
    }

    func test_DW_4_3_pidless_target_accepts_matching_bundle() async {
        var wmState = WindowManagerState()
        wmState.metadata.activeSpaceID = 100
        let picked = makeTileable(id: 700, pid: 50, space: 100, app: "PickedApp")
        wmState.windows["700"] = picked
        wmState.displays = [makeDisplay(uuid: "display-1", space: 100)]
        wmState.spaces["100"] = SpaceState(id: 100, uuid: "u", type: "user", displayUUID: "display-1")
        wmState.applications["50"] = ApplicationState._test_make(
            pid: 50, name: "PickedApp", bundleID: "com.picked.app")

        let mock = MockStateProvider(state: wmState)
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "100", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "100", cellIDs: ["left", "right"])

        let reconciler = GridReconciler()
        reconciler._test_setup(stateProvider: mock, gridState: gridState)
        reconciler._test_setPendingLaunchTarget(
            PendingLaunchTarget(spaceID: "100", cellID: "left",
                                createdAt: CFAbsoluteTimeGetCurrent(),
                                bundleID: "com.picked.app", pid: nil)
        )

        await reconciler._test_handlePendingLaunchWindow(windowID: 700, pid: 50)

        let left = await gridState.getCellWindows(spaceID: "100", cellID: "left")
        XCTAssertTrue(left.contains(700), "matching-bundle window claims the target")
        XCTAssertNil(reconciler._test_pendingLaunchTarget(), "target consumed on a real claim")
    }

    // MARK: - DW-4.4 (#32): locked cell on an inactive space moves the window.

    func test_DW_4_4_locked_cell_inactive_space_moves_window() async {
        var wmState = WindowManagerState()
        // Active display shows space 100. The locked cell lives on space 200,
        // which is NOT visible on any display.
        wmState.metadata.activeSpaceID = 100
        let win = makeTileable(id: 800, pid: 7, space: 100, app: "Terminal")
        wmState.windows["800"] = win
        wmState.displays = [makeDisplay(uuid: "display-1", space: 100)]
        wmState.spaces["100"] = SpaceState(id: 100, uuid: "u1", type: "user", displayUUID: "display-1")
        wmState.spaces["200"] = SpaceState(id: 200, uuid: "u2", type: "user", displayUUID: "display-1")
        wmState.applications["7"] = ApplicationState._test_make(pid: 7, name: "Terminal")

        let mock = MockStateProvider(state: wmState)
        let gridState = GridState()
        // Both spaces have layouts; the locked cell "right" exists only on 200.
        await gridState._test_setLayout(spaceID: "100", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "100", cellIDs: ["left"])
        await gridState._test_setLayout(spaceID: "200", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "200", cellIDs: ["right"])

        let mockWC = MockWindowController()
        let reconciler = GridReconciler()
        reconciler._test_setup(
            stateProvider: mock,
            gridState: gridState,
            lockedRules: [GridAppRule(app: "Terminal", preferredCell: "right", float: false, locked: true)]
        )
        reconciler._test_setWindowController(mockWC)

        await reconciler._test_triggerWindowCreated(windowID: 800, pid: 7)

        // The window is assigned to the locked cell on the inactive space...
        let right = await gridState.getCellWindows(spaceID: "200", cellID: "right")
        XCTAssertTrue(right.contains(800), "window assigned to locked cell on inactive space")
        // ...and moved there (so the displacement sweep does not bounce it back).
        let moved = mockWC.calls.contains {
            if case .moveWindowToSpace(let wid, let sp) = $0 { return wid == 800 && sp == 200 }
            return false
        }
        XCTAssertTrue(moved, "must moveWindowToSpace for an inactive locked-cell space (#32)")
    }

    // MARK: - DW-4.7 (#57): a pending claim survives a suppressed apply (queue-not-clobber).

    // The claim is applied at suppressionDepth 0 (via the sweep/replay path),
    // not raced into a live apply. We assert the claim survives an executeAction
    // that suppresses around it: the window is still tracked afterwards.
    func test_DW_4_7_pending_claim_survives_suppressed_apply() async {
        var wmState = WindowManagerState()
        wmState.metadata.activeSpaceID = 100
        let win = makeTileable(id: 900, pid: 11, space: 100, app: "PickedApp")
        wmState.windows["900"] = win
        wmState.displays = [makeDisplay(uuid: "display-1", space: 100)]
        wmState.spaces["100"] = SpaceState(id: 100, uuid: "u", type: "user", displayUUID: "display-1")
        wmState.applications["11"] = ApplicationState._test_make(pid: 11, name: "PickedApp")

        let mock = MockStateProvider(state: wmState)
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "100", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "100", cellIDs: ["left", "right"])

        let reconciler = GridReconciler()
        reconciler._test_setup(stateProvider: mock, gridState: gridState)
        reconciler._test_setPendingLaunchTarget(
            PendingLaunchTarget(spaceID: "100", cellID: "left",
                                createdAt: CFAbsoluteTimeGetCurrent(), bundleID: nil, pid: 11)
        )

        // Run a suppressed action; the pending claim happens at depth 0.
        _ = await reconciler.executeAction(label: "apply") {
            // no-op body; suppression is active here
        }
        await reconciler._test_handlePendingLaunchWindow(windowID: 900, pid: 11)

        let left = await gridState.getCellWindows(spaceID: "100", cellID: "left")
        XCTAssertTrue(left.contains(900), "claim must not be clobbered (#57)")
    }

    // MARK: - DW-4.8 (#12): untracked tileable adopted at depth 0.

    func test_DW_4_8_adopt_untracked_tileable_at_depth0() async {
        var wmState = WindowManagerState()
        wmState.metadata.activeSpaceID = 100
        // A tileable window StateManager knows about but GridState never tiled
        // (its create was dropped during suppression).
        let orphan = makeTileable(id: 1000, pid: 21, space: 100, app: "DroppedApp")
        wmState.windows["1000"] = orphan
        wmState.displays = [makeDisplay(uuid: "display-1", space: 100)]
        wmState.spaces["100"] = SpaceState(id: 100, uuid: "u", type: "user", displayUUID: "display-1")
        wmState.applications["21"] = ApplicationState._test_make(pid: 21, name: "DroppedApp")

        let mock = MockStateProvider(state: wmState)
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "100", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "100", cellIDs: ["left", "right"])

        let reconciler = GridReconciler()
        reconciler._test_setup(stateProvider: mock, gridState: gridState)

        // Precondition: window is NOT tracked.
        let before = await gridState.findSpaceContaining(windowID: 1000)
        XCTAssertNil(before, "window starts untracked")

        await reconciler._test_adoptUntrackedTileables()

        // It is adopted into a cell.
        let space = await gridState.findSpaceContaining(windowID: 1000)
        XCTAssertEqual(space, "100", "untracked tileable adopted at depth 0 (#12)")
    }

    // MARK: - DW-4.6 (#41): not_standard re-evaluated within grace, then tiles.

    func test_DW_4_6_not_standard_reeval_tiles_after_grace_sweep() async {
        var wmState = WindowManagerState()
        wmState.metadata.activeSpaceID = 100
        // Window classified floating at creation (no fullscreen button).
        var win = makeTileable(id: 1100, pid: 31, space: 100, app: "SlowButtonApp")
        win.hasFullscreenButton = false
        wmState.windows["1100"] = win
        wmState.displays = [makeDisplay(uuid: "display-1", space: 100)]
        wmState.spaces["100"] = SpaceState(id: 100, uuid: "u", type: "user", displayUUID: "display-1")
        wmState.applications["31"] = ApplicationState._test_make(pid: 31, name: "SlowButtonApp")

        let mock = MockStateProvider(state: wmState)
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "100", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "100", cellIDs: ["left", "right"])

        let reconciler = GridReconciler()
        reconciler._test_setup(stateProvider: mock, gridState: gridState)

        // Create: classifies not_standard, records grace, does not tile.
        await reconciler._test_triggerWindowCreated(windowID: 1100, pid: 31)
        XCTAssertEqual(reconciler._test_notStandardGraceCount, 1, "tracked for grace re-eval")
        let untiled = await gridState.findSpaceContaining(windowID: 1100)
        XCTAssertNil(untiled, "not tiled at creation")

        // The window's buttons populate (now standard); the grace sweep re-evals.
        wmState.windows["1100"]?.hasFullscreenButton = true
        mock.state = wmState
        await reconciler._test_notStandardGraceSweep()

        let tiled = await gridState.findSpaceContaining(windowID: 1100)
        XCTAssertEqual(tiled, "100", "slow-button window tiles on grace re-eval (#41)")
        XCTAssertEqual(reconciler._test_notStandardGraceCount, 0, "grace entry cleared after success")
    }
}
