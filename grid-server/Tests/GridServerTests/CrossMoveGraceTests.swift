import XCTest
@testable import GridServer

// DW-D2: GridReconciler records a deliberate cross-space move and the
// displaced-sweep skips that window while it is within the cross-move grace,
// resuming normal behavior after the grace expires.
//
// The displacement DECISION predicate is unit-tested in GraceWindowPolicyTests.
// Here we drive the reconciler's real grace map + real predicate through a
// `_test_` seam so the wiring (noteCrossSpaceMove → grace map → predicate gate)
// is exercised without the full AX/SLS/gridState async stack (live bounce-test
// is the orchestrator's UAT).
final class CrossMoveGraceTests: XCTestCase {

    // A window that recorded a cross-space move is skipped by the sweep while
    // within grace.
    func test_DW_D_2_note_cross_space_move_skips_displaced_sweep() {
        let reconciler = GridReconciler()
        let now: CFAbsoluteTime = 1000.0
        reconciler._test_noteCrossSpaceMove(42, at: now)

        XCTAssertTrue(
            reconciler._test_shouldSkipDisplacedForGrace(wid: 42, now: now + 1.0),
            "window within cross-move grace must be skipped by the displaced sweep"
        )
    }

    // After the grace expires, the sweep resumes normal correction for the
    // window (no skip).
    func test_DW_D_2_after_grace_sweep_resumes() {
        let reconciler = GridReconciler()
        let now: CFAbsoluteTime = 1000.0
        reconciler._test_noteCrossSpaceMove(42, at: now)

        XCTAssertFalse(
            reconciler._test_shouldSkipDisplacedForGrace(wid: 42, now: now + 999.0),
            "after the cross-move grace expires the sweep must resume"
        )
    }

    // A window that never recorded a cross move is never skipped.
    func test_DW_D_2_untracked_window_not_skipped() {
        let reconciler = GridReconciler()
        XCTAssertFalse(
            reconciler._test_shouldSkipDisplacedForGrace(wid: 7, now: 1000.0),
            "a window with no recorded cross move must not be skipped"
        )
    }
}
