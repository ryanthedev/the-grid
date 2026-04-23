import XCTest
@testable import GridServer

// Tests for the same-cell focus race detection added in cycleFocus.
//
// Background: when two same-app windows share a cell, the macOS appActivated
// notification for an earlier ax.focus call can land *after* a later
// verification read, causing focusWindowByID to report a stale "actual"
// window. Without the race detector, cycleFocus then walks every window in
// the cell, issuing extra ax.focus calls and ultimately throwing a spurious
// noWindowsInCell — even though the first focus call DID take effect.
//
// detectFocusRace is the pure decision predicate extracted from cycleFocus.
// If true, the loop should commit the requested index and return instead of
// continuing to iterate.
final class GridFocusRaceTests: XCTestCase {

    // DW-1.1 / DW-1.4(a): when the OS-reported "actual" focused window is
    // itself a member of the current cell, this is a same-cell async race
    // (not an unfocusable window). The helper must report true so cycleFocus
    // can short-circuit instead of issuing a second ax.focus.
    func test_DW_1_1_race_branch_returns_true_when_actual_in_cell_windows() {
        let cellWindows: [UInt32] = [414, 1622]
        let actual: UInt32 = 1622
        XCTAssertTrue(GridFocus.detectFocusRace(actual: actual, cellWindows: cellWindows))
    }

    // DW-1.4(b): a genuinely unfocusable window scenario looks like a focus
    // mismatch where the OS-reported actual is NOT a member of this cell
    // (e.g. focus stayed on whatever was focused before, or jumped to an
    // unrelated app). Helper must report false so cycleFocus continues to
    // try the next index — and after exhausting the loop, throws
    // noWindowsInCell as before.
    func test_DW_1_4_unfocusable_window_not_in_cell_continues_loop() {
        let cellWindows: [UInt32] = [414, 1622]
        // Some unrelated window the OS focused instead.
        let actual: UInt32 = 99999
        XCTAssertFalse(GridFocus.detectFocusRace(actual: actual, cellWindows: cellWindows))
    }

    // DW-1.4(c): single-window cell path is unchanged. The race helper isn't
    // invoked there (cycleFocus has an early return for cellWindows.count == 1),
    // but if it WERE invoked with a one-element list and the actual matched
    // that one window, it would still report true (consistent with the
    // race-detection semantics).
    func test_DW_1_4_single_window_path_unaffected() {
        let cellWindows: [UInt32] = [414]
        // Exactly the one window in the cell.
        XCTAssertTrue(GridFocus.detectFocusRace(actual: 414, cellWindows: cellWindows))
        // An unrelated window — would be a genuine mismatch (loop would
        // continue, but the count==1 early return makes this path moot).
        XCTAssertFalse(GridFocus.detectFocusRace(actual: 999, cellWindows: cellWindows))
    }

    // Empty-cell sanity: never report a race for an empty cell. (cycleFocus
    // throws before reaching the loop in this case, so this is a defensive
    // unit for the helper itself.)
    func test_detectFocusRace_empty_cell_returns_false() {
        XCTAssertFalse(GridFocus.detectFocusRace(actual: 100, cellWindows: []))
    }
}
