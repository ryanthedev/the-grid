import XCTest
@testable import GridServer

// Tests for the pure coordinate-math helpers extracted from enrichDisplayInfo.
//
// These helpers take only primitive CGRect inputs, so no hardware or NSScreen
// mocking is required. The three helpers under test are:
//   - selectFrameSource(bounds:)
//   - computeFrameQuartz(bounds:cocoaFrame:mainScreenHeight:)
//   - computeVisibleFrame(quartzFrame:cocoaScreen:cocoaVisibleScreen:)
final class DisplayInfoHelperTests: XCTestCase {

    // MARK: - selectFrameSource

    // DW-1.4(b): non-empty CGRect → .success path taken (CGDisplayBounds used verbatim)
    func test_DW_1_4_select_success_for_non_empty_bounds() {
        let bounds = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        XCTAssertEqual(DisplayInfoHelper.selectFrameSource(bounds: bounds), .success)
    }

    // DW-1.4(b): CGRect.zero → .fallback path taken (hand-rolled flip, warn emitted by caller)
    func test_DW_1_4_select_fallback_for_zero_bounds() {
        XCTAssertEqual(DisplayInfoHelper.selectFrameSource(bounds: .zero), .fallback)
    }

    // Edge: non-zero origin but zero size → still fallback (no displayable area)
    func test_DW_1_4_select_fallback_for_zero_size_nonzero_origin() {
        let bounds = CGRect(x: 100, y: 0, width: 0, height: 0)
        XCTAssertEqual(DisplayInfoHelper.selectFrameSource(bounds: bounds), .fallback)
    }

    // MARK: - computeFrameQuartz

    // DW-1.1 / DW-1.4(c): success path returns CGDisplayBounds output verbatim
    func test_DW_1_1_success_path_returns_cgdisplaybounds_rect() {
        let bounds = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
        let cocoaFrame = CGRect(x: 2560, y: 200, width: 1920, height: 1080)
        let result = DisplayInfoHelper.computeFrameQuartz(
            bounds: bounds,
            cocoaFrame: cocoaFrame,
            mainScreenHeight: 1440
        )
        XCTAssertEqual(result, bounds)
    }

    // DW-1.1 / DW-1.4(c): fallback path returns hand-rolled flip
    // Formula: quartzY = mainScreenHeight - (cocoaFrame.origin.y + cocoaFrame.height)
    func test_DW_1_1_fallback_path_returns_hand_rolled_flip() {
        // Simulate CGDisplayBounds returning zero (disconnected display edge case)
        let bounds = CGRect.zero
        let cocoaFrame = CGRect(x: 2560, y: 200, width: 1920, height: 1080)
        let mainH: CGFloat = 1440
        // Expected: quartzY = 1440 - (200 + 1080) = 160
        let expected = CGRect(x: 2560, y: 160, width: 1920, height: 1080)
        let result = DisplayInfoHelper.computeFrameQuartz(
            bounds: bounds,
            cocoaFrame: cocoaFrame,
            mainScreenHeight: mainH
        )
        XCTAssertEqual(result, expected)
    }

    // MARK: - computeVisibleFrame

    // DW-1.2 / DW-1.4(a): menu-bar-only inset (top=24, others=0)
    // Cocoa: frame.maxY - visibleFrame.maxY = 24 → topInset = 24
    // Quartz result: y += 24, height -= 24
    func test_DW_1_2_menubar_only_inset() {
        // Cocoa coords: main display, origin at (0,0)
        // screen.frame: y=0, height=1440
        // screen.visibleFrame: y=0, height=1416 (menu bar = 24px at top in Cocoa = maxY side)
        let cocoaFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let cocoaVisible = CGRect(x: 0, y: 0, width: 2560, height: 1416)
        let quartzFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)

        let result = DisplayInfoHelper.computeVisibleFrame(
            quartzFrame: quartzFrame,
            cocoaScreen: cocoaFrame,
            cocoaVisibleScreen: cocoaVisible
        )

        // topInset = cocoaFrame.maxY - cocoaVisible.maxY = 1440 - 1416 = 24
        // In Quartz: visible y = quartzFrame.y + topInset = 0 + 24 = 24
        // visible height = 1440 - 24 = 1416
        let expected = CGRect(x: 0, y: 24, width: 2560, height: 1416)
        XCTAssertEqual(result, expected)
    }

    // DW-1.2 / DW-1.4(a): dock-on-bottom inset (bottom=64, top=24 menu bar)
    // bottomInset = cocoaVisible.minY - cocoaFrame.minY
    func test_DW_1_2_dock_on_bottom() {
        // Cocoa: screen y=0..1440, visible y=64..1416 (dock 64px bottom, menubar 24px top)
        let cocoaFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let cocoaVisible = CGRect(x: 0, y: 64, width: 2560, height: 1352)
        let quartzFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)

        let result = DisplayInfoHelper.computeVisibleFrame(
            quartzFrame: quartzFrame,
            cocoaScreen: cocoaFrame,
            cocoaVisibleScreen: cocoaVisible
        )

        // topInset    = 1440 - (64 + 1352) = 1440 - 1416 = 24
        // bottomInset = 64 - 0 = 64
        // In Quartz: y = 0 + 24 = 24, height = 1440 - 24 - 64 = 1352, x=0, width=2560
        let expected = CGRect(x: 0, y: 24, width: 2560, height: 1352)
        XCTAssertEqual(result, expected)
    }

    // DW-1.2 / DW-1.4(a): dock-on-left inset (left=64, top=24 menu bar)
    func test_DW_1_2_dock_on_left() {
        // Cocoa: screen x=0..2560, visible x=64..2560 (dock 64px left, menubar 24px top)
        let cocoaFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let cocoaVisible = CGRect(x: 64, y: 0, width: 2496, height: 1416)
        let quartzFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)

        let result = DisplayInfoHelper.computeVisibleFrame(
            quartzFrame: quartzFrame,
            cocoaScreen: cocoaFrame,
            cocoaVisibleScreen: cocoaVisible
        )

        // topInset  = 1440 - (0 + 1416) = 24
        // leftInset = 64 - 0 = 64
        // In Quartz: x = 0 + 64 = 64, y = 0 + 24 = 24
        // width = 2560 - 64 = 2496, height = 1440 - 24 = 1416
        let expected = CGRect(x: 64, y: 24, width: 2496, height: 1416)
        XCTAssertEqual(result, expected)
    }

    // DW-1.2 / DW-1.4(a): full-screen / no inset — visible == frame
    func test_DW_1_2_no_inset() {
        let cocoaFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let cocoaVisible = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let quartzFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)

        let result = DisplayInfoHelper.computeVisibleFrame(
            quartzFrame: quartzFrame,
            cocoaScreen: cocoaFrame,
            cocoaVisibleScreen: cocoaVisible
        )

        XCTAssertEqual(result, quartzFrame)
    }
}
