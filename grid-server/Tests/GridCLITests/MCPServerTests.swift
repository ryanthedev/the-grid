import XCTest
@testable import GridCLI

final class MCPServerTests: XCTestCase {
    // Records every RPC the server forwards and answers with a canned result.
    private func makeServer(_ calls: NSMutableArray, result: [String: Any] = ["ok": true]) -> MCPServer {
        MCPServer(version: "test") { method, params in
            calls.add([method, params] as [Any])
            return result
        }
    }

    func testInitializeFramesAProtocolResponse() {
        let server = makeServer([])
        let frame = server.handle(frame: ["jsonrpc": "2.0", "id": 7, "method": "initialize", "params": [:]])!
        XCTAssertEqual(frame["id"] as? Int, 7)
        let result = frame["result"] as! [String: Any]
        XCTAssertEqual(result["protocolVersion"] as? String, MCPServer.protocolVersion)
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
    }

    func testNotificationsGetNoReply() {
        let server = makeServer([])
        XCTAssertNil(server.handle(frame: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
    }

    func testToolsListMatchesTheTable() {
        let server = makeServer([])
        let frame = server.handle(frame: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])!
        let tools = (frame["result"] as! [String: Any])["tools"] as! [[String: Any]]
        XCTAssertEqual(tools.count, mcpTools.count)
        XCTAssertEqual(Set(tools.map { $0["name"] as! String }), Set(mcpTools.map { $0.name }))
        // Required-only props land in `required`; optional ones do not.
        let focus = tools.first { $0["name"] as? String == "grid.focus" }!
        let schema = focus["inputSchema"] as! [String: Any]
        XCTAssertEqual(schema["required"] as? [String], ["direction"])
    }

    func testResizeToolsForwardASignedDelta() {
        let calls = NSMutableArray()
        let server = makeServer(calls)
        _ = server.callTool(name: "grid.resize.grow", args: [:])
        _ = server.callTool(name: "grid.resize.shrink", args: ["amount": 0.25])
        XCTAssertEqual(calls.count, 2)
        let grow = calls[0] as! [Any]
        let shrink = calls[1] as! [Any]
        XCTAssertEqual(grow[0] as? String, "grid.resize.adjust")
        XCTAssertEqual((grow[1] as! [String: Any])["delta"] as? Double, 0.1)
        XCTAssertEqual((shrink[1] as! [String: Any])["delta"] as? Double, -0.25)
    }

    func testUnknownToolAndRpcFailureAreToolErrors() {
        let calls = NSMutableArray()
        let server = makeServer(calls)
        XCTAssertTrue(server.callTool(name: "nope", args: [:]).isError)
        XCTAssertEqual(calls.count, 0)

        let failing = MCPServer(version: "test") { _, _ in throw RPCError.timeout }
        let result = failing.callTool(name: "ping", args: [:])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.content.first?["text"] as? String, "Error: Request timed out")
    }
}
