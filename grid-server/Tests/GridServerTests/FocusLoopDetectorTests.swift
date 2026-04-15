import XCTest
@testable import GridServer

final class FocusLoopDetectorTests: XCTestCase {

    // DW-2.2: trips after >3 same-pair flips within <2s window, returns (count, duration).

    func test_DW_2_2_trips_after_3_pair_flips_within_window() {
        var det = FocusLoopDetector()

        // First 3 observations of the same (100,200) pair within 2s should all
        // return nil (proceed normally — existing retry behavior handles these).
        XCTAssertNil(det.observe(requested: 100, actual: 200, now: 1000.0))
        XCTAssertNil(det.observe(requested: 200, actual: 100, now: 1000.2))
        XCTAssertNil(det.observe(requested: 100, actual: 200, now: 1000.5))

        // 4th observation of same pair: trip.
        let trip = det.observe(requested: 200, actual: 100, now: 1001.0)
        XCTAssertNotNil(trip)
        XCTAssertEqual(trip?.count, 4)
        // duration ~ 1.0s → 1000ms
        XCTAssertEqual(trip?.durationMs, 1000)
    }

    func test_DW_2_2_does_not_trip_on_different_pairs() {
        var det = FocusLoopDetector()
        XCTAssertNil(det.observe(requested: 1, actual: 2, now: 0.0))
        XCTAssertNil(det.observe(requested: 3, actual: 4, now: 0.1))
        XCTAssertNil(det.observe(requested: 5, actual: 6, now: 0.2))
        XCTAssertNil(det.observe(requested: 7, actual: 8, now: 0.3))
    }

    func test_DW_2_2_ignores_entries_outside_window() {
        var det = FocusLoopDetector()
        // 3 entries long ago
        _ = det.observe(requested: 10, actual: 20, now: 0.0)
        _ = det.observe(requested: 10, actual: 20, now: 0.1)
        _ = det.observe(requested: 10, actual: 20, now: 0.2)
        // 4th entry far in the future — prior entries pruned, this one counts as fresh 1.
        XCTAssertNil(det.observe(requested: 10, actual: 20, now: 100.0))
    }

    func test_DW_2_2_pair_is_order_independent() {
        // (100,200) and (200,100) are the same pair.
        var det = FocusLoopDetector()
        _ = det.observe(requested: 100, actual: 200, now: 0.0)
        _ = det.observe(requested: 200, actual: 100, now: 0.1)
        _ = det.observe(requested: 100, actual: 200, now: 0.2)
        let trip = det.observe(requested: 200, actual: 100, now: 0.3)
        XCTAssertNotNil(trip)
        XCTAssertEqual(trip?.count, 4)
    }
}
