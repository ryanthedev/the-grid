import XCTest

@testable import GridServer

// Intra-cell stacking tests for CellStackPolicy.
//
// Written to close a mutation-testing gap: a 200-mutant campaign scored
// GridCellOps at 0% — 17 survivors, 9 of them on the direction→delta sign that
// decides which way `window swap` moves a window. Invert any one of them and
// windows move the wrong way; the entire suite stayed green. The plan listed
// this as test item DW-5.1 and it was never written.
//
// Each test names the specific mutant it kills.
final class CellStackPolicyTests: XCTestCase {

    // MARK: - swapTargetIndex: direction sign
    //
    // Kills GridCellOps:316/318/320 eq->ne and or->and (9 mutants) — every
    // mutation of `(direction == .up || direction == .left) ? -1 : 1`.

    func test_swapTarget_upMovesTowardZero() {
        XCTAssertEqual(
            CellStackPolicy.swapTargetIndex(currentIdx: 2, windowCount: 4, direction: .up),
            1
        )
    }

    func test_swapTarget_leftMovesTowardZero() {
        XCTAssertEqual(
            CellStackPolicy.swapTargetIndex(currentIdx: 2, windowCount: 4, direction: .left),
            1
        )
    }

    func test_swapTarget_downMovesTowardEnd() {
        XCTAssertEqual(
            CellStackPolicy.swapTargetIndex(currentIdx: 1, windowCount: 4, direction: .down),
            2
        )
    }

    func test_swapTarget_rightMovesTowardEnd() {
        XCTAssertEqual(
            CellStackPolicy.swapTargetIndex(currentIdx: 1, windowCount: 4, direction: .right),
            2
        )
    }

    // The `or->and` mutants collapse the two decrementing directions into a
    // condition no single direction can satisfy, flipping every -1 to +1. A
    // test that only exercised .up would still pass under `.up && .left` if it
    // asserted the wrong side, so assert both decrementing directions land on
    // the same index and that it is not the incrementing one.
    func test_swapTarget_upAndLeftAgree_andDifferFromDownAndRight() {
        let up = CellStackPolicy.swapTargetIndex(currentIdx: 2, windowCount: 5, direction: .up)
        let left = CellStackPolicy.swapTargetIndex(currentIdx: 2, windowCount: 5, direction: .left)
        let down = CellStackPolicy.swapTargetIndex(currentIdx: 2, windowCount: 5, direction: .down)
        let right = CellStackPolicy.swapTargetIndex(currentIdx: 2, windowCount: 5, direction: .right)

        XCTAssertEqual(up, left)
        XCTAssertEqual(down, right)
        XCTAssertNotEqual(up, down)
        XCTAssertEqual(up, 1)
        XCTAssertEqual(down, 3)
    }

    // MARK: - swapTargetIndex: wraparound

    func test_swapTarget_wrapsBackwardFromFirstToLast() {
        XCTAssertEqual(
            CellStackPolicy.swapTargetIndex(currentIdx: 0, windowCount: 3, direction: .up),
            2
        )
    }

    func test_swapTarget_wrapsForwardFromLastToFirst() {
        XCTAssertEqual(
            CellStackPolicy.swapTargetIndex(currentIdx: 2, windowCount: 3, direction: .down),
            0
        )
    }

    // Two windows is the minimum the caller allows; both directions must land
    // on the other window rather than on self.
    func test_swapTarget_twoWindowsAlwaysTargetsTheOther() {
        for direction in [GridDirection.up, .down, .left, .right] {
            XCTAssertEqual(
                CellStackPolicy.swapTargetIndex(currentIdx: 0, windowCount: 2, direction: direction),
                1,
                "direction \(direction.rawValue) from index 0"
            )
            XCTAssertEqual(
                CellStackPolicy.swapTargetIndex(currentIdx: 1, windowCount: 2, direction: direction),
                0,
                "direction \(direction.rawValue) from index 1"
            )
        }
    }

