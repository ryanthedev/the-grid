import XCTest
@testable import GridServer

// vana: `layout apply` swallowed a 270x113 Zoom popup into a tab and made it
// the focused window. The apply now takes only standard windows, or windows
// already in the space's cells.
final class ApplyFilterTests: XCTestCase {

    private func window(_ id: UInt32, modal: Bool) -> WindowState {
        var w = WindowState(id: id)
        w.role = "AXWindow"
        w.subrole = "AXStandardWindow"
        w.hasFullscreenButton = true
        w.isModal = modal
        w.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        w.spaces = [1]
        w.appName = "zoom.us"
        return w
    }

    func test_apply_skips_unassigned_popups_but_keeps_assigned_windows() {
        var wmState = WindowManagerState()
        wmState.windows["1"] = window(1, modal: false)
        wmState.windows["2"] = window(2, modal: true)
        wmState.windows["3"] = window(3, modal: true)

        let ids = GridApply().filterTileableFromState(
            wmState: wmState,
            spaceID: "1",
            exclusions: GridWindowExclusion(),
            alreadyAssigned: [3]
        ).map(\.id).sorted()

        XCTAssertEqual(ids, [1, 3], "popup 2 is not adopted; 3 was already in a cell")
    }
}
