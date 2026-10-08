import XCTest
import CoreGraphics
@testable import GridServer

final class KeyComboTests: XCTestCase {

    func test_plus_and_dash_separators_parse_the_same() throws {
        let a = try parseKeyCombo("cmd+shift+s")
        let b = try parseKeyCombo("cmd+shift-s")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.keyCode, BFDKeycodes["s"])
        XCTAssertTrue(a.flags.contains(.maskCommand))
        XCTAssertTrue(a.flags.contains(.maskShift))
        XCTAssertFalse(a.flags.contains(.maskControl))
    }

    func test_bare_key_and_trailing_separator_key() throws {
        XCTAssertEqual(try parseKeyCombo("enter").keyCode, BFDKeycodes["return"])
        XCTAssertEqual(try parseKeyCombo("Escape").flags, [])
        // "cmd+-" is cmd and the minus key, not a malformed spec.
        let minus = try parseKeyCombo("cmd+-")
        XCTAssertEqual(minus.keyCode, BFDKeycodes["-"])
        XCTAssertTrue(minus.flags.contains(.maskCommand))
    }

    func test_unknown_key_or_modifier_is_rejected() {
        XCTAssertThrowsError(try parseKeyCombo("cmd+bogus"))
        XCTAssertThrowsError(try parseKeyCombo("windows+s"))
        XCTAssertThrowsError(try parseKeyCombo(""))
        XCTAssertEqual(try parseModifierFlags(nil), [])
        XCTAssertEqual(try parseModifierFlags("ctrl+alt"), [.maskControl, .maskAlternate])
    }
}
