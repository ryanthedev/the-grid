import XCTest
@testable import GridServer

// DW-D4: warn.poll.readd fires ONLY for a genuine resurrection — a wid removed
// from state (poll-prune or handleWindowDestroyed) that a stale poll snapshot
// then re-adds within the grace window. A window the poll merely discovered and
// that StateManager never tracked (never tombstoned) is never logged.
//
// The resurrection DECISION predicate is unit-tested in GraceWindowPolicyTests.
// Here we drive StateManager's real actor-isolated tombstone map + real
// predicate through `_test_` seams.
final class RemovalTombstoneTests: XCTestCase {

    // A removed wid re-added within grace is a genuine resurrection.
    func test_DW_D_4_recent_removal_is_resurrection() async {
        let sm = StateManager.shared
        await sm._test_resetTombstone()
        let now: CFAbsoluteTime = 5000.0
        await sm._test_noteRemoval(101, at: now)

        let result = await sm._test_isResurrection(wid: 101, now: now + 1.0)
        XCTAssertTrue(result, "wid removed 1s ago and re-added within grace is a resurrection")
    }

    // A wid never removed (never tombstoned) is never a resurrection — this is
    // the flood case: poll-discovered windows StateManager never tracked.
    func test_DW_D_4_never_removed_is_not_resurrection() async {
        let sm = StateManager.shared
        await sm._test_resetTombstone()

        let result = await sm._test_isResurrection(wid: 999, now: 5000.0)
        XCTAssertFalse(result, "a wid never removed must never be flagged as a resurrection")
    }

    // An expired tombstone is not a resurrection (poll legitimately rediscovered).
    func test_DW_D_4_expired_tombstone_is_not_resurrection() async {
        let sm = StateManager.shared
        await sm._test_resetTombstone()
        let now: CFAbsoluteTime = 5000.0
        await sm._test_noteRemoval(202, at: now)

        let result = await sm._test_isResurrection(wid: 202, now: now + 999.0)
        XCTAssertFalse(result, "a tombstone older than grace must not be a resurrection")
    }

    // Pruning drops expired tombstone entries (bounded growth each poll).
    func test_DW_D_4_prune_drops_expired_entries() async {
        let sm = StateManager.shared
        await sm._test_resetTombstone()
        let now: CFAbsoluteTime = 5000.0
        await sm._test_noteRemoval(303, at: now)
        await sm._test_noteRemoval(304, at: now)

        let before = await sm._test_tombstoneCount
        XCTAssertEqual(before, 2)

        await sm._test_pruneTombstone(now: now + 999.0)
        let after = await sm._test_tombstoneCount
        XCTAssertEqual(after, 0, "expired tombstone entries must be pruned")
    }
}
