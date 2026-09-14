import XCTest
@testable import GridServer

// Actor-level cover for the focus-pointer rules. CellFocusPointerPolicyTests
// pins the decision; these pin that GridState actually *uses* it -- reverting
// assignWindow to the old unconditional `cell.lastFocusedWid = windowID` must
// turn one of these red.
final class GridStateFocusPointerTests: XCTestCase {

    private func cell(_ gs: GridState, _ cellID: String) async -> GridCellStateData? {
        await gs.getSpaceReadOnly("3")?.cells[cellID]
    }

    private func makeSpace() async -> GridState {
        let gs = GridState()
        await gs._test_setLayout(spaceID: "3", layoutID: "two-column")
        await gs._test_setCells(spaceID: "3", cellIDs: ["left", "right"])
        return gs
    }

    // The logged failure, reproduced at the state layer: the user's target is
    // 328; the reconciler adopts four ghosts into the same cell; entering the
    // cell must still choose 328, not the last ghost added.
    func testReconcilerInsertsDoNotStealTheUsersFocusTarget() async {
        let gs = await makeSpace()
        await gs.assignWindow(9828, toCellID: "right", inSpace: "3")
        await gs.assignWindow(328, toCellID: "right", inSpace: "3")
        await gs.setFocus(spaceID: "3", cellID: "right", windowIndex: 1)
        let seeded = await cell(gs, "right")?.lastFocusedWid
        XCTAssertEqual(seeded, 328)

        for ghost: UInt32 in [8563, 2514, 8586, 1130] {
            await gs.assignWindow(ghost, toCellID: "right", inSpace: "3")
        }

        let right = await cell(gs, "right")
        XCTAssertEqual(right?.lastFocusedWid, 328, "adopted windows must not claim the cell")
        XCTAssertEqual(right?.windows[right!.lastFocusedIdx], 328, "index must still name 328")
    }

    // The first window into an empty cell has to become its target, or the cell
    // is unfocusable.
    func testFirstWindowIntoAnEmptyCellClaimsThePointer() async {
        let gs = await makeSpace()
        await gs.assignWindow(9828, toCellID: "left", inSpace: "3")
        let left = await cell(gs, "left")
        XCTAssertEqual(left?.lastFocusedWid, 9828)
    }

    // A prepend shifts every element right; the incumbent's index must follow
    // its window rather than stay put and name a different one.
    func testPrependKeepsTheIncumbentIndexOnItsOwnWindow() async {
        let gs = await makeSpace()
        await gs.assignWindow(9828, toCellID: "right", inSpace: "3")
        await gs.assignWindow(328, toCellID: "right", inSpace: "3")
        await gs.setFocus(spaceID: "3", cellID: "right", windowIndex: 1)

        await gs.prependWindow(1130, toCellID: "right", inSpace: "3")

        let right = await cell(gs, "right")
        XCTAssertEqual(right?.windows, [1130, 9828, 328])
        XCTAssertEqual(right?.lastFocusedWid, 328)
        XCTAssertEqual(right?.lastFocusedIdx, 2, "index followed its window across the shift")
    }

    // Removing a window ahead of the pointer used to leave the index one past
    // its window; it must track instead.
    func testRemovingAWindowAheadOfThePointerKeepsThemInSync() async {
        let gs = await makeSpace()
        for wid: UInt32 in [9828, 328, 9234] {
            await gs.assignWindow(wid, toCellID: "right", inSpace: "3")
        }
        await gs.setFocus(spaceID: "3", cellID: "right", windowIndex: 2)
        let seeded = await cell(gs, "right")?.lastFocusedWid
        XCTAssertEqual(seeded, 9234)

        await gs.removeWindow(9828, fromSpace: "3")

        let right = await cell(gs, "right")
        XCTAssertEqual(right?.windows, [328, 9234])
        XCTAssertEqual(right?.lastFocusedWid, 9234)
        XCTAssertEqual(right?.lastFocusedIdx, 1)
    }

    // Deliberate placement still moves the pointer when it asks to.
    func testExplicitMakeFocusedClaimsOverAnIncumbent() async {
        let gs = await makeSpace()
        await gs.assignWindow(9828, toCellID: "right", inSpace: "3")
        await gs.setFocus(spaceID: "3", cellID: "right", windowIndex: 0)

        await gs.assignWindow(328, toCellID: "right", inSpace: "3", makeFocused: true)

        let right = await cell(gs, "right")
        XCTAssertEqual(right?.lastFocusedWid, 328)
    }
}
