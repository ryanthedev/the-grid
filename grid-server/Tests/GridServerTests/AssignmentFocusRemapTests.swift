import XCTest
@testable import GridServer

// ska: `layout apply` reordered a cell and left the space's focused index on
// a different window; borders jumped 598 -> 192 until a sweep corrected it.
final class AssignmentFocusRemapTests: XCTestCase {

    func test_reordering_a_cell_keeps_focus_on_the_same_window() async {
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "1", layoutID: "single-tabs")
        await gridState.setWindowAssignments(spaceID: "1", assignments: ["main": [598, 192, 185]])
        await gridState.setFocus(spaceID: "1", cellID: "main", windowIndex: 0)
        await gridState.setFocus(spaceID: "1", cellID: "main", windowIndex: 1)
        await gridState.setFocus(spaceID: "1", cellID: "main", windowIndex: 0)

        // Re-apply in a different order (z-order sort).
        await gridState.setWindowAssignments(spaceID: "1", assignments: ["main": [192, 185, 598]])

        let focused = await gridState.getFocusedWindow(spaceID: "1")
        XCTAssertEqual(focused, 598)
        let cell = await gridState.getSpaceReadOnly("1")?.cells["main"]
        XCTAssertEqual(cell?.lastFocusedWid, 598, "focus history survives an apply")
        XCTAssertEqual(cell?.prevFocusedWid, 192)
    }
}
