import XCTest
@testable import GridServer

// Tests for Phase 1 of the wake-layout-restore plan.
//
// Scope:
//   - StateValidator.resetAllOrphanCounts() empties the orphan-count map
//     so a stale pre-sleep count cannot push a real, alive window past the
//     2-cycle prune threshold during the wake stabilization window.
//   - GridReconciler.handleSystemWake() calls refreshAllDisplays() exactly
//     once, *after* validate() has run, so layouts are reapplied on wake.
//
// Mocking strategy:
//   GridApply is a class with no protocol abstraction. Per project standards
//   "no new abstractions for tests"; we subclass GridApply in-test and
//   override refreshAllDisplays to record call count and the validator's
//   heartbeat tick count at the moment of the call. The heartbeat tick
//   increments inside validate() — reading it from the stub yields a
//   deterministic ordering signal that does not rely on log scraping or
//   wall-clock timestamps.

// Records every refreshAllDisplays call and the StateValidator heartbeat
// tick count observed at call time. tickAtCall >= 1 proves the validator's
// validate() body completed before refreshAllDisplays was invoked.
final class StubGridApply: GridApply, @unchecked Sendable {
    var callCount = 0
    var tickAtCall: Int = -1
    weak var validatorForOrdering: StateValidator?

    override func refreshAllDisplays(displayFilter: String? = nil) async -> [GridDisplayError] {
        callCount += 1
        if let validator = validatorForOrdering {
            tickAtCall = await validator.peekHeartbeatTickCount()
        }
        return []
    }
}

final class WakeLayoutRestoreTests: XCTestCase {

    // DW-1.5: populate orphan counts directly, call resetAllOrphanCounts(),
    // assert the map is empty afterward. The plan-level "next prune does not
    // fire on previously-counted wids" reduces to "the count for those wids
    // is 0 after reset" — pruneAXOrphanedWindows fires at count >= threshold,
    // so a 0 count cannot fire.
    func test_DW_1_5_resetAllOrphanCounts_clears_state_and_skips_next_prune() async {
        let gridState = GridState()
        let validator = StateValidator(
            gridState: gridState,
            stateManager: StateManager.shared,
            connectionID: 0
        )

        // Pre-populate orphan counts directly. Use a test-only seed helper
        // so we don't have to drive the full pruneAXOrphanedWindows machinery
        // (which requires real AX queries).
        await validator._test_seedOrphanCounts([111: 1, 222: 1])
        let beforeCount = await validator._test_orphanCountForWid(111)
        XCTAssertEqual(beforeCount, 1, "precondition: seed populated wid 111")

        await validator.resetAllOrphanCounts()

        let afterWid111 = await validator._test_orphanCountForWid(111)
        let afterWid222 = await validator._test_orphanCountForWid(222)
        XCTAssertEqual(afterWid111, 0, "wid 111 must be cleared after resetAll")
        XCTAssertEqual(afterWid222, 0, "wid 222 must be cleared after resetAll")
    }

    // DW-1.6: handleSystemWake (driven via the public StateEventHandler
    // path) must invoke gridApply.refreshAllDisplays exactly once, AFTER
    // stateValidator.validate has run. Heartbeat tick == 1 at refresh-call
    // time proves the ordering.
    func test_DW_1_6_handleSystemWake_invokes_refreshAllDisplays_after_validate() async throws {
        let gridState = GridState()
        let gridConfig = GridConfig()
        let borderManager = SimpleBorderManager(connectionID: 0)

        let reconciler = GridReconciler()
        reconciler.setup(
            gridState: gridState,
            gridConfig: gridConfig,
            stateManager: StateManager.shared,
            simpleBorderManager: borderManager
        )

        let validator = StateValidator(
            gridState: gridState,
            stateManager: StateManager.shared,
            connectionID: 0
        )
        reconciler.setValidator(validator)

        let stubApply = StubGridApply()
        stubApply.validatorForOrdering = validator
        reconciler.setApply(stubApply)

        // Drive the wake event through the public handler entry point.
        let context = EventContext(source: .manual(reason: "test"))
        try await reconciler.handle(.systemWoke, context: context)

        // wakeValidationTask is awaited synchronously inside handleSystemWake,
        // so handle() returning means the whole sequence completed.
        XCTAssertEqual(stubApply.callCount, 1,
            "refreshAllDisplays must be called exactly once on wake")
        XCTAssertGreaterThanOrEqual(stubApply.tickAtCall, 1,
            "validate() must complete before refreshAllDisplays is called " +
            "(heartbeat tick >= 1 at call time)")
    }
}
