import XCTest
@testable import GridServer

final class AppTermReconcileTests: XCTestCase {

    // DW-2.3: given a terminating pid, list all cells that still reference wids
    // belonging to that pid, grouped by display.

    private func makeWmState(windows: [(wid: UInt32, pid: pid_t, display: String)]) -> WindowManagerState {
        var state = WindowManagerState()
        for w in windows {
            var ws = WindowState(id: w.wid)
            ws.pid = w.pid
            ws.displayUUID = w.display
            state.windows[String(w.wid)] = ws
        }
        return state
    }

    func test_DW_2_3_lists_stale_cells_for_pid() {
        // Ghostty (pid=42) owns wid=100; wid=100 is in cell "A1" on displayX.
        // Finder (pid=99) owns wid=200; wid=200 is in cell "B1" on displayY.
        // Terminating pid=42 → expect one stale entry for (displayX, "A1", [100]).
        let wmState = makeWmState(windows: [
            (100, 42, "displayX"),
            (200, 99, "displayY"),
        ])
        let assignmentsBySpace: [String: [String: [UInt32]]] = [
            "space1": ["A1": [100]],
            "space2": ["B1": [200]],
        ]
        let spaceToDisplay: [String: String] = [
            "space1": "displayX",
            "space2": "displayY",
        ]

        let stale = AppTermReconciler.findStaleCells(
            pid: 42,
            wmState: wmState,
            assignmentsBySpace: assignmentsBySpace,
            spaceToDisplay: spaceToDisplay
        )

        XCTAssertEqual(stale.count, 1)
        XCTAssertEqual(stale[0].display, "displayX")
        XCTAssertEqual(stale[0].cell, "A1")
        XCTAssertEqual(stale[0].wids, [100])
    }

    func test_DW_2_3_returns_empty_when_no_stale_wids() {
        // Terminating pid owns no currently-cell-assigned wids.
        let wmState = makeWmState(windows: [
            (200, 99, "displayY"),
        ])
        let assignmentsBySpace: [String: [String: [UInt32]]] = [
            "space2": ["B1": [200]],
        ]
        let spaceToDisplay: [String: String] = [
            "space2": "displayY",
        ]

        let stale = AppTermReconciler.findStaleCells(
            pid: 42,
            wmState: wmState,
            assignmentsBySpace: assignmentsBySpace,
            spaceToDisplay: spaceToDisplay
        )
        XCTAssertTrue(stale.isEmpty)
    }

    func test_DW_2_3_aggregates_multiple_wids_in_same_cell() {
        let wmState = makeWmState(windows: [
            (100, 42, "displayX"),
            (101, 42, "displayX"),
            (102, 42, "displayX"),
        ])
        let assignmentsBySpace: [String: [String: [UInt32]]] = [
            "space1": ["A1": [100, 101, 102]],
        ]
        let spaceToDisplay: [String: String] = [
            "space1": "displayX",
        ]

        let stale = AppTermReconciler.findStaleCells(
            pid: 42,
            wmState: wmState,
            assignmentsBySpace: assignmentsBySpace,
            spaceToDisplay: spaceToDisplay
        )
        XCTAssertEqual(stale.count, 1)
        XCTAssertEqual(stale[0].wids.sorted(), [100, 101, 102])
    }
}
