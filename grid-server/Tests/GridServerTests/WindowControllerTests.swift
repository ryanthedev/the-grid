import XCTest
import CoreGraphics
@testable import GridServer

// MockWindowController: test fake that records focusWindow and setWindowFrame calls.
// Conforms to WindowController so it can be injected into GridApply and GridFocus.
// @unchecked Sendable: tests are single-threaded; no real concurrency.
final class MockWindowController: WindowController, @unchecked Sendable {

    // Recorded call types for assertion
    enum Call: Equatable {
        case focusWindow(windowID: UInt32, pid: pid_t)
        case setWindowFrame(windowID: UInt32, pid: pid_t, frame: CGRect)
    }

    // All recorded calls in order
    var calls: [Call] = []

    // Configurable return values
    var focusResult: Bool = true
    var setFrameResult: Bool = true

    func focusWindow(windowID: UInt32, pid: pid_t) async -> Bool {
        calls.append(.focusWindow(windowID: windowID, pid: pid))
        return focusResult
    }

    func setWindowFrame(windowID: UInt32, pid: pid_t, frame: CGRect) async -> Bool {
        calls.append(.setWindowFrame(windowID: windowID, pid: pid, frame: frame))
        return setFrameResult
    }
}

// Tests for the WindowController port protocol.
final class WindowControllerTests: XCTestCase {

    // DW-3.1: Protocol exists with both async methods.
    // Verified at compile time: MockWindowController conforms to WindowController.
    // This test confirms the mock can be used as the protocol type.
    func test_DW_3_1_protocol_has_both_async_methods() async {
        let mock = MockWindowController()
        let port: any WindowController = mock

        // Exercise both methods to confirm they compile and run
        let focusResult = await port.focusWindow(windowID: 100, pid: 1234)
        let frameResult = await port.setWindowFrame(
            windowID: 100,
            pid: 1234,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertTrue(focusResult, "focusWindow should return true from mock")
        XCTAssertTrue(frameResult, "setWindowFrame should return true from mock")
        XCTAssertEqual(mock.calls.count, 2, "Both port methods should be callable and recorded")
    }

    // DW-3.4: MockWindowController records focusWindow calls with window ID and pid.
    func test_DW_3_4_mock_records_focus_call() async {
        let mock = MockWindowController()

        _ = await mock.focusWindow(windowID: 555, pid: 9999)

        XCTAssertEqual(mock.calls.count, 1)
        if case .focusWindow(let wid, let pid) = mock.calls[0] {
            XCTAssertEqual(wid, 555)
            XCTAssertEqual(pid, 9999)
        } else {
            XCTFail("First call should be focusWindow")
        }
    }

    // DW-3.4: MockWindowController records setWindowFrame calls with window ID, pid, and frame.
    func test_DW_3_4_mock_records_set_frame_call() async {
        let mock = MockWindowController()
        let frame = CGRect(x: 100, y: 200, width: 960, height: 540)

        _ = await mock.setWindowFrame(windowID: 777, pid: 1111, frame: frame)

        XCTAssertEqual(mock.calls.count, 1)
        if case .setWindowFrame(let wid, let pid, let recordedFrame) = mock.calls[0] {
            XCTAssertEqual(wid, 777)
            XCTAssertEqual(pid, 1111)
            XCTAssertEqual(recordedFrame, frame)
        } else {
            XCTFail("First call should be setWindowFrame")
        }
    }

    // DW-3.5a: Layout apply calls setWindowFrame through the injected WindowController port.
    // Uses a wmState with one window and a seeded GridState with a layout + cell assignment,
    // then calls applyPlacementsViaAX indirectly through _test_applyPlacements.
    // Tests that the port receives the call with the correct windowID.
    func test_DW_3_5a_layout_apply_calls_set_frame() async {
        let mockWC = MockWindowController()
        let mockState = MockStateProvider()
        let gridState = GridState()

        // Wire up GridApply with the mock window controller
        let gridApply = GridApply()
        gridApply._test_setup(
            gridState: gridState,
            stateProvider: mockState,
            windowController: mockWC
        )

        // Inject a window into StateManager so ManipulationContext.from can find it
        var wmState = WindowManagerState()
        var window = WindowState(id: 300)
        window.pid = 42
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        wmState.windows["300"] = window
        await StateManager.shared._test_setState(wmState)

        // Call the test placement method with one placement
        let placement = GridWindowPlacement(windowID: 300, bounds: CGRect(x: 0, y: 0, width: 960, height: 540))
        let failed = await gridApply._test_applyPlacements([placement])

        // The window should have been placed (not in failed set)
        XCTAssertFalse(failed.contains(300), "Window 300 should not be in failed set")

        // The port should have received a setWindowFrame call for window 300
        let frameCalls = mockWC.calls.filter {
            if case .setWindowFrame(let wid, _, _) = $0 { return wid == 300 }
            return false
        }
        XCTAssertFalse(frameCalls.isEmpty, "setWindowFrame should be called through the WindowController port")
    }

    // DW-3.5b: Focus navigates to the correct window via the WindowController port.
    // focusWindowByID should call focusWindow on the injected port.
    func test_DW_3_5b_focus_calls_focus_window() async {
        let mockWC = MockWindowController()
        let gridState = GridState()

        // Seed state with one window on space 100
        var wmState = WindowManagerState()
        var window = WindowState(id: 400)
        window.pid = 77
        window.spaces = [100]
        wmState.windows["400"] = window
        // No focused window yet so mismatch detection is skipped
        wmState.metadata.focusedWindowID = 400

        let mockState = MockStateProvider(state: wmState)

        let gridFocus = GridFocus()
        gridFocus._test_setup(
            gridState: gridState,
            stateProvider: mockState,
            windowController: mockWC
        )

        // Call focusWindowByID -- should go through the port
        let result = try? await gridFocus.focusWindowByID(400)

        XCTAssertEqual(result, 400, "focusWindowByID should return the requested window ID")

        // The port should have received at least one focusWindow call for window 400
        let focusCalls = mockWC.calls.filter {
            if case .focusWindow(let wid, _) = $0 { return wid == 400 }
            return false
        }
        XCTAssertFalse(focusCalls.isEmpty, "focusWindow should be called through the WindowController port")

        // Verify the correct pid was passed
        if case .focusWindow(_, let pid) = mockWC.calls.first {
            XCTAssertEqual(pid, 77, "focusWindow should receive the window's pid from state")
        }
    }

    // DW-3.5c: Focus handles a missing window gracefully by throwing windowNotFound.
    func test_DW_3_5c_focus_missing_window_throws() async {
        let mockWC = MockWindowController()
        let gridState = GridState()

        // Empty state -- no windows
        let mockState = MockStateProvider(state: WindowManagerState())

        let gridFocus = GridFocus()
        gridFocus._test_setup(
            gridState: gridState,
            stateProvider: mockState,
            windowController: mockWC
        )

        // focusWindowByID for a nonexistent window should throw windowNotFound
        do {
            _ = try await gridFocus.focusWindowByID(999)
            XCTFail("Should have thrown for missing window")
        } catch GridFocusError.windowNotFound(let wid) {
            XCTAssertEqual(wid, 999, "Error should name the missing window ID")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // Port should not have been called
        XCTAssertTrue(mockWC.calls.isEmpty, "Port should not be called when window is not found in state")
    }
}
