import XCTest
@testable import GridServer

// Phase 1 — DW-1.4 (#4): the reconciler's long-lived action session is
// consume-once. A racing duplicate endAction (e.g. two @nudge exit submits)
// must NOT strip another session's suppression.
//
// These exercise the REAL GridReconciler.beginAction/endAction wiring (not just
// the underlying registry). beginAction/endAction only touch suppressionDepth,
// the generation counter, and the token registry; the depth-0 border sync runs
// in a detached Task that no-ops with nil dependencies, so a bare reconciler is
// sufficient to assert the suppression accounting.

final class ReconcilerActionTokenTests: XCTestCase {

    func test_DW_1_4_double_endAction_same_token_does_not_underflow_other_session() {
        let reconciler = GridReconciler()

        // Two overlapping sessions: depth becomes 2.
        let a = reconciler.beginAction(label: "nudge")
        let b = reconciler.beginAction(label: "picker")
        XCTAssertEqual(reconciler._test_suppressionDepth, 2)

        // End session A once — depth 1.
        reconciler.endAction(a, syncBorders: false)
        XCTAssertEqual(reconciler._test_suppressionDepth, 1)

        // A racing duplicate end of the SAME token A must be rejected (consume-once):
        // it must NOT decrement again and strip session B's suppression.
        reconciler.endAction(a, syncBorders: false)
        XCTAssertEqual(reconciler._test_suppressionDepth, 1,
            "duplicate endAction for an already-consumed token is a no-op")

        // Ending session B properly returns to 0.
        reconciler.endAction(b, syncBorders: false)
        XCTAssertEqual(reconciler._test_suppressionDepth, 0)
    }

    func test_DW_1_7_generation_increments_on_each_begin() {
        let reconciler = GridReconciler()
        let g0 = reconciler.generation
        let a = reconciler.beginAction(label: "x")
        let g1 = reconciler.generation
        let b = reconciler.beginAction(label: "y")
        let g2 = reconciler.generation
        XCTAssertGreaterThan(g1, g0, "generation bumps on beginAction")
        XCTAssertGreaterThan(g2, g1, "generation bumps again on next beginAction")
        reconciler.endAction(a, syncBorders: false)
        reconciler.endAction(b, syncBorders: false)
    }

    // DW-1.3 (#14): the reconciler's fence is refcounted through its public API —
    // acquire×2 / release×1 leaves the window fenced; a second release clears it;
    // releasing an unheld window is a no-op.
    func test_DW_1_3_reconciler_fence_is_refcounted() {
        let reconciler = GridReconciler()
        reconciler.acquireFence(windowIDs: [42], reason: "moveA")
        reconciler.acquireFence(windowIDs: [42], reason: "moveB")
        reconciler.releaseFence(windowIDs: [42])
        XCTAssertTrue(reconciler._test_isFenced(42),
            "still fenced after one of two releases (overlapping moves)")
        reconciler.releaseFence(windowIDs: [42])
        XCTAssertFalse(reconciler._test_isFenced(42),
            "cleared after both releases reach refcount 0")
        // Releasing an unheld window is a harmless no-op.
        reconciler.releaseFence(windowIDs: [999])
        XCTAssertFalse(reconciler._test_isFenced(999))
    }

    // DW-1.6 (#12): window create/destroy arriving during suppression are queued,
    // not dropped. A bare reconciler with no gridState still queues them (the
    // enqueue happens before any handler work).
    func test_DW_1_6_create_destroy_queued_while_suppressed() async {
        let reconciler = GridReconciler()
        let token = reconciler.beginAction(label: "suppressing")
        XCTAssertEqual(reconciler._test_suppressedQueueCount, 0)

        await reconciler._test_handle(.windowCreated(windowID: 700, pid: 0))
        await reconciler._test_handle(.windowDestroyed(windowID: 701))

        XCTAssertEqual(reconciler._test_suppressedQueueCount, 2,
            "create + destroy queued during suppression instead of being dropped")

        // Ending the session drains the queue (replay runs in a detached Task).
        reconciler.endAction(token, syncBorders: false)
        // Give the detached replay task a moment to drain.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(reconciler._test_suppressedQueueCount, 0,
            "queue drained on return to depth 0")
    }
}
