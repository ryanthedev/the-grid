import XCTest
@testable import GridServer

final class GridServerTests: XCTestCase {
    func testMessageEncoding() throws {
        // Test request encoding
        let request = Request(id: "test-123", method: "ping", params: nil)
        let message = Message(request: request)

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message.self, from: data)

        XCTAssertEqual(decoded.type, .request)
        XCTAssertEqual(decoded.request?.id, "test-123")
        XCTAssertEqual(decoded.request?.method, "ping")
    }

    func testResponseEncoding() throws {
        // Test response encoding
        let response = Response(id: "test-456", result: AnyCodable(["pong": true]))
        let message = Message(response: response)

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message.self, from: data)

        XCTAssertEqual(decoded.type, .response)
        XCTAssertEqual(decoded.response?.id, "test-456")
        XCTAssertNil(decoded.response?.error)
    }

    func testEventEncoding() throws {
        // Test event encoding
        let event = Event(eventType: "heartbeat", data: AnyCodable(["timestamp": 12345.67]))
        let message = Message(event: event)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(message)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Message.self, from: data)

        XCTAssertEqual(decoded.type, .event)
        XCTAssertEqual(decoded.event?.eventType, "heartbeat")
    }
}
