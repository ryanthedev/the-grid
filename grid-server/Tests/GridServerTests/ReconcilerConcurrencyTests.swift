import XCTest
@testable import GridServer

/// GridReconciler is a plain class whose `handle()` runs on the global pool:
/// EventRouter awaits each handler, and the actor lets the next route() start
/// meanwhile, so events for the same reconciler run in parallel. These tests
/// drive that parallelism; run them under `swift test --sanitize=thread` to see
/// a data race (they pass without TSan either way).
final class ReconcilerConcurrencyTests: XCTestCase {

    private func makeReconciler() async -> (GridReconciler, MockStateProvider) {
        var wmState = WindowManagerState()
        var win = WindowState(id: 100)
        win.appName = "App"
        win.role = "AXWindow"
        win.subrole = "AXStandardWindow"
        win.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        wmState.windows["100"] = win
        wmState.spaces["1"] = SpaceState(id: 1, uuid: "u1", type: "user", displayUUID: "d1")

        let stateProvider = MockStateProvider(state: wmState)
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "1", layoutID: "test")
        await gridState._test_setCells(spaceID: "1", cellIDs: ["main"])
        await gridState._test_assignWindow(spaceID: "1", cellID: "main", windowID: 100)

        let reconciler = GridReconciler()
        reconciler._test_setup(stateProvider: stateProvider, gridState: gridState)
        reconciler._test_setAXWindowIDs { _ in [100] }
        return (reconciler, stateProvider)
    }

    // A burst of move events (any window drag) each reschedules the membership
    // sweep, cancelling and replacing the same Task reference from parallel
    // threads. A double release of that Task fits the ska heap-corruption crash.
    func test_parallel_window_moves_reschedule_membership_sweep_safely() async {
        let (reconciler, provider) = await makeReconciler()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let frame = CGRect(x: Double(i), y: 0, width: 800, height: 600)
                    await reconciler._test_handle(.windowMoved(windowID: 100, frame: frame))
                }
            }
        }
        withExtendedLifetime(provider) {}
    }

    // Move commands fence windows while focus handling reads the fence and
    // commands await wake completion, all from different tasks.
    func test_parallel_fence_and_wake_access_is_safe() async {
        let (reconciler, provider) = await makeReconciler()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let wid = UInt32(100 + i % 5)
                    reconciler.acquireFence(windowIDs: [wid], reason: "test")
                    _ = reconciler._test_isWindowFenced(wid)
                    await reconciler.awaitWakeCompletion()
                    reconciler.releaseFence(windowIDs: [wid])
                }
            }
        }
        for i in 0..<5 {
            XCTAssertFalse(reconciler._test_isWindowFenced(UInt32(100 + i)), "every acquire was released")
        }
        withExtendedLifetime(provider) {}
    }
}
