import XCTest
@testable import GridServer

// The asymmetric-suppression bug (BUG C). A focus event has two consumers:
// GridReconciler declined external ones while an action owned focus
// (reconcile.focus.suppressed), but StateManager applied them unconditionally.
// So a wid the reconciler had rejected still reached state.metadata and was
// persisted -- and the 300ms focusSweep then propagated that poisoned metadata
// into GridState cell focus. The guard existed, on one of the two consumers.
//
// These pin the flag that lets the second consumer see what the first sees.
final class FocusOwnershipMirrorTests: XCTestCase {

    override func tearDown() {
        FocusOwnership.shared._test_reset()
        super.tearDown()
    }

    // The reconciler's suppression depth must be visible cross-actor, since
    // StateManager cannot block on the reconciler to ask.
    func testReconcilerActionMirrorsOwnershipToTheSharedFlag() async {
        FocusOwnership.shared._test_reset()
        XCTAssertFalse(FocusOwnership.shared.isOwned, "idle: nobody owns focus")

        let reconciler = GridReconciler()
        var ownedInside = false
        _ = await reconciler.executeAction(label: "focus.down") {
            ownedInside = FocusOwnership.shared.isOwned
        }

        XCTAssertTrue(ownedInside, "an in-flight action must own focus")
        XCTAssertFalse(FocusOwnership.shared.isOwned, "ownership released on exit")
    }

    // Actions nest (a layout apply inside a focus command), so the flag is
    // refcounted -- an inner action finishing must not release the outer one.
    func testNestedActionsKeepOwnershipUntilTheOutermostEnds() async {
        FocusOwnership.shared._test_reset()
        let reconciler = GridReconciler()

        var ownedAfterInner = false
        _ = await reconciler.executeAction(label: "outer") {
            _ = await reconciler.executeAction(label: "inner") {}
            ownedAfterInner = FocusOwnership.shared.isOwned
        }

        XCTAssertTrue(ownedAfterInner, "inner action ending must not release the outer")
        XCTAssertFalse(FocusOwnership.shared.isOwned)
    }

    // The action path has logged more action.start than action.end (24 unmatched
    // across one archived log). A stray release must not drive the count
    // negative, which would wedge the flag permanently off and silently restore
    // the original bug.
    func testStrayReleaseCannotWedgeTheFlagOff() {
        FocusOwnership.shared._test_reset()
        FocusOwnership.shared.set(depth: -5)
        XCTAssertFalse(FocusOwnership.shared.isOwned)

        FocusOwnership.shared.set(depth: 1)
        XCTAssertTrue(FocusOwnership.shared.isOwned, "flag still responds after an underflow")
    }
}
