import XCTest
@testable import GridServer

final class WindowHitTestTests: XCTestCase {
    private func entry(_ id: UInt32, pid: pid_t, _ name: String, layer: Int = 0, alpha: Double = 1, _ bounds: CGRect) -> WindowHitTest.Entry {
        WindowHitTest.Entry(windowID: id, pid: pid, ownerName: name, layer: layer, alpha: alpha, bounds: bounds)
    }

    // Front to back, as CGWindowList returns them: a full-display panel over a small calculator.
    private var stack: [WindowHitTest.Entry] {
        [
            entry(9, pid: 3, "Overlay", alpha: 0, CGRect(x: 0, y: -1080, width: 3840, height: 1080)),
            entry(1, pid: 1, "GridNotify", CGRect(x: 10, y: -1070, width: 3820, height: 1060)),
            entry(2, pid: 2, "Calculator", CGRect(x: 1470, y: -556, width: 230, height: 408)),
            entry(8, pid: 4, "Borders", layer: -1, CGRect(x: 0, y: -1080, width: 3840, height: 1080)),
        ]
    }

    func testFrontmostVisibleWindowTakesTheClick() {
        XCTAssertEqual(WindowHitTest.top(at: CGPoint(x: 1500, y: -300), in: stack)?.windowID, 1)
        XCTAssertNil(WindowHitTest.top(at: CGPoint(x: 9000, y: 0), in: stack))
    }

    func testCoveredTargetIsRefusedAndNamesTheCulprit() {
        let why = WindowHitTest.obstruction(at: CGPoint(x: 1500, y: -300), targetPid: 2, windowID: 2, in: stack)
        XCTAssertTrue(why?.contains("GridNotify") ?? false)
    }

    func testOwnAppsMenusAndSheetsAreLegitimateTargets() {
        let menu = entry(7, pid: 2, "Calculator", layer: 101, CGRect(x: 1480, y: -500, width: 200, height: 300))
        XCTAssertNil(WindowHitTest.obstruction(at: CGPoint(x: 1500, y: -300), targetPid: 2, windowID: 2, in: [menu] + stack))
    }
}
