import XCTest
import ApplicationServices
@testable import GridServer

// Tests for the single-AX-window fallback guard in StateManager.getAXProperties.
//
// Bug: AnycubicSlicerNext (and similar multi-window apps) spawn transient helper
// windows that appear in CGWindowList with nil AX role. The poll re-queries those
// nil-role windows; each fails the direct-ID AX match, then hit the
// `windows.count == 1` fallback which promoted the phantom using the ONE real
// window's tileable role/subrole. The phantom then got tiled into a cell, polluting
// layout (resize churn) until the validator pruned it as ax_orphan — a focus-storm
// source.
//
// Fix: only use the fallback when the sole AX window's CG ID is unresolvable
// (Ghostty case) or matches the queried ID. A resolvable, different ID means the
// queried window is a distinct phantom and must NOT be promoted.
final class AXPropertiesFallbackTests: XCTestCase {

    // Phantom: sole AX window resolves to a concrete, DIFFERENT id → do not promote.
    func test_resolvable_different_id_rejects_phantom() {
        XCTAssertFalse(
            StateManager.shouldUseSoleWindowFallback(
                resolved: .success, soleWindowID: 2167, queriedID: 2168
            ),
            "A phantom whose id differs from the sole resolvable AX window must not be promoted"
        )
    }

    // Same window: queried id IS the sole AX window → promote.
    func test_resolvable_same_id_promotes() {
        XCTAssertTrue(
            StateManager.shouldUseSoleWindowFallback(
                resolved: .success, soleWindowID: 2167, queriedID: 2167
            )
        )
    }

    // Unresolvable (zero) id: ambiguous → promote (preserves Ghostty workaround).
    func test_zero_id_promotes() {
        XCTAssertTrue(
            StateManager.shouldUseSoleWindowFallback(
                resolved: .success, soleWindowID: 0, queriedID: 2168
            )
        )
    }

    // AX resolution failed: ambiguous → promote (preserves Ghostty workaround).
    func test_unresolved_promotes() {
        XCTAssertTrue(
            StateManager.shouldUseSoleWindowFallback(
                resolved: .cannotComplete, soleWindowID: 0, queriedID: 2168
            )
        )
    }
}
