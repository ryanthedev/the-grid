import XCTest
@testable import GridServer

final class GridAssignmentTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal tileable WindowState for testing.
    private func makeWindow(
        id: UInt32,
        appName: String,
        pid: pid_t = 0
    ) -> WindowState {
        var w = WindowState(id: id)
        w.appName = appName
        w.pid = pid
        w.role = "AXWindow"
        w.subrole = "AXStandardWindow"
        w.hasCloseButton = true
        w.hasFullscreenButton = true
        // Large enough to pass isTileable check
        w.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        return w
    }

    /// Build a simple layout with the given cell IDs.
    private func makeLayout(cellIDs: [String]) -> GridLayoutDef {
        let cells = cellIDs.enumerated().map { (i, id) in
            GridCellDef(
                id: id,
                columnStart: i + 1,
                columnEnd: i + 2,
                rowStart: 1,
                rowEnd: 2
            )
        }
        let frTrack = GridTrackSize(type: .fr, value: 1.0)
        return GridLayoutDef(
            id: "test",
            name: "Test",
            description: "",
            columns: cellIDs.map { _ in frTrack },
            rows: [frTrack],
            cells: cells,
            cellModes: [:]
        )
    }

    /// Build simple cell bounds for the given cell IDs.
    private func makeCellBounds(cellIDs: [String]) -> [String: CGRect] {
        var bounds: [String: CGRect] = [:]
        for (i, id) in cellIDs.enumerated() {
            bounds[id] = CGRect(
                x: Double(i) * 400,
                y: 0,
                width: 400,
                height: 800
            )
        }
        return bounds
    }

    // MARK: - Test: Non-matching window skips locked cell (DW-3.2)

    func testNonMatchingWindowSkipsLockedCell() {
        let layout = makeLayout(cellIDs: ["left", "right", "notify"])
        let cellBounds = makeCellBounds(cellIDs: ["left", "right", "notify"])
        let appRules = [
            GridAppRule(
                app: "com.thegrid.notify",
                preferredCell: "notify",
                float: false,
                locked: true,
                preferredStackMode: nil
            ),
        ]

        // Safari window — does NOT match the locked rule
        let windows = [makeWindow(id: 1, appName: "Safari", pid: 1)]

        let result = GridAssignment.assignWindows(
            windows: windows,
            layout: layout,
            cellBounds: cellBounds,
            appRules: appRules,
            previousAssignments: [:],
            strategy: .autoFlow,
            bundleIDLookup: { _ in "com.apple.Safari" }
        )

        // The "notify" cell must be empty
        XCTAssertEqual(
            result.assignments["notify"] ?? [],
            [],
            "Locked cell should be empty when no matching window exists"
        )
        // The Safari window should be in one of the non-locked cells
        let nonLockedWindows = (result.assignments["left"] ?? [])
            + (result.assignments["right"] ?? [])
        XCTAssertTrue(
            nonLockedWindows.contains(1),
            "Non-matching window should be assigned to a non-locked cell"
        )
    }

    // MARK: - Test: Matching window auto-assigns to locked cell (DW-3.3)

    func testMatchingWindowAutoAssignsToLockedCell() {
        let layout = makeLayout(cellIDs: ["left", "right", "notify"])
        let cellBounds = makeCellBounds(cellIDs: ["left", "right", "notify"])
        let appRules = [
            GridAppRule(
                app: "com.thegrid.notify",
                preferredCell: "notify",
                float: false,
                locked: true,
                preferredStackMode: nil
            ),
        ]

        // GridNotify window — matches the locked rule by bundle ID
        let windows = [
            makeWindow(id: 1, appName: "Safari", pid: 1),
            makeWindow(id: 2, appName: "GridNotify", pid: 2),
        ]

        let result = GridAssignment.assignWindows(
            windows: windows,
            layout: layout,
            cellBounds: cellBounds,
            appRules: appRules,
            previousAssignments: [:],
            strategy: .autoFlow,
            bundleIDLookup: { pid in
                if pid == 2 { return "com.thegrid.notify" }
                return "com.apple.Safari"
            }
        )

        // GridNotify should be in the locked cell
        XCTAssertEqual(
            result.assignments["notify"],
            [2],
            "Matching window should auto-assign to locked cell"
        )
        // Safari should NOT be in the locked cell
        XCTAssertFalse(
            (result.assignments["notify"] ?? []).contains(1),
            "Non-matching window must not be in locked cell"
        )
    }

    // MARK: - Test: Non-locked preferredCell still works (DW-3.5)

    func testPreferredCellWithoutLockedStillWorks() {
        let layout = makeLayout(cellIDs: ["left", "right"])
        let cellBounds = makeCellBounds(cellIDs: ["left", "right"])
        let appRules = [
            GridAppRule(
                app: "com.apple.Safari",
                preferredCell: "right",
                float: false,
                locked: false,
                preferredStackMode: nil
            ),
        ]

        let windows = [
            makeWindow(id: 1, appName: "Safari", pid: 1),
            makeWindow(id: 2, appName: "Terminal", pid: 2),
        ]

        let result = GridAssignment.assignWindows(
            windows: windows,
            layout: layout,
            cellBounds: cellBounds,
            appRules: appRules,
            previousAssignments: [:],
            strategy: .pinned,
            bundleIDLookup: { pid in
                if pid == 1 { return "com.apple.Safari" }
                return "com.apple.Terminal"
            }
        )

        // Safari should be in "right" (its preferred cell)
        XCTAssertTrue(
            (result.assignments["right"] ?? []).contains(1),
            "Window with preferredCell should be assigned to preferred cell"
        )
        // Terminal should be in "left" (the remaining cell)
        XCTAssertTrue(
            (result.assignments["left"] ?? []).contains(2),
            "Unpinned window should be assigned to remaining cell"
        )
    }
}
