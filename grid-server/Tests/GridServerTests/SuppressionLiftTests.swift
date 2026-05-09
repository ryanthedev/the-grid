import XCTest
@testable import GridServer

// Tests for Phase 2 of the suppression-lift-sweep plan.
//
// Validates all four decision branches of sweepDisplacedWindows() via the
// extracted pure helper GridReconciler.resolveDisplacedTarget(...).
//
// No actor wiring is needed — the helper takes only value-type arguments
// and returns a String? encoding the migration decision.
//
// Branch map:
//   DW-2.1 — no displacement (window still on tracked space)   → nil
//   DW-2.2 — clean migration (exactly one tracked candidate)   → targetSpaceID
//   DW-2.3 — ambiguous skip (two actual spaces, both tracked)  → nil
//   DW-2.4 — untracked target (actual space not in GridState)  → nil

final class SuppressionLiftTests: XCTestCase {

    // MARK: - DW-2.1: No displacement — window still on its tracked space

    // trackedSpaceID: "3"
    // actualSpaces: [3, 5]  — includes 3, so no displacement
    // knownSpaceIDs: {"3", "5"}
    // Expected: nil (no migration)
    func test_DW_2_1_noDisplacement_returnsNil() {
        let result = GridReconciler.resolveDisplacedTarget(
            trackedSpaceID: "3",
            actualSpaces: [3, 5],
            knownSpaceIDs: ["3", "5"]
        )
        XCTAssertNil(result,
            "window still present on tracked space — must not migrate")
    }

    // MARK: - DW-2.2: Clean migration — one unambiguous target in GridState

    // trackedSpaceID: "3"
    // actualSpaces: [6]     — 3 absent, exactly one candidate that GridState tracks
    // knownSpaceIDs: {"3", "6"}
    // Expected: "6"
    func test_DW_2_2_cleanMigration_returnsTargetSpaceID() {
        let result = GridReconciler.resolveDisplacedTarget(
            trackedSpaceID: "3",
            actualSpaces: [6],
            knownSpaceIDs: ["3", "6"]
        )
        XCTAssertEqual(result, "6",
            "window displaced to exactly one tracked space — must return that space ID")
    }

    // MARK: - DW-2.3: Ambiguous skip — window on two actual spaces, both tracked

    // trackedSpaceID: "3"
    // actualSpaces: [5, 6]  — 3 absent, but two candidates both in GridState
    // knownSpaceIDs: {"3", "5", "6"}
    // Expected: nil (ambiguous, don't guess)
    func test_DW_2_3_ambiguousSpaces_returnsNil() {
        let result = GridReconciler.resolveDisplacedTarget(
            trackedSpaceID: "3",
            actualSpaces: [5, 6],
            knownSpaceIDs: ["3", "5", "6"]
        )
        XCTAssertNil(result,
            "window displaced to two tracked spaces — must skip (ambiguous)")
    }

    // MARK: - DW-2.4: Untracked target — actual space not managed by GridState

    // trackedSpaceID: "3"
    // actualSpaces: [99]    — 3 absent, 99 is not in knownSpaceIDs
    // knownSpaceIDs: {"3", "5"}
    // Expected: nil (target space is unmanaged)
    func test_DW_2_4_untrackedTarget_returnsNil() {
        let result = GridReconciler.resolveDisplacedTarget(
            trackedSpaceID: "3",
            actualSpaces: [99],
            knownSpaceIDs: ["3", "5"]
        )
        XCTAssertNil(result,
            "window displaced to an untracked space — must skip (unmanaged target)")
    }
}
