import XCTest
import ApplicationServices
@testable import GridServer

// Phase 4 pure-predicate unit tests. These exercise the creation/classification/
// adoption decision logic off the AX/SkyLight/timer boundary
// (docs/code-standards.md testing pattern).
final class WindowAdoptionPolicyTests: XCTestCase {

    // MARK: - DW-4.1 (#15): sole-window fallback guard reused in WindowManipulator.

    // WindowManipulator must reuse the EXACT StateManager helper (no fork).
    // A phantom whose sole AX window resolves to a different concrete id must
    // NOT substitute the real window.
    func test_DW_4_1_resolvable_different_id_rejects_phantom() {
        XCTAssertFalse(
            StateManager.shouldUseSoleWindowFallback(
                resolved: .success, soleWindowID: 2167, queriedID: 2168
            )
        )
    }

    func test_DW_4_1_unresolvable_promotes_ghostty_case() {
        XCTAssertTrue(
            StateManager.shouldUseSoleWindowFallback(
                resolved: .cannotComplete, soleWindowID: 0, queriedID: 2168
            )
        )
    }

    // MARK: - DW-4.2/4.3 (#18,#31): pending-launch bundle-id match.

    // A pid-less target requires a bundle-id match — a foreign app's window
    // must NOT claim it (the first-come hole).
    func test_DW_4_3_pidless_target_rejects_foreign_bundle() {
        XCTAssertFalse(
            PendingLaunchPolicy.matchesTarget(
                windowBundleID: "com.foreign.app",
                targetBundleID: "com.picked.app",
                windowPID: 123,
                targetPID: nil
            )
        )
    }

    func test_DW_4_3_pidless_target_accepts_matching_bundle() {
        XCTAssertTrue(
            PendingLaunchPolicy.matchesTarget(
                windowBundleID: "com.picked.app",
                targetBundleID: "com.picked.app",
                windowPID: 123,
                targetPID: nil
            )
        )
    }

    // Once the PID is known it is authoritative: wrong pid rejected, right pid
    // accepted, regardless of bundle id.
    func test_DW_4_3_known_pid_is_authoritative() {
        XCTAssertFalse(
            PendingLaunchPolicy.matchesTarget(
                windowBundleID: "com.picked.app",
                targetBundleID: "com.picked.app",
                windowPID: 999,
                targetPID: 123
            )
        )
        XCTAssertTrue(
            PendingLaunchPolicy.matchesTarget(
                windowBundleID: nil,
                targetBundleID: "com.picked.app",
                windowPID: 123,
                targetPID: 123
            )
        )
    }

    // No pid and no bundle id — unconstrained target accepts (legacy fallback).
    func test_DW_4_3_unconstrained_target_accepts() {
        XCTAssertTrue(
            PendingLaunchPolicy.matchesTarget(
                windowBundleID: nil, targetBundleID: nil, windowPID: 1, targetPID: nil
            )
        )
    }

    // MARK: - DW-4.6 (#41): not_standard grace window.

    func test_DW_4_6_within_grace_reevaluates() {
        XCTAssertTrue(
            NotStandardGracePolicy.shouldReevaluate(
                now: 100.0, firstSeen: 98.0, graceWindow: 3.0
            )
        )
    }

    func test_DW_4_6_expired_grace_drops() {
        XCTAssertFalse(
            NotStandardGracePolicy.shouldReevaluate(
                now: 100.0, firstSeen: 96.0, graceWindow: 3.0
            )
        )
    }

    func test_DW_4_6_boundary_is_inclusive() {
        XCTAssertTrue(
            NotStandardGracePolicy.shouldReevaluate(
                now: 100.0, firstSeen: 97.0, graceWindow: 3.0
            )
        )
    }

    // MARK: - DW-4.8 (#12): untracked-tileable adoption decision.

    func test_DW_4_8_tileable_unassigned_is_adopted() {
        XCTAssertTrue(
            AdoptionPolicy.isUntrackedTileable(isTileable: true, isAssignedAnywhere: false)
        )
    }

    func test_DW_4_8_tileable_already_assigned_not_adopted() {
        XCTAssertFalse(
            AdoptionPolicy.isUntrackedTileable(isTileable: true, isAssignedAnywhere: true)
        )
    }

    func test_DW_4_8_non_tileable_not_adopted() {
        XCTAssertFalse(
            AdoptionPolicy.isUntrackedTileable(isTileable: false, isAssignedAnywhere: false)
        )
    }

    // MARK: - DW-4.5 (#40): observer-register retry backoff schedule.

    func test_DW_4_5_backoff_schedule_then_gives_up() {
        XCTAssertEqual(ObserverRetryPolicy.nextDelay(attempt: 0), 0.5)
        XCTAssertEqual(ObserverRetryPolicy.nextDelay(attempt: 1), 1.0)
        XCTAssertEqual(ObserverRetryPolicy.nextDelay(attempt: 2), 2.0)
        XCTAssertNil(ObserverRetryPolicy.nextDelay(attempt: 3))
        XCTAssertNil(ObserverRetryPolicy.nextDelay(attempt: -1))
    }
}
