import XCTest
@testable import GridServer

// Tests for Phase 1 and Phase 2 of the picker-window-placement bug fix.
//
// Phase 1 (DW-1.x): PID-tagged multi-shot pending launch target.
//   Phantom/mismatched windows must NOT consume pendingLaunchTarget.
//   The real matching window MUST consume it and land in the target cell.
//
// Phase 2 (DW-2.x): Focused-cell preference for non-picker window creates.
//   New windows prefer the focused cell over least-populated,
//   unless the focused cell is locked by an app rule.
//
// Test doubles:
//   - GridReconciler._test_pendingLaunchTarget() reads the private field.
//   - StateManager._test_setState() seeds wmState without AX/SkyLight queries.
//   - GridReconciler.pickTargetCell(focusedCell:assignments:locked:) is the
//     extracted pure helper that Phase 2 tests exercise directly.

final class PickerPlacementTests: XCTestCase {

    // MARK: - Shared fixture helpers

    private func makeTileableWindow(id: UInt32, pid: pid_t = 42) -> WindowState {
        var w = WindowState(id: id)
        w.pid = pid
        w.appName = "Ghostty"
        w.role = "AXWindow"
        w.subrole = "AXStandardWindow"
        w.hasCloseButton = true
        w.hasFullscreenButton = true
        w.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        return w
    }

    private func makeReconciler(
        gridState: GridState,
        stateManager: StateManager
    ) -> GridReconciler {
        let gridConfig = GridConfig()
        let borderManager = SimpleBorderManager(connectionID: 0)
        let reconciler = GridReconciler()
        reconciler.setup(
            gridState: gridState,
            gridConfig: gridConfig,
            stateManager: stateManager,
            simpleBorderManager: borderManager
        )
        return reconciler
    }

    private func eventContext() -> EventContext {
        EventContext(source: .manual(reason: "test"))
    }

    // MARK: - DW-1.2: Phantom burst does not consume pending target

    // Set a pending target with pid=nil (PID callback hasn't fired yet).
    // Fire three windowCreated events for windows that are NOT present in
    // StateManager's wmState (simulates phantom AX window bursts).
    // The guard inside handlePendingLaunchWindow returns early for unknown wids
    // without touching pendingLaunchTarget.
    func test_DW_1_2_phantomBurst_targetSurvives() async throws {
        let gridState = GridState()
        let sm = StateManager.shared
        // Empty wmState — no windows seeded, simulates pre-launch phantom burst.
        await sm._test_setState(WindowManagerState())

        let reconciler = makeReconciler(gridState: gridState, stateManager: sm)

        let target = PendingLaunchTarget(
            spaceID: "1",
            cellID: "left",
            createdAt: CFAbsoluteTimeGetCurrent(),
            pid: nil
        )
        reconciler.setPendingLaunchTarget(target)

        let ctx = eventContext()
        // Fire three phantom window creates — none are in wmState
        try await reconciler.handle(.windowCreated(windowID: 201, pid: 0), context: ctx)
        try await reconciler.handle(.windowCreated(windowID: 202, pid: 0), context: ctx)
        try await reconciler.handle(.windowCreated(windowID: 203, pid: 0), context: ctx)

        // Target must survive: phantom burst must not consume it
        let surviving = reconciler._test_pendingLaunchTarget()
        XCTAssertNotNil(surviving, "pendingLaunchTarget must survive phantom burst (3 unknown wids)")
    }

    // MARK: - DW-1.3: PID-mismatch window does not consume pending target

    // Set a pending target with pid=100. Fire a windowCreated event from pid=999.
    // The PID check in handlePendingLaunchWindow must skip-not-consume.
    func test_DW_1_3_pidMismatch_targetSurvives() async throws {
        let gridState = GridState()
        let sm = StateManager.shared
        await sm._test_setState(WindowManagerState())

        let reconciler = makeReconciler(gridState: gridState, stateManager: sm)

        let target = PendingLaunchTarget(
            spaceID: "1",
            cellID: "left",
            createdAt: CFAbsoluteTimeGetCurrent(),
            pid: 100
        )
        reconciler.setPendingLaunchTarget(target)

        let ctx = eventContext()
        // Window from a different process (pid=999 vs target.pid=100)
        try await reconciler.handle(.windowCreated(windowID: 301, pid: 999), context: ctx)

        let surviving = reconciler._test_pendingLaunchTarget()
        XCTAssertNotNil(surviving, "pendingLaunchTarget must survive PID-mismatch window create")
    }