    // The old expression was `(currentIdx + delta + windowCount) % windowCount`,
    // which only survives because delta is exactly ±1. Guard the modulo against
    // a negative result directly.
    func test_swapTarget_neverReturnsNegativeIndex() {
        for count in 1...6 {
            for idx in 0..<count {
                for direction in [GridDirection.up, .down, .left, .right] {
                    let target = CellStackPolicy.swapTargetIndex(
                        currentIdx: idx,
                        windowCount: count,
                        direction: direction
                    )
                    XCTAssertTrue(
                        (0..<count).contains(target),
                        "idx \(idx) of \(count) going \(direction.rawValue) -> \(target)"
                    )
                }
            }
        }
    }

    func test_swapTarget_zeroWindowCountReturnsZeroRatherThanTrapping() {
        XCTAssertEqual(
            CellStackPolicy.swapTargetIndex(currentIdx: 0, windowCount: 0, direction: .up),
            0
        )
    }

    // MARK: - stackModeFromLayout
    //
    // Kills GridCellOps:291 eq->ne, ne->eq and and->or (3 mutants) on
    // `cell.id == cellID && cell.stackMode != nil`.

    private func cell(_ id: String, _ mode: GridStackMode?) -> GridCellDef {
        GridCellDef(
            id: id,
            columnStart: 1,
            columnEnd: 2,
            rowStart: 1,
            rowEnd: 2,
            stackMode: mode
        )
    }

    func test_stackMode_prefersMatchingCellsOwnMode() {
        let mode = CellStackPolicy.stackModeFromLayout(
            cellID: "b",
            cells: [cell("a", .vertical), cell("b", .horizontal)],
            cellModes: [:]
        )
        XCTAssertEqual(mode, .horizontal)
    }

    // `cell.id != cellID` would return the first other cell's mode. Give the
    // non-matching cell a different mode so the wrong branch is visible.
    func test_stackMode_ignoresOtherCellsModes() {
        let mode = CellStackPolicy.stackModeFromLayout(
            cellID: "b",
            cells: [cell("a", .vertical)],
            cellModes: [:]
        )
        XCTAssertNil(mode)
    }

    // `cell.stackMode == nil` would return the matching cell despite it
    // declaring nothing, and force-unwrap on nil. The cellModes map must win.
    func test_stackMode_matchingCellWithNoModeFallsThroughToCellModes() {
        let mode = CellStackPolicy.stackModeFromLayout(
            cellID: "b",
            cells: [cell("b", nil)],
            cellModes: ["b": .tabs]
        )
        XCTAssertEqual(mode, .tabs)
    }

    // `||` instead of `&&` matches any cell that either has the right id or
    // declares any mode — here that is cell "a", whose mode differs.
    func test_stackMode_requiresBothIdMatchAndDeclaredMode() {
        let mode = CellStackPolicy.stackModeFromLayout(
            cellID: "b",
            cells: [cell("a", .vertical), cell("b", nil)],
            cellModes: ["b": .tabs]
        )
        XCTAssertEqual(mode, .tabs)
    }

    func test_stackMode_nilWhenNeitherCellNorMapDeclaresOne() {
        XCTAssertNil(
            CellStackPolicy.stackModeFromLayout(
                cellID: "b",
                cells: [cell("b", nil)],
                cellModes: ["a": .tabs]
            )
        )
    }

    // MARK: - swappedSplitRatios
    //
    // Kills GridCellOps:187 eq->ne on `splitRatios.count == cellWindows.count`.

    func test_splitRatios_swapsWhenCountMatchesWindows() {
        let out = CellStackPolicy.swappedSplitRatios([0.2, 0.3, 0.5], windowCount: 3, 0, 2)
        XCTAssertEqual(out, [0.5, 0.3, 0.2])
    }

    func test_splitRatios_nilWhenCountDisagreesWithWindows() {
        XCTAssertNil(CellStackPolicy.swappedSplitRatios([0.5, 0.5], windowCount: 3, 0, 1))
    }

    // The common real case: ratios were never initialised for this cell.
    func test_splitRatios_nilWhenEmpty() {
        XCTAssertNil(CellStackPolicy.swappedSplitRatios([], windowCount: 2, 0, 1))
    }

    func test_splitRatios_nilWhenIndexOutOfRange() {
        XCTAssertNil(CellStackPolicy.swappedSplitRatios([0.5, 0.5], windowCount: 2, 0, 2))
    }
}
