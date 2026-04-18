import XCTest
@testable import GridServer

final class SrvAliveTests: XCTestCase {

    // DW-2.4: srv.alive heartbeat fires every 2nd validator tick (60s cadence
    // at validator's 30s timer), so ~10 per 10 minutes; HeapReader reports a
    // non-zero heap_mb on a live process.

    func test_DW_2_4_heartbeat_predicate_fires_every_second_tick() {
        var ticks: [Int] = []
        for tick in 1...20 {
            if HeartbeatScheduler.shouldEmit(tickCount: tick) {
                ticks.append(tick)
            }
        }
        // Expected: ticks 2, 4, 6, 8, 10, 12, 14, 16, 18, 20 → 10 events over
        // the equivalent of 10 minutes at a 30s validator cadence. DW allows
        // "at least 9" to account for the first 30s of startup delay.
        XCTAssertEqual(ticks.count, 10)
        XCTAssertEqual(ticks, [2, 4, 6, 8, 10, 12, 14, 16, 18, 20])
    }

    func test_DW_2_4_heartbeat_does_not_fire_on_odd_ticks() {
        XCTAssertFalse(HeartbeatScheduler.shouldEmit(tickCount: 1))
        XCTAssertFalse(HeartbeatScheduler.shouldEmit(tickCount: 3))
        XCTAssertFalse(HeartbeatScheduler.shouldEmit(tickCount: 99))
    }

    func test_DW_2_4_heap_reader_returns_nonzero_on_live_process() {
        // XCTest runs in a real Mach task; task_info must succeed and report
        // a non-zero resident size.
        let mb = HeapReader.readHeapMb()
        XCTAssertGreaterThan(mb, 0)
    }
}
