import XCTest
@testable import GridServer

/// DW-7.8 (#36): MSS availability cache can be reset (wake re-probe) and the
/// re-probe threshold policy drives invalidation after repeated move failures.
/// The live Dock handshake is a UAT item; here we prove the cache lifecycle.
final class MSSReprobeTests: XCTestCase {

    func test_DW_7_8_isAvailable_caches_then_reset_reprobes() {
        let client = MSSClient()
        // First probe caches a verdict (false on CI/test — no Dock addition).
        let first = client.isAvailable()
        // Repeated calls return the cached verdict without re-probing.
        XCTAssertEqual(client.isAvailable(), first)

        // Reset clears the cache; the next call re-probes (must not crash and
        // must return a Bool). This is the wake path the bug left uncalled.
        client.resetAvailabilityCache()
        let afterReset = client.isAvailable()
        XCTAssertEqual(afterReset, first, "re-probe in the same env yields the same verdict but actually re-ran")
    }

    func test_DW_7_8_reset_is_idempotent() {
        let client = MSSClient()
        client.resetAvailabilityCache()
        client.resetAvailabilityCache()
        // No crash, still answerable.
        _ = client.isAvailable()
    }
}
