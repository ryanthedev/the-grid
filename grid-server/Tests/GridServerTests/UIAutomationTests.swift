import XCTest
@testable import GridServer

final class UIAutomationTests: XCTestCase {
    func testOutlineLineCarriesRefRoleTextFrameAndFlags() {
        let node = UINode(ref: "14442:7", depth: 2, role: "AXButton", title: "Send", value: nil, description: nil,
                          frame: CGRect(x: 1204, y: -220, width: 64, height: 28), enabled: false, focused: true)
        XCTAssertEqual(node.line, "    [14442:7] AXButton \"Send\" (1204,-220 64x28) press focused disabled")
    }

    func testUnlabelledControlShowsSubroleAndDuplicateDescriptionIsDropped() {
        let close = UINode(ref: "1:2", depth: 0, role: "AXButton", subrole: "AXCloseButton", title: nil, value: nil,
                           description: nil, frame: nil, enabled: true, focused: false)
        XCTAssertEqual(close.line, "[1:2] AXButton:AXCloseButton press")
        let back = UINode(ref: "1:3", depth: 0, role: "AXButton", title: "Back", value: nil, description: "Back",
                          frame: nil, enabled: true, focused: false)
        XCTAssertEqual(back.line, "[1:3] AXButton \"Back\" press")
    }

    func testBareContainersAreSkippedButLabelledOnesAreNot() {
        XCTAssertFalse(UINode.isWorthEmitting(role: "AXGroup", title: nil, value: nil, description: nil))
        XCTAssertTrue(UINode.isWorthEmitting(role: "AXGroup", title: nil, value: nil, description: "Sidebar"))
        XCTAssertTrue(UINode.isWorthEmitting(role: "AXTextField", title: nil, value: nil, description: nil))
    }

    func testCleanKeepsANodeOnOneLine() {
        XCTAssertEqual(UINode.clean("  two\nlines \"quoted\"  "), "two lines 'quoted'")
        XCTAssertNil(UINode.clean(" \n "))
        XCTAssertEqual(UINode.clean(String(repeating: "a", count: 200))?.count, 121)
    }

    func testUnknownRefIsAnErrorNotACrash() {
        XCTAssertThrowsError(try UIAutomation.shared.element(for: "999:1"))
        XCTAssertThrowsError(try UIAutomation.shared.element(for: "garbage"))
    }

    func testFocusIsHeldOnlyWhenTheOSConfirmsIt() {
        XCTAssertEqual(UIAutomation.verdict(frontmostPid: 10, targetPid: 10, focusedIsTarget: true), .held)
        XCTAssertNotEqual(UIAutomation.verdict(frontmostPid: 10, targetPid: 10, focusedIsTarget: false), .held)
        XCTAssertNotEqual(UIAutomation.verdict(frontmostPid: 11, targetPid: 10, focusedIsTarget: true), .held)
        // A hung app that will not report its focused window is never "held".
        XCTAssertNotEqual(UIAutomation.verdict(frontmostPid: 10, targetPid: 10, focusedIsTarget: nil), .held)
        XCTAssertNotEqual(UIAutomation.verdict(frontmostPid: nil, targetPid: 10, focusedIsTarget: nil), .held)
    }

    func testHostileNumbersAreRejectedNotTrapped() {
        XCTAssertNil(MessageHandler.int(["count": AnyCodable(1e30)], "count"))
        XCTAssertNil(MessageHandler.int(["count": AnyCodable("nan")], "count"))
        XCTAssertEqual(MessageHandler.int(["count": AnyCodable(2.9)], "count"), 2)
        XCTAssertNil(MessageHandler.windowID(["windowId": AnyCodable(-1)]))
        let huge = UINode(ref: "1:1", depth: 0, role: "AXImage", title: nil, value: nil, description: nil,
                          frame: CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10), enabled: true, focused: false)
        XCTAssertEqual(huge.line, "[1:1] AXImage")
        XCTAssertFalse(InputError.offScreen(CGPoint(x: 1e300, y: 0)).description.isEmpty)
    }

    func testQueryMatchesRoleTextAndBorrowedLabel() {
        let save = UINode(ref: "1:1", depth: 3, role: "AXButton", title: "Save As…", value: nil, description: nil, frame: nil, enabled: true, focused: false, pressable: true)
        var zoom = UINode(ref: "1:2", depth: 3, role: "AXCheckBox", subrole: "AXSwitch", title: nil, value: "1", description: nil, frame: nil, enabled: true, focused: false, pressable: true)
        zoom.label = "Use scroll gesture with modifier keys to zoom"
        let text = UINode(ref: "1:3", depth: 1, role: "AXStaticText", title: nil, value: "Saved", description: nil, frame: nil, enabled: true, focused: false)

        XCTAssertTrue(UIQuery(role: "button", text: "save").matches(save))
        XCTAssertTrue(UIQuery(role: "AXButton").matches(save))
        XCTAssertFalse(UIQuery(role: "button").matches(text))
        // A switch is found by its subrole and by the label it borrowed from the text beside it.
        XCTAssertTrue(UIQuery(role: "switch", text: "scroll gesture").matches(zoom))
        XCTAssertTrue(UIQuery(text: "SAVE", pressable: false).matches(text))
        XCTAssertFalse(UIQuery(text: "save", pressable: false).matches(save))
    }
}
