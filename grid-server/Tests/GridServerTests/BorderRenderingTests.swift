import XCTest
import CoreGraphics
@testable import GridServer

// MockBorderRenderer: test fake that records all calls for assertion.
// Conforms to BorderRendering so it can be injected into GridReconciler.
// @unchecked Sendable: tests are single-threaded; no real concurrency.
final class MockBorderRenderer: BorderRendering, @unchecked Sendable {

    // Recorded call types for assertion
    enum Call: Equatable {
        case setCellAssignments(
            assignments: [UInt32: String],
            displayUUID: String,
            focusedWindowID: UInt32?,
            source: String
        )
        case updateFocus(windowID: UInt32, displayUUID: String)
        case handleWindowDestroyed(windowID: UInt32)
        case handleWindowMoved(windowID: UInt32, frame: CGRect)
        case handleDisplayDisconnected(displayUUID: String)
    }

    // All recorded calls in order
    var calls: [Call] = []

    func setCellAssignments(
        _ assignments: [UInt32: String],
        forDisplay displayUUID: String,
        focusedWindowID: UInt32?,
        cellStackModes: [String: String],
        windowOrder: [String: [UInt32]]?,
        displayFrame: CGRect?,
        source: String,
        liveWids: [UInt32]?
    ) async {
        calls.append(.setCellAssignments(
            assignments: assignments,
            displayUUID: displayUUID,
            focusedWindowID: focusedWindowID,
            source: source
        ))
    }

    func updateFocus(newFocusedWindow: UInt32, displayUUID: String) async {
        calls.append(.updateFocus(windowID: newFocusedWindow, displayUUID: displayUUID))
    }

    func handleWindowDestroyed(windowID: UInt32) async {
        calls.append(.handleWindowDestroyed(windowID: windowID))
    }

    func handleWindowMoved(windowID: UInt32, newFrame: CGRect) async {
        calls.append(.handleWindowMoved(windowID: windowID, frame: newFrame))
    }

    func handleDisplayDisconnected(displayUUID: String) async {
        calls.append(.handleDisplayDisconnected(displayUUID: displayUUID))
    }
}

// Tests for the BorderRendering port protocol.
final class BorderRenderingTests: XCTestCase {

    // DW-2.1: Protocol exists with all 5 async methods.
    // Verified at compile time: MockBorderRenderer conforms to BorderRendering.
    // This test ensures the mock can be assigned to the protocol type.
    func test_DW_2_1_protocol_has_all_five_methods() async {
        let mock = MockBorderRenderer()
        let port: any BorderRendering = mock

        // Exercise all 5 methods to confirm they compile and run
        await port.setCellAssignments(
            [100: "left"],
            forDisplay: "display-1",
            focusedWindowID: 100,
            cellStackModes: ["left": "tabs"],
            windowOrder: ["left": [100]],
            displayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            source: "test",
            liveWids: [100]
        )
        await port.updateFocus(newFocusedWindow: 100, displayUUID: "display-1")
        await port.handleWindowDestroyed(windowID: 100)
        await port.handleWindowMoved(windowID: 100, newFrame: .zero)
        await port.handleDisplayDisconnected(displayUUID: "display-1")

        XCTAssertEqual(mock.calls.count, 5, "All 5 protocol methods should be callable")
    }

    // DW-2.4: MockBorderRenderer records all calls with arguments.
    func test_DW_2_4_mock_records_all_calls() async {
        let mock = MockBorderRenderer()

        await mock.setCellAssignments(
            [200: "right", 300: "left"],
            forDisplay: "display-2",
            focusedWindowID: 200,
            cellStackModes: ["right": "vertical"],
            windowOrder: nil,
            displayFrame: nil,
            source: "reconcile",
            liveWids: [200, 300]
        )
        await mock.updateFocus(newFocusedWindow: 300, displayUUID: "display-2")
        await mock.handleWindowDestroyed(windowID: 400)

        XCTAssertEqual(mock.calls.count, 3)

        // Verify setCellAssignments recorded correct args
        if case .setCellAssignments(let assignments, let uuid, let focused, let source) = mock.calls[0] {
            XCTAssertEqual(assignments, [200: "right", 300: "left"])
            XCTAssertEqual(uuid, "display-2")
            XCTAssertEqual(focused, 200)
            XCTAssertEqual(source, "reconcile")
        } else {
            XCTFail("First call should be setCellAssignments")
        }

        // Verify updateFocus recorded correct args
        XCTAssertEqual(mock.calls[1], .updateFocus(windowID: 300, displayUUID: "display-2"))

        // Verify handleWindowDestroyed recorded correct args
        XCTAssertEqual(mock.calls[2], .handleWindowDestroyed(windowID: 400))
    }

