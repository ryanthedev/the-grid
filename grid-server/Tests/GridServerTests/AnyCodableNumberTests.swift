import XCTest
@testable import GridServer

/// Numbers that happen to be 0 or 1 must stay numbers on the wire; only real
/// booleans encode as true/false.
final class AnyCodableNumberTests: XCTestCase {
    private struct Sample: Codable {
        let version: Int
        let index: Int
        let ratios: [Double]
        let flag: Bool
    }

    private func json(_ value: Any) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: try encoder.encode(AnyCodable(value)), encoding: .utf8)!
    }

    func testCodableStructKeepsZeroAndOneNumeric() throws {
        let out = try json(Sample(version: 1, index: 0, ratios: [1.0, 0.5], flag: true))
        XCTAssertEqual(out, #"{"flag":true,"index":0,"ratios":[1,0.5],"version":1}"#)
    }

    func testDictionaryOfSwiftValues() throws {
        let out = try json(["a": 1, "b": 0, "c": true, "d": false, "e": 1.0] as [String: Any])
        XCTAssertEqual(out, #"{"a":1,"b":0,"c":true,"d":false,"e":1}"#)
    }

    func testNSNumberFromJSONSerialization() throws {
        let parsed = try JSONSerialization.jsonObject(with: Data(#"{"n":1,"z":0,"t":true,"f":1.5}"#.utf8))
        XCTAssertEqual(try json(parsed), #"{"f":1.5,"n":1,"t":true,"z":0}"#)
    }

    func testDecodeKeepsNumbersNumeric() throws {
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: Data(#"{"n":1,"z":0,"t":true}"#.utf8))
        let dict = decoded.value as! [String: Any]
        XCTAssertEqual(try json(dict), #"{"n":1,"t":true,"z":0}"#)
    }
}
