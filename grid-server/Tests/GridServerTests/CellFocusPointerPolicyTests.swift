import XCTest
@testable import GridServer

/// Covers the two rules that keep a cell's focus pointer honest. The bug these
/// pin: a window added to a cell used to claim `lastFocusedWid` unconditionally,
/// so reconciler bookkeeping (adoption of an untracked window, locked-cell
/// create, lift migration, rejected sweep) silently retargeted the cell, and
/// entering it focused the new arrival instead of the window last used there.
final class CellFocusPointerPolicyTests: XCTestCase {

    // An incumbent focus target must survive a later arrival -- the exact
    // sequence that made a re-adopted window win a cell it never earned.
    func testInsertDoesNotDisplaceAnExistingPointer() {
        XCTAssertFalse(CellFocusPointerPolicy.shouldClaimOnInsert(currentLastFocusedWid: 328))
    }

    // A cell with no pointer has one to give, or focusing it has no target.
    func testInsertClaimsPointerWhenCellHasNone() {
        XCTAssertTrue(CellFocusPointerPolicy.shouldClaimOnInsert(currentLastFocusedWid: 0))
    }

    // Removing a window ahead of the pointer used to leave the index pointing
    // one past its window; resolving from the wid absorbs the shift.
    func testIndexFollowsItsWindowAcrossRemovalAndPrepend() {
        // [9828, 328, 9234] focused on 9234 (idx 2); drop 9828 from the front.
        XCTAssertEqual(
            CellFocusPointerPolicy.resolveIndex(
                windows: [328, 9234], lastFocusedWid: 9234, lastFocusedIdx: 2
            ),
            1
        )
        // Prepend shifts everything right; the pointer tracks its window.
        XCTAssertEqual(
            CellFocusPointerPolicy.resolveIndex(
                windows: [1130, 328, 9234], lastFocusedWid: 9234, lastFocusedIdx: 1
            ),
            2
        )
    }

    // With no wid to resolve against, the stale index must stay in range
    // rather than trapping on an out-of-bounds read.
    func testIndexIsClampedWhenNoWidToResolveAgainst() {
        XCTAssertEqual(
            CellFocusPointerPolicy.resolveIndex(
                windows: [328, 9234], lastFocusedWid: 0, lastFocusedIdx: 7
            ),
            1
        )
        XCTAssertEqual(
            CellFocusPointerPolicy.resolveIndex(
                windows: [], lastFocusedWid: 0, lastFocusedIdx: 3
            ),
            0
        )
    }

    // A wid that left the cell entirely falls back to the clamped index.
    func testAbsentWidFallsBackToClampedIndex() {
        XCTAssertEqual(
            CellFocusPointerPolicy.resolveIndex(
                windows: [328, 9234], lastFocusedWid: 1130, lastFocusedIdx: 0
            ),
            0
        )
    }
}
