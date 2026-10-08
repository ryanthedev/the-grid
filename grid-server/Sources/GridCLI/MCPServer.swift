import CoreGraphics
import Foundation

// MCP stdio server: newline-delimited JSON-RPC 2.0 on stdin/stdout. Nothing
// but protocol frames may be written to stdout -- a stray print hangs the
// client. Diagnostics go to stderr.

typealias RPCCall = (_ method: String, _ params: [String: Any]) throws -> [String: Any]

struct MCPToolResult {
    let content: [[String: Any]]
    let isError: Bool

    static func text(_ s: String) -> MCPToolResult {
        MCPToolResult(content: [["type": "text", "text": s]], isError: false)
    }

    static func error(_ s: String) -> MCPToolResult {
        MCPToolResult(content: [["type": "text", "text": s]], isError: true)
    }

    static func image(_ data: Data, mimeType: String) -> MCPToolResult {
        MCPToolResult(content: [["type": "image", "data": data.base64EncodedString(), "mimeType": mimeType]], isError: false)
    }

    static func json(_ obj: [String: Any]) -> MCPToolResult {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else {
            return .error("Error: result was not serializable")
        }
        return .text(s)
    }

    var payload: [String: Any] {
        var out: [String: Any] = ["content": content]
        if isError {
            out["isError"] = true
        }
        return out
    }
}

final class MCPServer {
    static let protocolVersion = "2024-11-05"

    let rpc: RPCCall
    let version: String

    init(version: String, rpc: @escaping RPCCall) {
        self.version = version
        self.rpc = rpc
    }

    // MARK: Tool dispatch

    func callTool(name: String, args: [String: Any]) -> MCPToolResult {
        guard let tool = mcpToolsByName[name] else {
            return .error("Error: unknown tool '\(name)'")
        }
        switch tool.handler {
        case .rpc(let method):
            return forward(method, args)
        case .resize(let sign):
            let amount = (args["amount"] as? NSNumber)?.doubleValue ?? 0.1
            return forward("grid.resize.adjust", ["delta": sign * amount])
        case .screenshot:
            return screenshot(args)
        }
    }

    private func forward(_ method: String, _ params: [String: Any]) -> MCPToolResult {
        do {
            return .json(try rpc(method, params))
        } catch {
            return .error("Error: \(error)")
        }
    }

    // MARK: Screenshot

