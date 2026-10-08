import CoreGraphics
import ImageIO
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

    func testResizeCellSendsTheDeltaTheServerRequires() {
        let calls = NSMutableArray()
        let server = makeServer(calls)
        _ = server.callTool(name: "grid.resize.cell", args: ["direction": "right", "amount": 0.2])
        _ = server.callTool(name: "grid.resize.cell", args: ["direction": "left"])
        XCTAssertEqual(((calls[0] as! [Any])[1] as! [String: Any])["delta"] as? Double, 0.2)
        XCTAssertEqual(((calls[1] as! [Any])[1] as! [String: Any])["delta"] as? Double, 0.05)
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

    private func png(width: Int, height: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func testLowQualityCapsTheLongEdgeAndNeverUpscales() {
        let wide = MCPServer.downscaledJPEG(png(width: 3840, height: 1080), maxEdge: MCPServer.lowQualityMaxEdge)!
        let wideSize = MCPServer.pixelSize(wide)!
        XCTAssertEqual(wideSize.width, 1568)
        XCTAssertEqual(wideSize.height, 441)

        let small = MCPServer.downscaledJPEG(png(width: 400, height: 300), maxEdge: MCPServer.lowQualityMaxEdge)!
        let smallSize = MCPServer.pixelSize(small)!
        XCTAssertEqual(smallSize.width, 400)
        XCTAssertEqual(smallSize.height, 300)
    }

    func testRegionClipsToTheDisplayItOverlapsMost() {
        let lower = CGRect(x: 0, y: 0, width: 3840, height: 1080)
        let upper = CGRect(x: 0, y: -1080, width: 3840, height: 1080)
        // Straddles both displays, mostly on the upper one.
        let clipped = MCPServer.clipRegion(CGRect(x: 100, y: -500, width: 800, height: 600), to: [lower, upper])
        XCTAssertEqual(clipped, CGRect(x: 100, y: -500, width: 800, height: 500))
        XCTAssertNil(MCPServer.clipRegion(CGRect(x: 5000, y: 0, width: 100, height: 100), to: [lower, upper]))
    }

    func testEveryAdvertisedScreenshotTargetReachesAHandler() {
        let server = makeServer([])
        let tool = mcpToolsByName["grid.screenshot"]!
        let targets = tool.props.first { $0.name == "target" }!.enumValues!
        // No ids or coordinates: each target must fail on its own validation, not as unknown.
        for target in targets where target != "full" {
            let text = server.callTool(name: "grid.screenshot", args: ["target": target]).content.first?["text"] as? String ?? ""
            XCTAssertFalse(text.hasPrefix("unknown target"), "\(target): \(text)")
        }
    }

    func testSnapshotOutlineIsSentAsPlainText() {
        let server = makeServer([], result: ["windowId": 7, "count": 2, "outline": "[7:1] AXWindow\n  [7:2] AXButton \"OK\" press"])
        let result = server.callTool(name: "ui.snapshot", args: ["windowId": "7"])
        XCTAssertEqual(result.content.count, 2)
        XCTAssertFalse((result.content[0]["text"] as! String).contains("outline"))
        XCTAssertEqual(result.content[1]["text"] as? String, "[7:1] AXWindow\n  [7:2] AXButton \"OK\" press")
    }

    func testObserveAppendsASnapshotOfTheRefsWindow() {
        let calls = NSMutableArray()
        let server = MCPServer(version: "test") { method, params in
            calls.add([method, params] as [Any])
            return method == "ui.snapshot" ? ["windowId": 7, "count": 1, "outline": "[7:1] AXWindow"] : ["pressed": "7:3"]
        }
        let result = server.callTool(name: "ui.press", args: ["ref": "7:3", "observe": "snapshot", "settleMs": 0])
        XCTAssertEqual((calls.lastObject as! [Any])[0] as? String, "ui.snapshot")
        XCTAssertEqual(((calls.lastObject as! [Any])[1] as! [String: Any])["windowId"] as? String, "7")
        XCTAssertEqual(result.content.last?["text"] as? String, "[7:1] AXWindow")
    }

    func testBatchRunsInOrderAndStopsAtTheFirstFailure() {
        let calls = NSMutableArray()
        let server = MCPServer(version: "test") { method, _ in
            calls.add(method)
            if method == "ui.setValue" { throw RPCError.timeout }
            return ["ok": true]
        }
        let steps = #"[{"tool":"ui.press","args":{"ref":"7:3"}},{"tool":"ui.setValue","args":{"ref":"7:4","value":"x"}},{"tool":"ui.press","args":{"ref":"7:5"}}]"#
        let result = server.callTool(name: "batch", args: ["steps": steps])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(calls as! [String], ["ui.press", "ui.setValue"])
        XCTAssertTrue(server.callTool(name: "batch", args: ["steps": #"[{"tool":"batch"}]"#]).isError)
        XCTAssertTrue(server.callTool(name: "batch", args: ["steps": "not json"]).isError)
    }

    func testStabilityToleratesACaretButNotARepaint() {
        var a = [UInt8](repeating: 20, count: 64 * 64)
        var caret = a
        caret[100] = 255
        XCTAssertLessThan(MCPServer.meanDifference(a, caret), 1.0)
        a = [UInt8](repeating: 200, count: 64 * 64)
        XCTAssertGreaterThan(MCPServer.meanDifference(a, caret), 1.0)
    }

    func testImagePixelsNeedAScreenshotAndAreRefusedWithoutOne() {
        let calls = NSMutableArray()
        let server = makeServer(calls)
        let result = server.callTool(name: "input.mouse.click", args: ["px": 10, "py": 10])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(calls.count, 0)
        // Plain screen points still pass straight through.
        _ = server.callTool(name: "input.mouse.click", args: ["x": 5, "y": 6])
        XCTAssertEqual(((calls[0] as! [Any])[1] as! [String: Any])["x"] as? Int, 5)
    }

    func testExpectationPollsUntilTheEffectShowsAndFailsWhenItNeverDoes() {
        var queries = 0
        let server = MCPServer(version: "test") { method, params in
            guard method == "ui.query" else { return ["pressed": "7:3"] }
            queries += 1
            // The text shows up on the third look; "never" never does.
            let hit = (params["text"] as? String) == "134" && queries >= 3
            return ["windowId": 7, "count": hit ? 1 : 0, "outline": ""]
        }
        let met = server.callTool(name: "ui.press", args: ["ref": "7:3", "expectText": "134", "timeoutMs": 2000])
        XCTAssertFalse(met.isError)
        XCTAssertTrue((met.content.last?["text"] as? String ?? "").contains("met"))

        let unmet = server.callTool(name: "ui.press", args: ["ref": "7:3", "expectText": "never", "timeoutMs": 300])
        XCTAssertTrue(unmet.isError)
        XCTAssertTrue((unmet.content.last?["text"] as? String ?? "").contains("Expectation not met"))
    }

    func testKnownFailuresComeWithTheNextMove() {
        struct Refused: Error, CustomStringConvertible { let description = "AXPress failed (AXError -25205)" }
        let server = MCPServer(version: "test") { _, _ in throw Refused() }
        let result = server.callTool(name: "ui.press", args: ["ref": "7:3"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue((result.content.last?["text"] as? String ?? "").hasPrefix("Next: Try ui.click"))
        XCTAssertNotNil(MCPServer.outlineHint("[1:8] AXTextField \"Address and search bar\"", count: 30, isQuery: false))
        XCTAssertNil(MCPServer.outlineHint("[1:1] AXWindow \"Calculator\"", count: 32, isQuery: false))
    }

    func testMenuToolsPrintAnOutlineAndTakeExpectations() {
        let calls = NSMutableArray()
        let server = makeServer(calls, result: ["app": "TextEdit", "count": 1, "outline": "Edit > Select All  [cmd+A]  enabled"])
        let listed = server.callTool(name: "menu.snapshot", args: ["app": "TextEdit", "text": "select all"])
        XCTAssertFalse(listed.isError)
        XCTAssertEqual(listed.content.last?["text"] as? String, "Edit > Select All  [cmd+A]  enabled")
        // One matching command is an answer, not a thin accessibility tree.
        XCTAssertFalse((listed.content.first?["text"] as? String ?? "").contains("hint"))
        XCTAssertEqual((calls[0] as! [Any])[0] as? String, "menu.snapshot")

        let invoke = mcpToolsByName["menu.invoke"]!
        XCTAssertTrue(invoke.observable)
        XCTAssertTrue(invoke.props.contains { $0.name == "expectText" })
        XCTAssertEqual(invoke.props.filter { $0.required }.map(\.name), ["path"])
    }

    func testAHiddenSpaceFailurePointsAtTheSpaceTools() {
        struct Unreachable: Error, CustomStringConvertible { let description = "window 7 is not reachable through accessibility" }
        let server = MCPServer(version: "test") { _, _ in throw Unreachable() }
        let next = server.callTool(name: "ui.snapshot", args: ["windowId": "7"]).content.last?["text"] as? String ?? ""
        XCTAssertTrue(next.hasPrefix("Next:") && next.contains("space.list") && next.contains("window.pull") && next.contains("space.switch"))
        // A refusal must not read as an invitation to pass the override.
        struct Refused: Error, CustomStringConvertible { let description = "space.switch refused: that display is showing a fullscreen space" }
        let refusing = MCPServer(version: "test") { _, _ in throw Refused() }
        let advice = refusing.callTool(name: "space.switch", args: ["spaceId": "4"]).content.last?["text"] as? String ?? ""
        XCTAssertTrue(advice.contains("ask before passing leaveFullscreen"))
        XCTAssertTrue(mcpToolsByName["window.pull"]!.observable)
        XCTAssertFalse(mcpToolsByName["space.switch"]!.observable)
    }
}
