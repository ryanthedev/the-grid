import XCTest
import CoreGraphics
@testable import GridServer

// Phase 5 geometry-writes tests.
//
// DW-5.1: Resize split sign — grow/shrink focused window even when last in stack.
// DW-5.2: Split ratios recalculated (not equalized) on assignWindow/removeWindow.
// DW-5.3: sweepDisplacedWindows calls applyCellLayout for target + vacated source.
// DW-5.4: cross-display move abort predicate + err.verify log on SLS-fallback branch.
// DW-5.5: assignAutoFlow logs warn.assign.dropped when all cells are locked.
final class GeometryWritesTests: XCTestCase {

    // MARK: - Helpers

    private func makeWindow(id: UInt32, appName: String = "App", pid: pid_t = 0) -> WindowState {
        var w = WindowState(id: id)
        w.appName = appName
        w.pid = pid
        w.role = "AXWindow"
        w.subrole = "AXStandardWindow"
        w.hasCloseButton = true
        w.hasFullscreenButton = true
        w.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        return w
    }

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

    private func makeCellBounds(cellIDs: [String]) -> [String: CGRect] {
        var bounds: [String: CGRect] = [:]
        for (i, id) in cellIDs.enumerated() {
            bounds[id] = CGRect(x: Double(i) * 400, y: 0, width: 400, height: 800)
        }
        return bounds
    }

    // MARK: - DW-5.1: Resize split sign correct for last-in-stack window
    //
    // The pure helper resolveBoundaryAndDelta must negate delta when the focused
    // window is last so that "grow" always expands the focused window regardless
    // of position in the stack.

    func test_DW_5_1_grow_last_window_expands_it() {
        // 2-window cell, last window focused (idx=1), grow (delta=+0.1).
        // Before fix: boundary=0 with delta=+0.1 → ratios[0] grows, ratios[1] shrinks → WRONG.
        // After fix:  boundary=0 with delta=-0.1 → ratios[0] shrinks, ratios[1] grows → CORRECT.
        let ratios = [0.5, 0.5]
        let (boundaryIndex, effectiveDelta) = GridResize.resolveBoundaryAndDelta(
            idx: 1,
            ratios: ratios,
            delta: 0.1
        )
        XCTAssertEqual(boundaryIndex, 0, "last window clamps to boundary 0")
        // Delta must be negated so adjustSplitRatio grows ratios[1] (the focused last window)
        XCTAssertEqual(effectiveDelta, -0.1, accuracy: 1e-10,
            "delta must be negated when last window is focused")

        let result = GridLayout.adjustSplitRatio(
            ratios: ratios,
            index: boundaryIndex,
            delta: effectiveDelta,
            minRatio: GridLayout.minimumRatio
        )
        guard case .success(let newRatios) = result else {
            XCTFail("adjustSplitRatio unexpectedly failed"); return
        }
        // ratios[1] (last/focused window) must be larger than original 0.5
        XCTAssertGreaterThan(newRatios[1], 0.5, "grow should expand the last focused window")
        XCTAssertLessThan(newRatios[0], 0.5, "grow of last window should shrink the previous one")
    }

    func test_DW_5_1_shrink_last_window_contracts_it() {
        // 2-window cell, last window focused (idx=1), shrink (delta=-0.1).
        // After fix: boundary=0 with delta=+0.1 → ratios[0] grows, ratios[1] shrinks → CORRECT.
        let ratios = [0.5, 0.5]
        let (boundaryIndex, effectiveDelta) = GridResize.resolveBoundaryAndDelta(
            idx: 1,
            ratios: ratios,
            delta: -0.1
        )
        XCTAssertEqual(boundaryIndex, 0)
        XCTAssertEqual(effectiveDelta, 0.1, accuracy: 1e-10,
            "negative delta is negated to positive when last window is focused")

        let result = GridLayout.adjustSplitRatio(
            ratios: ratios,
            index: boundaryIndex,
            delta: effectiveDelta,
            minRatio: GridLayout.minimumRatio
        )
        guard case .success(let newRatios) = result else {
            XCTFail("adjustSplitRatio unexpectedly failed"); return
        }
        XCTAssertLessThan(newRatios[1], 0.5, "shrink should contract the last focused window")
        XCTAssertGreaterThan(newRatios[0], 0.5)
    }