    // Alongside the image, return the captured region in screen points and
    // the returned image's pixel size so the model can map a pixel it sees
    // to a point it can click: x = frame.x + px * frame.width / image.width.
    private func screenshot(_ args: [String: Any]) -> MCPToolResult {
        let target = args["target"] as? String ?? "full"
        let id = args["id"] as? String
        let cursor = args["cursor"] as? Bool ?? false
        let display = (args["display"] as? NSNumber)?.intValue
        let high = (args["quality"] as? String) == "high"

        let tmp = FileManager.default.temporaryDirectory
        let uuid = UUID().uuidString
        let pngPath = tmp.appendingPathComponent("grid-screenshot-\(uuid).png").path
        let jpegPath = tmp.appendingPathComponent("grid-screenshot-\(uuid).jpg").path
        defer {
            try? FileManager.default.removeItem(atPath: pngPath)
            try? FileManager.default.removeItem(atPath: jpegPath)
        }

        // -x: no capture sound
        var captureArgs = ["-x"]
        var geometry: [String: Any] = ["target": target]
        var frame: CGRect?
        switch target {
        case "full":
            if cursor { captureArgs.append("-C") }
            let displays = displayFrames()
            if let display {
                guard display >= 0, display < displays.count else {
                    return .error("display index \(display) out of range (\(displays.count) displays)")
                }
                frame = displays[display].frame
                geometry["display"] = display
            } else if let mainIndex = displays.firstIndex(where: { $0.isMain }) ?? (displays.isEmpty ? nil : 0) {
                frame = displays[mainIndex].frame
                geometry["display"] = mainIndex
            }
            // Capture by rect so the region is exactly the frame we report.
            if let f = frame {
                captureArgs += ["-R", "\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))"]
            }
        case "window", "cell":
            let wid: Int
            if target == "window" {
                guard let id, let parsed = Int(id) else {
                    return .error("window target requires numeric 'id' (window ID)")
                }
                wid = parsed
            } else {
                guard let id else {
                    return .error("cell target requires 'id' (cell ID)")
                }
                guard let found = windowIdForCell(id) else {
                    return .error("could not find focused window in cell '\(id)'")
                }
                wid = found
                geometry["cell"] = id
            }
            geometry["windowId"] = wid
            frame = windowFrame(wid)
            // -o: no window shadow, so the image edge is the window edge.
            captureArgs += ["-l", String(wid), "-o"]
        default:
            return .error("unknown target; use 'full', 'window', or 'cell'")
        }
        captureArgs.append(pngPath)

        let captureStatus = run("/usr/sbin/screencapture", captureArgs)
        guard captureStatus == 0 else {
            return .error("screencapture failed with exit code \(captureStatus)")
        }
        guard let png = FileManager.default.contents(atPath: pngPath), !png.isEmpty else {
            return .error("screenshot file not found at \(pngPath)")
        }

        var imageData = png
        var mimeType = "image/png"
        var imagePath = pngPath
        if !high {
            let sipsStatus = run("/usr/bin/sips", [
                "--resampleHeightWidthMax", "1024",
                "--setProperty", "format", "jpeg",
                "--setProperty", "formatOptions", "60",
                pngPath, "--out", jpegPath,
            ])
            guard sipsStatus == 0 else {
                return .error("sips compress failed with exit code \(sipsStatus)")
            }
            guard let jpeg = FileManager.default.contents(atPath: jpegPath), !jpeg.isEmpty else {
                return .error("compressed screenshot not found at \(jpegPath)")
            }
            imageData = jpeg
            mimeType = "image/jpeg"
            imagePath = jpegPath
        }

        if let f = frame {
            geometry["frame"] = ["x": f.minX, "y": f.minY, "width": f.width, "height": f.height]
        }
        if let size = imagePixelSize(imagePath) {
            geometry["image"] = ["width": size.width, "height": size.height]
        }
        var result = MCPToolResult.image(imageData, mimeType: mimeType)
        if let data = try? JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            result = MCPToolResult(content: result.content + [["type": "text", "text": text]], isError: false)
        }
        return result
    }

    private struct DisplayEntry {
        let frame: CGRect
        let isMain: Bool
    }

    private func displayFrames() -> [DisplayEntry] {
        guard let result = try? rpc("display.list", [:]),
              let displays = result["displays"] as? [[String: Any]] else {
            return []
        }
        return displays.compactMap { d in
            guard let f = d["frame"] as? [String: Any], let rect = rect(fromDict: f) else { return nil }
            return DisplayEntry(frame: rect, isMain: d["isMain"] as? Bool ?? false)
        }
    }

    // dump encodes CGRect as [[x, y], [w, h]].
    private func windowFrame(_ wid: Int) -> CGRect? {
        guard let result = try? rpc("dump", [:]),
              let windows = result["windows"] as? [String: Any],
              let window = windows[String(wid)] as? [String: Any],
              let f = window["frame"] as? [[NSNumber]], f.count == 2, f[0].count == 2, f[1].count == 2 else {
            return nil
        }
        return CGRect(x: f[0][0].doubleValue, y: f[0][1].doubleValue, width: f[1][0].doubleValue, height: f[1][1].doubleValue)
    }

    private func rect(fromDict d: [String: Any]) -> CGRect? {
        guard let x = (d["x"] as? NSNumber)?.doubleValue, let y = (d["y"] as? NSNumber)?.doubleValue,
              let w = (d["width"] as? NSNumber)?.doubleValue, let h = (d["height"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func imagePixelSize(_ path: String) -> (width: Int, height: Int)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        p.arguments = ["-g", "pixelWidth", "-g", "pixelHeight", path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        var w: Int?, h: Int?
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let v = Int(parts[1]) else { continue }
            if parts[0] == "pixelWidth" { w = v }
            if parts[0] == "pixelHeight" { h = v }
        }
        guard let w, let h else { return nil }
        return (w, h)
    }

    private func windowIdForCell(_ cellId: String) -> Int? {
        guard let result = try? rpc("grid.state.show", [:]),
              let state = result["state"] as? [String: Any],
              let spaces = state["spaces"] as? [String: Any] else {
            return nil
        }
        for space in spaces.values {
            guard let cells = (space as? [String: Any])?["cells"] as? [String: Any],
                  let cell = cells[cellId] as? [String: Any],
                  let wid = (cell["lastFocusedWid"] as? NSNumber)?.intValue, wid > 0 else {
                continue
            }
            return wid
        }
        return nil
    }

    private func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return -1
        }
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: JSON-RPC

    // Returns the response frame, or nil for notifications and anything else
    // that must not be answered.
    func handle(frame: [String: Any]) -> [String: Any]? {
        let id = frame["id"]
        guard let method = frame["method"] as? String else {
            guard let id else { return nil }
            return errorFrame(id: id, code: -32600, message: "Invalid Request")
        }
        let params = frame["params"] as? [String: Any] ?? [:]

        // Notifications carry no id and get no reply.
        guard let id else { return nil }

        switch method {
        case "initialize":
            return resultFrame(id: id, [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "thegrid", "version": version],
            ])
        case "ping":
            return resultFrame(id: id, [:])
        case "tools/list":
            return resultFrame(id: id, ["tools": mcpTools.map { $0.definition }])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return errorFrame(id: id, code: -32602, message: "Invalid params: missing tool name")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            return resultFrame(id: id, callTool(name: name, args: args).payload)
        default:
            return errorFrame(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func resultFrame(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorFrame(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    // MARK: stdio loop

    func serve() {
        let stdout = FileHandle.standardOutput
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            var response: [String: Any]?
            if let data = trimmed.data(using: .utf8),
               let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                response = handle(frame: frame)
            } else {
                response = errorFrame(id: NSNull(), code: -32700, message: "Parse error")
            }

            guard let response,
                  var out = try? JSONSerialization.data(withJSONObject: response) else {
                continue
            }
            out.append(0x0A)
            stdout.write(out)
        }
    }
}
