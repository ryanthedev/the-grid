import XCTest
@testable import GridServer

// Pure-predicate tests for GraceWindowPolicy (DW-D1, DW-D3).
//
// Both predicates are number-line in-range checks over CFAbsoluteTime with a
// nil-guard. Tested off the OS boundary — no AX/SLS, no reconciler/actor stack.
final class GraceWindowPolicyTests: XCTestCase {

    private let grace: CFAbsoluteTime = 5.0

    // MARK: - DW-D1: withinCrossMoveGrace

    // nil stamp (window never recorded a cross move) ⇒ false.
    func test_DW_D_1_nil_movedAt_returns_false() {
        XCTAssertFalse(
            GraceWindowPolicy.withinCrossMoveGrace(movedAt: nil, now: 100.0, graceSeconds: grace)
        )
    }

    // A move 1s ago with a 5s grace is still within grace ⇒ true.
    func test_DW_D_1_recent_move_within_grace_returns_true() {
        XCTAssertTrue(
            GraceWindowPolicy.withinCrossMoveGrace(movedAt: 99.0, now: 100.0, graceSeconds: grace)
        )
    }

    // Exactly at the grace boundary (now - movedAt == grace) ⇒ false (strict <).
    func test_DW_D_1_at_grace_boundary_returns_false() {
        XCTAssertFalse(
            GraceWindowPolicy.withinCrossMoveGrace(movedAt: 95.0, now: 100.0, graceSeconds: grace)
        )
    }

    // Move older than grace ⇒ false.
    func test_DW_D_1_after_grace_returns_false() {
        XCTAssertFalse(
            GraceWindowPolicy.withinCrossMoveGrace(movedAt: 90.0, now: 100.0, graceSeconds: grace)
        )
    }

    // MARK: - DW-D3: isResurrection

    // nil stamp (wid never removed / never tombstoned) ⇒ false.
    func test_DW_D_3_nil_removedAt_returns_false() {
        XCTAssertFalse(
            GraceWindowPolicy.isResurrection(removedAt: nil, now: 100.0, graceSeconds: grace)
        )
    }

    // Removed 1s ago, poll re-adds within grace ⇒ genuine resurrection ⇒ true.
    func test_DW_D_3_recent_removal_returns_true() {
        XCTAssertTrue(
            GraceWindowPolicy.isResurrection(removedAt: 99.0, now: 100.0, graceSeconds: grace)
        )
    }

    // Exactly at the grace boundary ⇒ false (strict <).
    func test_DW_D_3_at_grace_boundary_returns_false() {
        XCTAssertFalse(
            GraceWindowPolicy.isResurrection(removedAt: 95.0, now: 100.0, graceSeconds: grace)
        )
    }

    // Tombstone older than grace ⇒ stale ⇒ false (would have been pruned).
    func test_DW_D_3_expired_returns_false() {
        XCTAssertFalse(
            GraceWindowPolicy.isResurrection(removedAt: 90.0, now: 100.0, graceSeconds: grace)
        )
    }
}