    // MARK: - DW-1.4: Matching window claims pending target and lands in target cell

    // Set a pending target with pid=42, spaceID="1", cellID="left".
    // Seed StateManager with a tileable window from pid=42.
    // Set metadata.activeSpaceID=1 so findCurrentSpaceID resolves to "1".
    // Set layout on gridState for space "1".
    // Fire windowCreated — the target must be consumed and window must be in "left".
    func test_DW_1_4_realWindow_claimsPendingTarget() async throws {
        let gridState = GridState()
        let sm = StateManager.shared

        // Build a wmState with the real window and correct active space
        var wmState = WindowManagerState()
        let window = makeTileableWindow(id: 401, pid: 42)
        wmState.windows["401"] = window
        wmState.metadata.activeSpaceID = 1
        await sm._test_setState(wmState)

        // Apply a layout to the space so layoutID is non-empty
        await gridState.setCurrentLayout(spaceID: "1", layoutID: "test", layoutIndex: 0)
        // Seed assignments so the cell exists in gridState
        await gridState.assignWindow(9999, toCellID: "left", inSpace: "1")

        let reconciler = makeReconciler(gridState: gridState, stateManager: sm)

        let target = PendingLaunchTarget(
            spaceID: "1",
            cellID: "left",
            createdAt: CFAbsoluteTimeGetCurrent(),
            pid: 42
        )
        reconciler.setPendingLaunchTarget(target)

        let ctx = eventContext()
        try await reconciler.handle(.windowCreated(windowID: 401, pid: 42), context: ctx)

        // Target must be consumed
        let remaining = reconciler._test_pendingLaunchTarget()
        XCTAssertNil(remaining, "pendingLaunchTarget must be consumed after matching window arrives")

        // Window must land in the target cell ("left")
        let assignments = await gridState.getWindowAssignments(spaceID: "1")
        let leftWindows = assignments["left"] ?? []
        XCTAssertTrue(leftWindows.contains(401),
            "window 401 must be assigned to target cell 'left', got: \(leftWindows)")
    }

    // MARK: - DW-2.1: Focused cell wins over least-populated when eligible

    // assignments: left=[a, b], right=[]  → least-populated is "right"
    // focused: "left"  → focused wins
    // locked: empty
    // Expected: pickTargetCell returns "left"
    func test_DW_2_1_windowCreated_prefersFocusedCell() {
        let assignments: [String: [UInt32]] = [
            "left": [1, 2],
            "right": []
        ]
        let locked: Set<String> = []
        let result = GridReconciler.pickTargetCell(
            focusedCell: "left",
            assignments: assignments,
            locked: locked
        )
        XCTAssertEqual(result, "left",
            "focused cell 'left' must win over least-populated 'right'")
    }

    // MARK: - DW-2.2: Locked focused cell falls back to least-populated

    // assignments: left=[a], right=[]  → least-populated is "right"
    // focused: "left"  → BUT "left" is locked, so skip
    // Expected: pickTargetCell returns "right" (least-populated non-locked)
    func test_DW_2_2_windowCreated_fallsBackToLeastPopulated() {
        let assignments: [String: [UInt32]] = [
            "left": [1],
            "right": []
        ]
        let locked: Set<String> = ["left"]
        let result = GridReconciler.pickTargetCell(
            focusedCell: "left",
            assignments: assignments,
            locked: locked
        )
        XCTAssertEqual(result, "right",
            "locked focused cell must be skipped; should fall back to least-populated 'right'")

        // Also verify nil focused cell falls back
        let resultNoFocus = GridReconciler.pickTargetCell(
            focusedCell: nil,
            assignments: assignments,
            locked: locked
        )
        XCTAssertEqual(resultNoFocus, "right",
            "nil focused cell must fall back to least-populated non-locked cell 'right'")
    }
}
