import XCTest
@testable import GridServer

// The adopt/prune loop (BUG A). Four kitty windows whose processes were alive
// but exposed zero AX windows cycled
//   validate.win.untracked -> reconcile.win.create -> ax.fail(not_in_list)
//   -> validate.win.prune(ax_orphan) -> repeat
// 154 times each over six days. Adoption answered from the cached
// WindowState.role, which latches at discovery and is re-queried only when nil;
// pruning answered from a live AX query. The two halves contradicted each other
// forever, and while a ghost sat in a cell it broke directional focus and
// failed layout placement.
//
// These pin the gate that makes both halves consult one oracle.
final class ZombieAdoptionLoopTests: XCTestCase {

    // Local copies of the WindowAdoptionIntegrationTests fixtures (private there).
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

    private func ghostState() -> WindowManagerState {
        var wmState = WindowManagerState()
        wmState.metadata.activeSpaceID = 100
        // Reads perfectly tileable from cache -- real role, real dimensions --
        // which is exactly why the old code kept re-adopting it.
        wmState.windows["1130"] = makeTileable(id: 1130, pid: 39899, space: 100, app: "kitty")
        wmState.displays = [makeDisplay(uuid: "display-1", space: 100)]
        wmState.spaces["100"] = SpaceState(id: 100, uuid: "u", type: "user", displayUUID: "display-1")
        wmState.applications["39899"] = ApplicationState._test_make(pid: 39899, name: "kitty")
        return wmState
    }

    // GridReconciler holds stateProvider weakly, so the mock must be returned
    // and kept alive by the caller or every handler bails on no_stateProvider.
    private func wire(
        _ wmState: WindowManagerState
    ) async -> (GridReconciler, GridState, MockStateProvider) {
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "100", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "100", cellIDs: ["left", "right"])
        let mock = MockStateProvider(state: wmState)
        let reconciler = GridReconciler()
        reconciler._test_setup(stateProvider: mock, gridState: gridState)
        return (reconciler, gridState, mock)
    }

    // The loop itself: a live process exposing no AX windows must not be
    // adopted, however tileable its cached properties look.
    func testGhostWindowIsNotAdoptedWhenAppExposesNoAXWindows() async {
        let (reconciler, gridState, mock) = await wire(ghostState())
        withExtendedLifetime(mock) {}
        reconciler._test_setAXWindowIDs { _ in [] }   // alive, zero AX windows

        await reconciler._test_adoptUntrackedTileables()

        let space = await gridState.findSpaceContaining(windowID: 1130)
        XCTAssertNil(space, "a window absent from its app's live AX list must not be adopted")
    }

    // The pruner skips a pid it could not query; adoption must abstain on the
    // same unknown, or the two halves resume contradicting each other.
    func testUnreachableAppAdoptsNothingRatherThanGuessing() async {
        let (reconciler, gridState, mock) = await wire(ghostState())
        withExtendedLifetime(mock) {}
        reconciler._test_setAXWindowIDs { _ in nil }  // busy/unreachable

        await reconciler._test_adoptUntrackedTileables()

        let space = await gridState.findSpaceContaining(windowID: 1130)
        XCTAssertNil(space, "unknown AX state must adopt nothing, not assume presence")
    }

    // Guard against over-correction: a real window still present over AX has to
    // keep being adopted, or the gate would break the feature it protects.
    func testLiveWindowIsStillAdopted() async {
        let (reconciler, gridState, mock) = await wire(ghostState())
        withExtendedLifetime(mock) {}
        reconciler._test_setAXWindowIDs { pid in pid == 39899 ? [1130] : [] }

        await reconciler._test_adoptUntrackedTileables()

        let space = await gridState.findSpaceContaining(windowID: 1130)
        XCTAssertEqual(space, "100", "a window AX still exposes must be adopted as before")
    }

    // An ax_orphan prune is not a death: SkyLight still reports bounds and the
    // process is alive. Clearing the wid's rejection there made a pruned ghost
    // *more* adoptable next pass, which is what closed the loop.
    func testAXOrphanPruneKeepsTheRejectionFlag() async {
        let gridState = GridState()
        await gridState.rejectWindow(1130)

        await gridState.removeWindowFromAllSpaces(1130, forgetRejection: false)
        let stillRejected = await gridState.isWindowRejected(1130)
        XCTAssertTrue(stillRejected, "ax_orphan prune must not clear the rejection")

        // A genuine destroy still clears it -- the id can be reused.
        await gridState.removeWindowFromAllSpaces(1130)
        let clearedOnDestroy = await gridState.isWindowRejected(1130)
        XCTAssertFalse(clearedOnDestroy, "a real destroy must release the wid")
    }
}
