import XCTest
@testable import GridServer

// On vana every @terminal launch timed out: kCGWindowName is empty there, so
// the scratch window was never found by its title.
final class TerminalScratchMatchTests: XCTestCase {

    func test_scratch_window_found_by_ax_title_when_window_title_is_empty() {
        var window = WindowState(id: 1)
        window.axTitle = "grid:scratch"
        XCTAssertTrue(GridTerminalManager.isScratchWindow(window))
    }

    func test_other_windows_are_not_scratch() {
        var window = WindowState(id: 2)
        window.title = "~/repos"
        window.axTitle = "~/repos"
        XCTAssertFalse(GridTerminalManager.isScratchWindow(window))
        XCTAssertFalse(GridTerminalManager.isScratchWindow(WindowState(id: 3)))
    }
}