    func test_DW_5_1_grow_first_window_expands_it() {
        // First window focused (idx=0): boundary=0, delta unchanged (no clamp).
        let ratios = [0.5, 0.5]
        let (boundaryIndex, effectiveDelta) = GridResize.resolveBoundaryAndDelta(
            idx: 0,
            ratios: ratios,
            delta: 0.1
        )
        XCTAssertEqual(boundaryIndex, 0)
        // No clamp — delta passes through unchanged
        XCTAssertEqual(effectiveDelta, 0.1, accuracy: 1e-10, "first window delta unchanged")

        let result = GridLayout.adjustSplitRatio(
            ratios: ratios,
            index: boundaryIndex,
            delta: effectiveDelta,
            minRatio: GridLayout.minimumRatio
        )
        guard case .success(let newRatios) = result else {
            XCTFail("adjustSplitRatio unexpectedly failed"); return
        }
        XCTAssertGreaterThan(newRatios[0], 0.5, "grow should expand the first focused window")
        XCTAssertLessThan(newRatios[1], 0.5)
    }

    func test_DW_5_1_sole_window_noop_no_crash() {
        // 1-window cell: no boundary to adjust; resolveBoundaryAndDelta must signal
        // an invalid boundary (< 0) so the caller can guard-fail early.
        let ratios = [1.0]
        let (boundaryIndex, _) = GridResize.resolveBoundaryAndDelta(
            idx: 0,
            ratios: ratios,
            delta: 0.1
        )
        XCTAssertLessThan(boundaryIndex, 0, "sole window yields no valid boundary index")
    }

    func test_DW_5_1_three_window_cell_middle_window_no_negation() {
        // Middle window (idx=1) in a 3-window cell: boundary=1, no clamp → delta unchanged.
        let ratios = [1.0/3.0, 1.0/3.0, 1.0/3.0]
        let (boundaryIndex, effectiveDelta) = GridResize.resolveBoundaryAndDelta(
            idx: 1,
            ratios: ratios,
            delta: 0.1
        )
        XCTAssertEqual(boundaryIndex, 1, "middle window uses its own boundary index")
        XCTAssertEqual(effectiveDelta, 0.1, accuracy: 1e-10, "middle window delta unchanged")
    }

    // MARK: - DW-5.2: Split ratios recalculated (not equalized) on membership change

    func test_DW_5_2_assignWindow_preserves_existing_ratios() async {
        // Cell has 2 windows with custom 70/30 split. Adding a third window should
        // scale both ratios proportionally (recalculate), not replace with 33/33/33.
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "s1", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "s1", cellIDs: ["left"])
        // Seed 2 windows
        await gridState._test_assignWindow(spaceID: "s1", cellID: "left", windowID: 1)
        await gridState._test_assignWindow(spaceID: "s1", cellID: "left", windowID: 2)
        // Set custom 70/30 split
        await gridState.setCellSplitRatios(spaceID: "s1", cellID: "left", ratios: [0.7, 0.3])

        let before = await gridState.getCellSplitRatios(spaceID: "s1", cellID: "left")
        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(before[0], 0.7, accuracy: 1e-6)

        // Add a third window — this must recalculate, not equalize
        await gridState.assignWindow(3, toCellID: "left", inSpace: "s1")

        let after = await gridState.getCellSplitRatios(spaceID: "s1", cellID: "left")
        XCTAssertEqual(after.count, 3, "should have 3 ratios after assigning 3rd window")

