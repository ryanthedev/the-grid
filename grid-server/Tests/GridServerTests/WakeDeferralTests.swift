import XCTest
@testable import GridServer

// A wake at the login screen emptied every cell until restart. Wake work that
// arrives while locked must wait for the unlock, and run exactly once.
final class WakeDeferralTests: XCTestCase {

    func test_wake_while_unlocked_runs_now() {
        var deferral = WakeDeferral()
        XCTAssertTrue(deferral.wake())
        XCTAssertFalse(deferral.unlock(), "nothing was deferred")
    }

    func test_wake_while_locked_runs_once_on_unlock() {
        var deferral = WakeDeferral()
        deferral.lock()
        XCTAssertFalse(deferral.wake())
        XCTAssertFalse(deferral.wake(), "a second locked wake still defers")
        XCTAssertTrue(deferral.unlock())
        XCTAssertFalse(deferral.unlock(), "the deferred wake runs once")
        XCTAssertTrue(deferral.wake(), "unlocked again after the unlock")
    }

    func test_lock_unlock_without_wake_runs_nothing() {
        var deferral = WakeDeferral()
        deferral.lock()
        XCTAssertFalse(deferral.unlock())
    }

    // The reconciler must not refresh layouts while locked (that is what saved
    // the cells empty), and must refresh once the screen unlocks.
    func test_reconciler_holds_wake_and_display_refresh_until_unlock() async {
        // The reconciler holds gridState weakly; keep it alive for the test.
        let gridState = GridState()
        let reconciler = GridReconciler()
        reconciler.setup(
            gridState: gridState,
            gridConfig: GridConfig(),
            stateProvider: StateManager.shared,
            borderRenderer: SimpleBorderManager(connectionID: 0)
        )
        let stubApply = StubGridApply()
        reconciler.setApply(stubApply)

        await reconciler._test_handle(.screenLocked)
        await reconciler._test_handle(.systemWoke)
        await reconciler._test_handle(.displayConnected(displayUUID: "display-1"))
        XCTAssertEqual(stubApply.callCount, 0, "no layout refresh while locked")

        await reconciler._test_handle(.screenUnlocked)
        XCTAssertEqual(stubApply.callCount, 1, "one refresh on unlock")

        await reconciler._test_handle(.screenLocked)
        await reconciler._test_handle(.screenUnlocked)
        XCTAssertEqual(stubApply.callCount, 1, "plain lock/unlock refreshes nothing")
    }
}
