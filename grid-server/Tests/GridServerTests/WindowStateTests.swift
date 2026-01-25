import XCTest
@testable import GridServer

final class WindowStateTests: XCTestCase {

    // MARK: - zOrder Default Value Tests

    func testZOrderDefaultValue() {
        let window = WindowState(id: 123)
        XCTAssertEqual(window.zOrder, Int32.max, "zOrder should default to Int32.max")
    }

    func testZOrderCanBeSet() {
        var window = WindowState(id: 123)
        window.zOrder = 0
        XCTAssertEqual(window.zOrder, 0, "zOrder should be settable to 0 (frontmost)")
    }

    func testZOrderCanBeSetToAnyValue() {
        var window = WindowState(id: 123)
        window.zOrder = 42
        XCTAssertEqual(window.zOrder, 42)
    }

    // MARK: - zOrder Codable Tests

    func testZOrderEncodeDecode() throws {
        var original = WindowState(id: 456)
        original.zOrder = 7

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WindowState.self, from: data)

        XCTAssertEqual(decoded.zOrder, 7, "zOrder should survive encode/decode round-trip")
    }

    func testZOrderEncodeDecodeZero() throws {
        var original = WindowState(id: 789)
        original.zOrder = 0

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WindowState.self, from: data)

        XCTAssertEqual(decoded.zOrder, 0, "zOrder 0 should survive encode/decode")
    }

    func testZOrderEncodeDecodeMax() throws {
        var original = WindowState(id: 111)
        original.zOrder = Int32.max

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WindowState.self, from: data)

        XCTAssertEqual(decoded.zOrder, Int32.max, "zOrder Int32.max should survive encode/decode")
    }

    func testZOrderInJSON() throws {
        var window = WindowState(id: 123)
        window.zOrder = 5

        let encoder = JSONEncoder()
        let data = try encoder.encode(window)

        // Verify zOrder appears in JSON
        let jsonString = String(data: data, encoding: .utf8)!
        XCTAssertTrue(jsonString.contains("\"zOrder\":5") || jsonString.contains("\"zOrder\": 5"),
                      "JSON should contain zOrder field")
    }

    // MARK: - zOrder Sorting Behavior Tests

    func testZOrderSortingSemantics() {
        var frontmost = WindowState(id: 1)
        frontmost.zOrder = 0

        var middle = WindowState(id: 2)
        middle.zOrder = 1

        var back = WindowState(id: 3)
        back.zOrder = 2

        var offScreen = WindowState(id: 4)
        offScreen.zOrder = Int32.max

        // Verify frontmost has lowest z-order
        XCTAssertLessThan(frontmost.zOrder, middle.zOrder)
        XCTAssertLessThan(middle.zOrder, back.zOrder)
        XCTAssertLessThan(back.zOrder, offScreen.zOrder)
    }

    func testZOrderArraySorting() {
        var windows = [
            WindowState(id: 1),
            WindowState(id: 2),
            WindowState(id: 3),
        ]
        windows[0].zOrder = 2  // Back
        windows[1].zOrder = 0  // Frontmost
        windows[2].zOrder = 1  // Middle

        // Sort by zOrder ascending (frontmost first)
        windows.sort { $0.zOrder < $1.zOrder }

        XCTAssertEqual(windows[0].id, 2, "Frontmost window (zOrder 0) should be first")
        XCTAssertEqual(windows[1].id, 3, "Middle window (zOrder 1) should be second")
        XCTAssertEqual(windows[2].id, 1, "Back window (zOrder 2) should be last")
    }
}
