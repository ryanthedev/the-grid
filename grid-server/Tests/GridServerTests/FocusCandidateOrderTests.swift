import XCTest

@testable import GridServer

// Candidate ordering for directional focus.
//
// Directional focus used to try exactly one window — the cell's restored
// index — and abort the whole command if the OS refused it. Spotify exposes a
// CG window with zero AX windows behind it; once that window was the restored
// candidate, `focus left/right/up/down` all failed with focusFailed(78) until
// the user clicked something manually. The cycle path already skipped
// unfocusable candidates. These pin the ordering the directional path now
// walks.
final class FocusCandidateOrderTests: XCTestCase {

    // The restored window is still tried first — skipping is a fallback, not a
    // change of preference.
    func test_preferredIndexIsTriedFirst() {
        XCTAssertEqual(
            GridFocus.focusCandidateOrder(preferredIdx: 2, windowCount: 4).first,
            2
        )
    }

    func test_remainingCandidatesFollowInWrappingOrder() {
        XCTAssertEqual(
            GridFocus.focusCandidateOrder(preferredIdx: 2, windowCount: 4),
            [2, 3, 0, 1]
        )
    }

    // Every window gets exactly one turn: none skipped, none retried.
    func test_everyIndexAppearsExactlyOnce() {
        for count in 1...8 {
            for preferred in 0..<count {
                let order = GridFocus.focusCandidateOrder(
                    preferredIdx: preferred,
                    windowCount: count
                )
                XCTAssertEqual(order.count, count, "count \(count) preferred \(preferred)")
                XCTAssertEqual(Set(order), Set(0..<count), "count \(count) preferred \(preferred)")
            }
        }
    }

    func test_singleWindowYieldsItself() {
        XCTAssertEqual(GridFocus.focusCandidateOrder(preferredIdx: 0, windowCount: 1), [0])
    }

    // An out-of-range preferred index comes from stale cell state; it must
    // clamp rather than produce an order that indexes past the array.
    func test_outOfRangePreferredIndexClamps() {
        XCTAssertEqual(
            GridFocus.focusCandidateOrder(preferredIdx: 99, windowCount: 3),
            [2, 0, 1]
        )
        XCTAssertEqual(
            GridFocus.focusCandidateOrder(preferredIdx: -5, windowCount: 3),
            [0, 1, 2]
        )
    }

    func test_emptyCellYieldsNoCandidates() {
        XCTAssertTrue(GridFocus.focusCandidateOrder(preferredIdx: 0, windowCount: 0).isEmpty)
    }

    // The skip decision itself is shouldCommitFocus, shared with the cycle
    // path. An unfocusable candidate must not commit — that is what lets the
    // loop move on instead of dead-ending.
    func test_unfocusableCandidateDoesNotCommit() {
        XCTAssertFalse(
            GridFocus.shouldCommitFocus(
                requested: 78,
                attempt: .failed,
                cellWindows: [1365, 78]
            )
        )
    }

    // ...and a successful one does, so the loop stops at the first window the
    // OS actually accepted.
    func test_focusableCandidateCommits() {
        XCTAssertTrue(
            GridFocus.shouldCommitFocus(
                requested: 1365,
                attempt: .focused(1365),
                cellWindows: [1365, 78]
            )
        )
    }
}