        // Equal ratios would give [0.333, 0.333, 0.333]; recalculate must not equalize.
        // recalculateSplitsAfterAddition([0.7, 0.3], newIndex:2):
        //   newRatio=1/3, scale=2/3 → [0.4667, 0.2, 0.333] approximately.
        // First ratio must still be larger than second (70/30 proportion preserved).
        XCTAssertNotEqual(after[0], after[1], accuracy: 1e-6,
            "recalculated ratios should preserve relative proportions, not equalize")
        XCTAssertGreaterThan(after[0], after[1],
            "original 70/30 proportion should survive after recalculation")
    }

    func test_DW_5_2_removeWindow_preserves_existing_ratios() async {
        // Cell has 3 windows with unequal 0.5/0.3/0.2 splits. Removing the middle
        // window should distribute its ratio to the remaining two, not equalize.
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "s1", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "s1", cellIDs: ["left"])
        await gridState._test_assignWindow(spaceID: "s1", cellID: "left", windowID: 1)
        await gridState._test_assignWindow(spaceID: "s1", cellID: "left", windowID: 2)
        await gridState._test_assignWindow(spaceID: "s1", cellID: "left", windowID: 3)
        // Set unequal 0.5/0.3/0.2 split
        await gridState.setCellSplitRatios(spaceID: "s1", cellID: "left", ratios: [0.5, 0.3, 0.2])

        // Remove middle window (id=2, index 1)
        await gridState.removeWindow(2, fromSpace: "s1")

        let after = await gridState.getCellSplitRatios(spaceID: "s1", cellID: "left")
        XCTAssertEqual(after.count, 2, "should have 2 ratios after removing one window")

        // Equal ratios would give [0.5, 0.5]; recalculate distributes removed ratio.
        // recalculateSplitsAfterRemoval([0.5, 0.3, 0.2], removedIndex:1):
        //   removed=0.3, bonus=0.15 each → [0.65, 0.35] normalized.
        XCTAssertNotEqual(after[0], after[1], accuracy: 1e-6,
            "removed ratio should be distributed proportionally, not yield equal splits")
        XCTAssertGreaterThan(after[0], after[1], "first window should retain larger share")

        let sum = after.reduce(0, +)
        XCTAssertEqual(sum, 1.0, accuracy: 1e-6, "ratios must sum to 1.0")
    }

    func test_DW_5_2_first_window_into_empty_cell_gets_unity_ratio() async {
        // First window assigned to an empty cell → [1.0]
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "s1", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "s1", cellIDs: ["left"])
        await gridState.assignWindow(42, toCellID: "left", inSpace: "s1")
        let ratios = await gridState.getCellSplitRatios(spaceID: "s1", cellID: "left")
        XCTAssertEqual(ratios, [1.0], "sole window in cell should have ratio [1.0]")
    }

    func test_DW_5_2_prependWindow_preserves_existing_ratios() async {
        // prependWindow is called by cross-display move. Custom 60/40 ratio must survive.
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "s1", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "s1", cellIDs: ["left"])
        await gridState._test_assignWindow(spaceID: "s1", cellID: "left", windowID: 10)
        await gridState._test_assignWindow(spaceID: "s1", cellID: "left", windowID: 20)
        // Custom 60/40 split
        await gridState.setCellSplitRatios(spaceID: "s1", cellID: "left", ratios: [0.6, 0.4])

        // prependWindow inserts at index 0
        await gridState.prependWindow(30, toCellID: "left", inSpace: "s1")

        let after = await gridState.getCellSplitRatios(spaceID: "s1", cellID: "left")
        XCTAssertEqual(after.count, 3)
        // recalculateSplitsAfterAddition([0.6, 0.4], newIndex:0) → [0.333, 0.4, 0.267] approx.
        // Key invariant: the two existing windows must NOT have equal ratios.
        XCTAssertNotEqual(after[1], after[2], accuracy: 1e-6,
            "original 60/40 proportion should survive after prepend recalculation")
    }

    // MARK: - DW-5.3: sweepDisplacedWindows calls applyCellLayout for target + source

    // Integration test: after displacement sweep, applyCellLayout is invoked for
    // both the target cell and the vacated source cell.
    // Uses GridApply._test_applyCellLayoutHook to intercept calls without a live display.
    func test_DW_5_3_sweep_calls_applyCellLayout_for_target_and_source_cells() async {
        // Window 100 is tracked in space "1" / cell "left",
        // but OS wmState reports it on space "2".
        var wmState = WindowManagerState()
        wmState.metadata.activeSpaceID = UInt64(1)

        var win = WindowState(id: 100)
        win.spaces = [UInt64(2)]
        win.role = "AXWindow"
        win.subrole = "AXStandardWindow"
        win.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        wmState.windows["100"] = win
        wmState.spaces["1"] = SpaceState(id: 1, uuid: "u1", type: "user", displayUUID: "d1")
        wmState.spaces["2"] = SpaceState(id: 2, uuid: "u2", type: "user", displayUUID: "d2")

        let stateProvider = MockStateProvider(state: wmState)
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "1", layoutID: "test")
        await gridState._test_setCells(spaceID: "1", cellIDs: ["left"])
        await gridState._test_assignWindow(spaceID: "1", cellID: "left", windowID: 100)
        await gridState._test_setLayout(spaceID: "2", layoutID: "test")
        await gridState._test_setCells(spaceID: "2", cellIDs: ["left"])
        await gridState.setFocus(spaceID: "2", cellID: "left", windowIndex: 0)

        // Real GridApply with a hook to capture invocations.
        let gridApply = GridApply()
        var capturedCalls: [(spaceID: String, cellID: String)] = []
        let lock = NSLock()
        gridApply._test_applyCellLayoutHook = { spaceID, cellID in
            lock.lock()
            capturedCalls.append((spaceID: spaceID, cellID: cellID))
            lock.unlock()
        }

        let reconciler = GridReconciler()
        reconciler._test_setup(stateProvider: stateProvider, gridState: gridState)
        reconciler._test_setGridApply(gridApply)

        await reconciler._test_sweepDisplacedWindows()

        let calledSpaces = Set(capturedCalls.map { $0.spaceID })
        XCTAssertTrue(calledSpaces.contains("2"),
            "applyCellLayout must be called for target space after displacement")
        XCTAssertTrue(calledSpaces.contains("1"),
            "applyCellLayout must be called for vacated source space after displacement")
    }

    // MARK: - DW-5.4: Cross-display move abort predicate + err.verify log

    // Pure predicate tests: shouldAbortCrossDisplayMove.
    func test_DW_5_4_move_abort_predicate_true_when_failed() {
        XCTAssertTrue(GridWindowMove.shouldAbortCrossDisplayMove(moved: false),
            "should abort when moveWindowToSpace returns false")
    }

    func test_DW_5_4_move_abort_predicate_false_when_succeeded() {
        XCTAssertFalse(GridWindowMove.shouldAbortCrossDisplayMove(moved: true),
            "should not abort when moveWindowToSpace succeeds")
    }

    // err.verify log is produced on the SLS-fallback branch of handleWindowCreated
    // when the locked cell's space is inactive and moveWindowToSpace returns false.
    func test_DW_5_4_err_verify_logged_on_sls_fallback_failure() async {
        // Window 500 on space 100 matches a locked-cell rule targeting space 200.
        // Space 200 is NOT active on any display → SLS-fallback branch.
        // MockWindowController returns false for moveWindowToSpace.
        var wmState = WindowManagerState()
        wmState.metadata.activeSpaceID = 100

        var win = makeWindow(id: 500, appName: "LockedApp", pid: 9)
        win.spaces = [UInt64(100)]
        wmState.windows["500"] = win
        // No displays → findDisplayUUIDForSpace("200", ...) returns nil → SLS-fallback
        wmState.displays = []
        wmState.spaces["100"] = SpaceState(id: 100, uuid: "u100", type: "user", displayUUID: "d1")
        wmState.spaces["200"] = SpaceState(id: 200, uuid: "u200", type: "user", displayUUID: "d2")
        wmState.applications["9"] = ApplicationState._test_make(pid: 9, name: "LockedApp", bundleID: "com.example.lockedapp")

        let appRules = [GridAppRule(
            app: "com.example.lockedapp",
            preferredCell: "left",
            float: false,
            locked: true,
            preferredStackMode: nil
        )]

        let mockController = MockWindowController()
        // moveWindowToSpace returns false → triggers err.verify log
        mockController.moveToSpaceResult = false

        let stateProvider = MockStateProvider(state: wmState)
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "100", layoutID: "test")
        await gridState._test_setCells(spaceID: "100", cellIDs: ["other"])
        await gridState._test_setLayout(spaceID: "200", layoutID: "test")
        await gridState._test_setCells(spaceID: "200", cellIDs: ["left"])
        // Seed a window in space 200 cell "left" so the assignment path fires
        await gridState._test_assignWindow(spaceID: "200", cellID: "left", windowID: 999)

        // Capture log events via _test_observer
        var capturedEvents: [String] = []
        let lock = NSLock()
        JSONLogger.shared._test_observer = { ev in
            lock.lock()
            capturedEvents.append(ev)
            lock.unlock()
        }
        defer { JSONLogger.shared._test_observer = nil }

        let reconciler = GridReconciler()
        reconciler._test_setup(
            stateProvider: stateProvider,
            gridState: gridState,
            lockedRules: appRules
        )
        reconciler._test_setWindowController(mockController)

        await reconciler._test_triggerWindowCreated(windowID: 500, pid: 9)

        XCTAssertTrue(
            capturedEvents.contains("err.verify"),
            "err.verify must be logged when moveWindowToSpace returns false on SLS-fallback branch"
        )
    }

    // MARK: - DW-5.5: assignAutoFlow logs warn.assign.dropped when all cells locked

    func test_DW_5_5_all_cells_locked_logs_dropped_wids() {
        let layout = makeLayout(cellIDs: ["left", "right"])
        let cellBounds = makeCellBounds(cellIDs: ["left", "right"])
        // Locked rules for all cells
        let appRules = [
            GridAppRule(app: "com.thegrid.notify", preferredCell: "left",
                        float: false, locked: true, preferredStackMode: nil),
            GridAppRule(app: "com.thegrid.notify2", preferredCell: "right",
                        float: false, locked: true, preferredStackMode: nil),
        ]
        let windows = [makeWindow(id: 1), makeWindow(id: 2)]

        var capturedEvents: [String] = []
        let lock = NSLock()
        JSONLogger.shared._test_observer = { ev in
            lock.lock()
            capturedEvents.append(ev)
            lock.unlock()
        }
        defer { JSONLogger.shared._test_observer = nil }

        let result = GridAssignment.assignWindows(
            windows: windows,
            layout: layout,
            cellBounds: cellBounds,
            appRules: appRules,
            previousAssignments: [:],
            strategy: .autoFlow,
            bundleIDLookup: { _ in "com.apple.Safari" }
        )

        // No windows should be placed in locked cells (no matching bundle IDs)
        let leftWindows = result.assignments["left"] ?? []
        let rightWindows = result.assignments["right"] ?? []
        XCTAssertFalse(leftWindows.contains(1) || leftWindows.contains(2) ||
                       rightWindows.contains(1) || rightWindows.contains(2),
            "non-matching windows must not land in locked cells")

        // warn.assign.dropped must have been logged
        XCTAssertTrue(
            capturedEvents.contains("warn.assign.dropped"),
            "warn.assign.dropped must be logged when all cells are locked and windows are dropped"
        )
    }

    func test_DW_5_5_partial_lock_still_assigns_without_dropping() {
        let layout = makeLayout(cellIDs: ["left", "right"])
        let cellBounds = makeCellBounds(cellIDs: ["left", "right"])
        // Only right cell locked
        let appRules = [
            GridAppRule(app: "com.thegrid.notify", preferredCell: "right",
                        float: false, locked: true, preferredStackMode: nil),
        ]
        let windows = [makeWindow(id: 1)]

        var capturedEvents: [String] = []
        let lock = NSLock()
        JSONLogger.shared._test_observer = { ev in
            lock.lock()
            capturedEvents.append(ev)
            lock.unlock()
        }
        defer { JSONLogger.shared._test_observer = nil }

        let result = GridAssignment.assignWindows(
            windows: windows,
            layout: layout,
            cellBounds: cellBounds,
            appRules: appRules,
            previousAssignments: [:],
            strategy: .autoFlow,
            bundleIDLookup: { _ in "com.apple.Safari" }
        )

        let assignedToLeft = result.assignments["left"] ?? []
        XCTAssertTrue(assignedToLeft.contains(1),
            "window should be assigned to the unlocked left cell")
        XCTAssertFalse(
            capturedEvents.contains("warn.assign.dropped"),
            "warn.assign.dropped must NOT be logged when a valid cell is available"
        )
    }
}