    // DW-2.3 + DW-2.5c: GridReconciler uses BorderRendering port --
    // syncBordersForSpace sends setCellAssignments through the injected mock.
    // Uses the no-layout branch (empty layoutID) which sends empty assignments
    // through the port without needing a real layout definition.
    func test_DW_2_3_and_2_5c_reconciler_sync_borders_calls_set_cell_assignments() async {
        let mockBorder = MockBorderRenderer()
        let mockState = MockStateProvider()
        let gridState = GridState()
        let gridConfig = GridConfig()

        // Seed GridState: space 100 with NO layout (empty layoutID triggers
        // the no-layout branch which sends empty setCellAssignments)
        await gridState._test_setLayout(spaceID: "100", layoutID: "")
        await gridState._test_setCells(spaceID: "100", cellIDs: ["left", "right"])

        let reconciler = GridReconciler()
        reconciler._test_setup(
            stateProvider: mockState,
            gridState: gridState,
            gridConfig: gridConfig,
            borderRenderer: mockBorder
        )

        // Trigger border sync for space -- no-layout path sends empty assignments
        await reconciler._test_triggerSyncBorders(spaceID: "100", displayUUID: "display-1")

        // Verify setCellAssignments was called through the port
        let assignmentCalls = mockBorder.calls.filter {
            if case .setCellAssignments = $0 { return true }
            return false
        }
        XCTAssertFalse(assignmentCalls.isEmpty, "syncBordersForSpace should call setCellAssignments on the border port")
    }

    // DW-2.5a: Focus change triggers updateFocus through the port.
    func test_DW_2_5a_focus_change_triggers_update_focus() async {
        let mockBorder = MockBorderRenderer()
        let gridState = GridState()

        await gridState._test_setLayout(spaceID: "100", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "100", cellIDs: ["left", "right"])
        await gridState._test_assignWindow(spaceID: "100", cellID: "left", windowID: 500)

        var wmState = WindowManagerState()
        wmState.metadata.activeSpaceID = 100
        var window = WindowState(id: 500)
        window.pid = 1
        window.spaces = [100]
        window.appName = "TestApp"
        wmState.windows["500"] = window
        var display = DisplayState(uuid: "display-1", currentSpaceID: 100, spaces: [100])
        display.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        wmState.displays = [display]
        wmState.spaces["100"] = SpaceState(id: 100, uuid: "space-uuid", type: "user", displayUUID: "display-1")

        // Hold strong reference to MockStateProvider so it survives weak storage
        let mockState = MockStateProvider(state: wmState)

        let reconciler = GridReconciler()
        reconciler._test_setup(
            stateProvider: mockState,
            gridState: gridState,
            borderRenderer: mockBorder
        )

        // Trigger focus change
        await reconciler._test_triggerFocusChanged(windowID: 500, spaceID: 100, displayUUID: "display-1")

        // Verify updateFocus was called on the border port
        let focusCalls = mockBorder.calls.filter {
            if case .updateFocus = $0 { return true }
            return false
        }
        XCTAssertFalse(focusCalls.isEmpty, "Focus change should call updateFocus on the border port")
    }

    // DW-2.5b: Window destroy triggers handleWindowDestroyed through the port.
    func test_DW_2_5b_window_destroy_triggers_handle_destroyed() async {
        let mockBorder = MockBorderRenderer()
        let mockState = MockStateProvider()
        let gridState = GridState()

        await gridState._test_setLayout(spaceID: "100", layoutID: "two-col")
        await gridState._test_setCells(spaceID: "100", cellIDs: ["left", "right"])
        await gridState._test_assignWindow(spaceID: "100", cellID: "left", windowID: 500)

        let reconciler = GridReconciler()
        reconciler._test_setup(
            stateProvider: mockState,
            gridState: gridState,
            borderRenderer: mockBorder
        )

        // Trigger window destroyed
        await reconciler._test_triggerWindowDestroyed(windowID: 500)

        // Verify handleWindowDestroyed was called on the border port
        let destroyCalls = mockBorder.calls.filter {
            if case .handleWindowDestroyed(let wid) = $0 { return wid == 500 }
            return false
        }
        XCTAssertFalse(destroyCalls.isEmpty, "Window destroy should call handleWindowDestroyed on the border port")
    }
}
