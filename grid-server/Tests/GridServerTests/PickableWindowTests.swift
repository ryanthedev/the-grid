import XCTest
@testable import GridServer

/// Regression tests for `isPickableWindow`.
///
/// Bug: Chrome spawns phantom helper AX elements (favicon, tab-drag, hover
/// previews) with a nil role, nil subrole, and empty title. The picker's old
/// inline filter only rejected windows below 50pt and non-nil non-standard
/// subroles, so these phantoms slipped through and rendered as a swarm of bare,
/// duplicate "Google Chrome" rows. Fixed by requiring role == "AXWindow".
final class PickableWindowTests: XCTestCase {

    /// A genuine top-level browser window.
    private func makeReal() -> WindowState {
        var w = WindowState(id: 1)
        w.role = "AXWindow"
        w.subrole = "AXStandardWindow"
        w.frame = CGRect(x: 0, y: 0, width: 1265, height: 1060)
        return w
    }

    /// A Chrome phantom: nil role, nil subrole, empty title (modeled on the
    /// 64x64 helper windows observed in the live state dump).
    private func makePhantom(width: CGFloat, height: CGFloat) -> WindowState {
        var w = WindowState(id: 2)
        w.role = nil
        w.subrole = nil
        w.frame = CGRect(x: 0, y: 0, width: width, height: height)
        return w
    }

    func testRealWindowIsPickable() {
        XCTAssertTrue(isPickableWindow(makeReal()))
    }

    func testSmallPhantomIsRejected() {
        // The classic 64x64 ghost.
        XCTAssertFalse(isPickableWindow(makePhantom(width: 64, height: 64)))
    }

    func testLargePhantomIsRejected() {
        // Tab hover-preview phantom (824x112): wider than the 50pt floor, so the
        // size check alone would NOT catch it — the role guard is what does.
        XCTAssertFalse(isPickableWindow(makePhantom(width: 824, height: 112)))
    }

    func testHiddenRealWindowIsRejected() {
        var w = makeReal()
        w.isHidden = true
        XCTAssertFalse(isPickableWindow(w))
    }

    func testNonStandardSubroleIsRejected() {
        var w = makeReal()
        w.subrole = "AXDialog"
        XCTAssertFalse(isPickableWindow(w))
    }
}
