import CoreGraphics
import Foundation
import ImageIO

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

    // Geometry of the screenshots this session has taken, so a click can be given in the
    // pixels of the image the caller is looking at instead of hand-converted screen points.
    private var shots: [Int: (frame: CGRect, image: CGSize, windowId: Int?)] = [:]
    private var lastShot = 0

    init(version: String, rpc: @escaping RPCCall) {
        self.version = version
        self.rpc = rpc
    }

    // MARK: Tool dispatch

    func callTool(name: String, args: [String: Any]) -> MCPToolResult {
        guard let tool = mcpToolsByName[name] else {
            return .error("Error: unknown tool '\(name)'")
        }
        var args = args
        if tool.pixelAddressable {
            switch resolvePixels(&args) {
            case .failure(let refusal): return .error(refusal.message)
            case .success: break
            }
        }
        var result = dispatch(tool, args)
        if result.isError { return Self.advised(result) }
        // A return code says the call was delivered, not that it worked (Finder answers AXPress
        // with an error and expands the folder anyway). `expect*` makes the effect the verdict.
        if tool.observable, let expectation = Expectation(args) {
            let verdict = await_(expectation, args)
            result = MCPToolResult(content: result.content + verdict.content, isError: verdict.isError)
            if verdict.isError { return result }
        }
        // Acting and looking in one round trip: the observation rides on the action's result.
        guard tool.observable, let mode = args["observe"] as? String else { return result }
        let observed = observe(mode, args)
        return MCPToolResult(content: result.content + observed.content, isError: false)
    }

    private func dispatch(_ tool: MCPTool, _ args: [String: Any]) -> MCPToolResult {
        switch tool.handler {
        case .rpc(let method):
            return forward(method, args)
        case .resize(let sign):
            let amount = (args["amount"] as? NSNumber)?.doubleValue ?? 0.1
            return forward("grid.resize.adjust", ["delta": sign * amount])
        case .resizeCell:
            let amount = (args["amount"] as? NSNumber)?.doubleValue ?? 0.05
            return forward("grid.resize.cell", ["direction": args["direction"] ?? "", "delta": amount])
        case .screenshot:
            return screenshot(args)
        case .outline(let method):
            return outline(method, args)
        case .batch:
            return batch(args)
        case .wait:
            guard let expectation = Expectation(args) else {
                return .error("give at least one of expectText, expectGone, expectTitle")
            }
            return await_(expectation, args)
        }
    }

    /// Some apps barely describe themselves. Say so, so the caller switches to pixels instead of
    /// concluding the window is empty.
    static func outlineHint(_ outline: String, count: Int, isQuery: Bool) -> String? {
        if outline.contains("\"Address and search bar\""), !outline.contains("AXWebArea") {
            return "Chrome exposes its toolbar and tabs, not the page. For page content: grid.screenshot(target=window), then click by px/py with windowId; wait with waitTitle."
        }
        if !isQuery, count <= 3 {
            return "Almost nothing here: terminals and canvas-drawn apps do not describe themselves. Use grid.screenshot to read and input.* with windowId to act. Electron apps build their tree on first request: snapshot once more."
        }
        return nil
    }

    // MARK: Expectations

    struct Expectation {
        var text: String?
        var gone: String?
        var title: String?
        var timeout: TimeInterval

        init?(_ args: [String: Any]) {
            text = args["expectText"] as? String
            gone = args["expectGone"] as? String
            title = args["expectTitle"] as? String
            guard text != nil || gone != nil || title != nil else { return nil }
            timeout = Double(min(max((args["timeoutMs"] as? NSNumber)?.intValue ?? 3000, 0), 30_000)) / 1000
        }
    }

    /// The window an action was aimed at: `windowId`, else the window a `ref` names, else the focused one.
    private func targetWindow(_ args: [String: Any]) -> String? {
        if let wid = args["windowId"] as? String ?? (args["windowId"] as? NSNumber)?.stringValue { return wid }
        if let ref = args["ref"] as? String, let wid = ref.split(separator: ":").first { return String(wid) }
        return ((try? rpc("metadata.get", [:]))?["focusedWindowID"] as? NSNumber)?.stringValue
    }

    /// Poll until every stated expectation holds, or say which one did not.
    private func await_(_ expectation: Expectation, _ args: [String: Any]) -> MCPToolResult {
        guard let wid = targetWindow(args) else { return .error("expect: no window to check; pass windowId") }
        let started = Date()
        var unmet = ""
        repeat {
            unmet = ""
            if let text = expectation.text, matches(wid, text) == 0 { unmet = "expectText \"\(text)\" is not in window \(wid)" }
            if unmet.isEmpty, let gone = expectation.gone, matches(wid, gone) != 0 { unmet = "expectGone \"\(gone)\" is still in window \(wid)" }
            if unmet.isEmpty, let title = expectation.title, !windowTitle(wid).localizedCaseInsensitiveContains(title) {
                unmet = "expectTitle \"\(title)\" does not match the title \"\(windowTitle(wid))\""
            }
            if unmet.isEmpty {
                return .json(["expect": "met", "afterMs": Int(Date().timeIntervalSince(started) * 1000)])
            }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date().timeIntervalSince(started) < expectation.timeout
        return .error("Expectation not met after \(Int(expectation.timeout * 1000)) ms: \(unmet). The action was delivered; its effect was not seen. Look (ui.snapshot or grid.screenshot) before retrying, so a slow success is not repeated.")
    }

    private func matches(_ wid: String, _ text: String) -> Int {
        ((try? rpc("ui.query", ["windowId": wid, "text": text, "limit": 1]))?["count"] as? NSNumber)?.intValue ?? 0
    }

    /// The title as the app reports it now. The server's cached copy (dump) trails a change by
    /// a second or more, which is exactly when an expectation is being checked.
    private func windowTitle(_ wid: String) -> String {
        if let line = ((try? rpc("ui.query", ["windowId": wid, "role": "window", "limit": 1]))?["outline"] as? String)?
            .split(separator: "\n").first,
           let open = line.firstIndex(of: "\""), let close = line[line.index(after: open)...].firstIndex(of: "\"") {
            return String(line[line.index(after: open)..<close])
        }
        let windows = (try? rpc("dump", [:]))?["windows"] as? [String: Any]
        return (windows?[wid] as? [String: Any])?["title"] as? String ?? ""
    }

    // MARK: Errors that say what to do next

    /// Known failure signatures and the move that works. One entry per quirk learned the hard
    /// way, delivered at the moment of failure to every client.
    static let advice: [(signature: String, hint: String)] = [
        ("AXPress failed", "Try ui.click(ref) (a real click), or ui.setValue for a checkbox, slider or switch. If the UI changed, the element may be gone: take a fresh ui.snapshot."),
        ("set AXValue failed", "Many web forms and some native fields ignore AXValue. ui.click(ref) the field, then input.key.type with windowId."),
        ("AXScrollToVisible failed", "Scroll with input.mouse.scroll (with windowId) over the list, then ui.snapshot again."),
        ("set AXSelected failed", "This row cannot be selected through accessibility; ui.click(ref) it instead."),
        ("not reachable through accessibility", "Windows on a space that is not visible cannot be driven. space.list shows which space the window is on; window.pull(windowId) brings it to the current space, or space.switch(spaceId) goes to it (refused for a display showing fullscreen content). If it is on the current space already, the app is hung: wait and retry."),
        ("clip.read refused", "Do not work around this: the clipboard holds something marked secret or not-to-be-recorded. Ask the user, or have them copy the value again once they are ready to share it."),
        ("space.switch refused", "Do not work around this. If the display is showing a fullscreen space, the user is watching or presenting something: ask before passing leaveFullscreen=true."),
        ("window.pull refused", "Do not work around this: nothing is moved off or onto a fullscreen space. For a window on a user space, make a display that shows a user space active first (window.focus a window there)."),
        ("was not pulled", "The window server ignored the move. space.switch(spaceId) to the window's space instead, or ask the user to bring the window over."),
        ("did not become current", "The window server ignored the switch. Ask the user to switch spaces (ctrl+arrow or Mission Control), then continue."),
        ("did not take keyboard focus", "A modal sheet, a full-screen app, or another space may be holding focus. grid.screenshot the window to see what is in front of it."),
        ("is covered by", "Use ui.press(ref), which needs no pointer, or move the covering window (grid.window.move, window.minimize) and retry."),
        ("lost keyboard focus", "Something took focus mid-typing (the user, a dialog). Read the field with ui.value to see what landed, then continue from there rather than retyping everything."),
        ("Failed to focus window", "Some apps reject AXRaise yet take focus anyway (Calculator). Check metadata.get, or just use a guarded input call: it verifies focus itself."),
        ("is outside every display", "Coordinates are global screen points; a display above the main one has negative y. Give px/py in pixels of a screenshot instead and let the server convert."),
        ("has moved or resized since shot", "Take a new grid.screenshot of that window and use its pixels."),
        ("unknown ref", "Refs come from the most recent ui.snapshot or ui.query of that window."),
        ("no menu item", "Paths come from menu.snapshot; pass text to find the command, then copy its path as printed."),
        ("is disabled in", "The app decides what is enabled from its selection and focus. Select or click what the command acts on (pass windowId so the right window is key), then retry; menu.snapshot(enabled=true) lists what is available now."),
        ("Request timed out", "The grid server did not answer, usually because an app it was talking to is hung. Run ping; if that fails the server is down (make run)."),
        ("Window not found", "IDs change when a window is recreated. window.find by appName/title again."),
        ("no cell in direction", "The focused window has no neighbouring cell that way in the current layout; grid.layout.get shows the cells."),
    ]

    static func advised(_ result: MCPToolResult) -> MCPToolResult {
        guard let text = result.content.first?["text"] as? String,
              let entry = advice.first(where: { text.localizedCaseInsensitiveContains($0.signature) }) else { return result }
        return MCPToolResult(content: result.content + [["type": "text", "text": "Next: \(entry.hint)"]], isError: true)
    }

    // MARK: Image-pixel coordinates

    struct PixelRefusal: Error {
        let message: String
    }

    /// px/py (and fromPx…toPy for a drag) are pixels of a screenshot this session took: the
    /// last one, or `shot`. They become x/y in screen points; nothing else changes.
    private func resolvePixels(_ args: inout [String: Any]) -> Result<Void, PixelRefusal> {
        let pairs = [("px", "py", "x", "y"), ("fromPx", "fromPy", "fromX", "fromY"), ("toPx", "toPy", "toX", "toY")]
        guard pairs.contains(where: { args[$0.0] != nil || args[$0.1] != nil }) else { return .success(()) }
        let id = (args["shot"] as? NSNumber)?.intValue ?? lastShot
        guard let shot = shots[id] else {
            return .failure(PixelRefusal(message: id == 0 ? "px/py need a screenshot first: take a grid.screenshot in this session, then give pixels of that image"
                                                           : "unknown shot \(id); this session has shots 1...\(lastShot)"))
        }
        for (px, py, x, y) in pairs {
            guard args[px] != nil || args[py] != nil else { continue }
            guard let ix = (args[px] as? NSNumber)?.doubleValue, let iy = (args[py] as? NSNumber)?.doubleValue else {
                return .failure(PixelRefusal(message: "\(px) and \(py) must both be numbers"))
            }
            // The pixels describe where the window WAS. If the grid has moved it since, they now
            // land somewhere else entirely.
            if let wid = shot.windowId, let now = windowInfo(wid)?.frame, now != shot.frame {
                return .failure(PixelRefusal(message: "window \(wid) has moved or resized since shot \(id); take a new screenshot before clicking by pixel"))
            }
            guard ix >= 0, iy >= 0, ix <= shot.image.width, iy <= shot.image.height else {
                return .failure(PixelRefusal(message: "(\(ix), \(iy)) is outside shot \(id), which is \(Int(shot.image.width))x\(Int(shot.image.height)) px"))
            }
            args[x] = shot.frame.minX + ix * shot.frame.width / shot.image.width
            args[y] = shot.frame.minY + iy * shot.frame.height / shot.image.height
            args[px] = nil
            args[py] = nil
        }
        return .success(())
    }

    // MARK: Observe and batch

    /// Wait for the UI to react, then look at the window the action was aimed
    /// at: `windowId`, else the window a `ref` names, else the focused window.
    private func observe(_ mode: String, _ args: [String: Any]) -> MCPToolResult {
        let settle = (args["settleMs"] as? NSNumber)?.intValue ?? 250
        Thread.sleep(forTimeInterval: Double(min(max(settle, 0), 10_000)) / 1000)
        var wid = args["windowId"] as? String ?? (args["windowId"] as? NSNumber)?.stringValue
        if wid == nil, let ref = args["ref"] as? String {
            wid = ref.split(separator: ":").first.map(String.init)
        }
        if wid == nil, let focused = (try? rpc("metadata.get", [:]))?["focusedWindowID"] as? NSNumber {
            wid = focused.stringValue
        }
        guard let wid else { return .text("observe: no window to look at; pass windowId") }
        switch mode {
        case "snapshot": return outline("ui.snapshot", ["windowId": wid])
        case "screenshot": return screenshot(["target": "window", "id": wid])
        default: return .text("observe: unknown mode '\(mode)'; use 'snapshot' or 'screenshot'")
        }
    }

    /// Run steps in order and stop at the first failure. `steps` arrives as a
    /// JSON string because tool props are scalars.
    private func batch(_ args: [String: Any]) -> MCPToolResult {
        guard let text = args["steps"] as? String, let data = text.data(using: .utf8),
              let steps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !steps.isEmpty else {
            return .error("steps must be a JSON array string: [{\"tool\":\"ui.press\",\"args\":{\"ref\":\"7:3\"}}, …]")
        }
        guard steps.count <= Self.maxBatchSteps else { return .error("at most \(Self.maxBatchSteps) steps per batch") }
        var content: [[String: Any]] = []
        for (i, step) in steps.enumerated() {
            guard let name = step["tool"] as? String, name != "batch", mcpToolsByName[name] != nil else {
                return MCPToolResult(content: content + [["type": "text", "text": "step \(i + 1): unknown tool"]], isError: true)
            }
            let result = callTool(name: name, args: step["args"] as? [String: Any] ?? [:])
            for var item in result.content {
                if let t = item["text"] as? String { item["text"] = "step \(i + 1) \(name): \(t)" }
                content.append(item)
            }
            if result.isError {
                content.append(["type": "text", "text": "stopped: step \(i + 1) of \(steps.count) failed; later steps did not run"])
                return MCPToolResult(content: content, isError: true)
            }
        }
        return MCPToolResult(content: content, isError: false)
    }

    static let maxBatchSteps = 20

    // The outline is line-oriented text; JSON-escaping it would bury every
    // newline. Send the rest of the result as a JSON header, then the text.
    private func outline(_ method: String, _ params: [String: Any]) -> MCPToolResult {
        do {
            var result = try rpc(method, params)
            guard let text = result.removeValue(forKey: "outline") as? String else {
                return .json(result)
            }
            // The thin-tree hint is about a window's outline; three menu commands matching a filter is not thin.
            if method.hasPrefix("ui."),
               let hint = Self.outlineHint(text, count: (result["count"] as? NSNumber)?.intValue ?? 0, isQuery: method == "ui.query") {
                result["hint"] = hint
            }
            let header = MCPToolResult.json(result)
            return MCPToolResult(content: header.content + [["type": "text", "text": text]], isError: false)
        } catch {
            return .error("Error: \(error)")
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
        var waited: [String: Any] = [:]
        if let settle = (args["settleMs"] as? NSNumber)?.intValue, settle > 0 {
            Thread.sleep(forTimeInterval: Double(min(settle, 10_000)) / 1000)
        }
        let timeout = Double(min(max((args["timeoutMs"] as? NSNumber)?.intValue ?? 5000, 0), 30_000)) / 1000
        if let title = args["waitTitle"] as? String, let id = args["id"] as? String, let wid = Int(id) {
            waited["titleMatched"] = waitForTitle(wid, containing: title, timeout: timeout)
        }

        let tmp = FileManager.default.temporaryDirectory
        let pngPath = tmp.appendingPathComponent("grid-screenshot-\(UUID().uuidString).png").path
        defer {
            try? FileManager.default.removeItem(atPath: pngPath)
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
            let info = windowInfo(wid)
            frame = info?.frame
            // The capture shows the window even when something covers it; a click would not reach it.
            if let info, let covering = coveringApps(info.frame, pid: info.pid), !covering.isEmpty {
                geometry["coveredBy"] = covering
                geometry["hint"] = "Part of this window is covered on screen, though the image shows all of it. A plain input.mouse.* there hits the covering window; pass windowId so the window is raised and the click is checked, or use ui.press."
            }
            // -o: no window shadow, so the image edge is the window edge.
            captureArgs += ["-l", String(wid), "-o"]
        case "region":
            guard let requested = rect(fromDict: args), requested.width > 0, requested.height > 0 else {
                return .error("region target requires x, y, width, height in screen points (width and height > 0)")
            }
            // Clip to one display so the reported frame is exactly what was captured.
            guard let clipped = Self.clipRegion(requested, to: displayFrames().map { $0.frame }) else {
                return .error("region \(requested.minX),\(requested.minY) \(requested.width)x\(requested.height) is not on any display")
            }
            frame = clipped
            if clipped != requested.integral {
                // Say so: the caller asked for one rectangle and is looking at another.
                geometry["clipped"] = true
                geometry["requested"] = ["x": requested.minX, "y": requested.minY, "width": requested.width, "height": requested.height]
            }
            captureArgs += ["-R", "\(Int(clipped.minX)),\(Int(clipped.minY)),\(Int(clipped.width)),\(Int(clipped.height))"]
        default:
            return .error("unknown target; use 'full', 'window', 'cell', or 'region'")
        }
        captureArgs.append(pngPath)

        if args["waitStable"] as? Bool == true {
            waited["stable"] = waitUntilStable(captureArgs, timeout: timeout)
        }
        for (key, value) in waited { geometry[key] = value }

        let captureStatus = run("/usr/sbin/screencapture", captureArgs)
        guard captureStatus == 0 else {
            return .error("screencapture failed with exit code \(captureStatus)")
        }
        guard let png = FileManager.default.contents(atPath: pngPath), !png.isEmpty else {
            return .error("screenshot file not found at \(pngPath)")
        }

        var imageData = png
        var mimeType = "image/png"
        if !high {
            guard let jpeg = Self.downscaledJPEG(png, maxEdge: Self.lowQualityMaxEdge) else {
                return .error("could not downscale screenshot")
            }
            imageData = jpeg
            mimeType = "image/jpeg"
        } else if png.count > Self.maxInlineImageBytes,
                  let jpeg = Self.downscaledJPEG(png, maxEdge: Self.highQualityMaxEdge, quality: 0.85) {
            // A Retina PNG of a whole display blows past the per-image limit; keep the pixels, drop the format.
            imageData = jpeg
            mimeType = "image/jpeg"
        }

        if let f = frame {
            geometry["frame"] = ["x": f.minX, "y": f.minY, "width": f.width, "height": f.height]
        }
        if let size = Self.pixelSize(imageData) {
            geometry["image"] = ["width": size.width, "height": size.height]
            if let f = frame {
                lastShot += 1
                shots[lastShot] = (f, CGSize(width: size.width, height: size.height), geometry["windowId"] as? Int)
                shots[lastShot - 8] = nil
                geometry["shot"] = lastShot
            }
            // Below roughly one image pixel per 1.5 points, prose survives but digits and tokens do not.
            if let f = frame, size.width > 0, f.width / CGFloat(size.width) > 1.5 {
                let note = "Downscaled \(String(format: "%.1f", f.width / CGFloat(size.width)))x: do not trust small text, digits or IDs from this image. Read them with ui.snapshot / ui.value, or zoom with target=region."
                geometry["hint"] = [geometry["hint"] as? String, note].compactMap { $0 }.joined(separator: " ")
            }
        }
        var result = MCPToolResult.image(imageData, mimeType: mimeType)
        if let data = try? JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            result = MCPToolResult(content: result.content + [["type": "text", "text": text]], isError: false)
        }
        return result
    }

    /// Poll the window's title (a page load, a document opening) until it contains `text`.
    private func waitForTitle(_ wid: Int, containing text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let windows = (try? rpc("dump", [:]))?["windows"] as? [String: Any],
               let title = (windows[String(wid)] as? [String: Any])?["title"] as? String,
               title.localizedCaseInsensitiveContains(text) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return false
    }

    /// Capture until two frames 150 ms apart look the same. Compared as 64 px
    /// grey thumbnails with a tolerance, so a blinking caret does not count as motion.
    private func waitUntilStable(_ captureArgs: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: [UInt8]?
        repeat {
            let probe = captureArgs.dropLast() + [captureArgs.last! + ".probe.png"]
            defer { try? FileManager.default.removeItem(atPath: probe.last!) }
            guard run("/usr/sbin/screencapture", Array(probe)) == 0,
                  let data = FileManager.default.contents(atPath: probe.last!),
                  let thumb = Self.greyThumbnail(data) else { return false }
            if let previous, Self.meanDifference(previous, thumb) < 1.0 { return true }
            previous = thumb
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return false
    }

    static func greyThumbnail(_ image: Data, edge: Int = 64) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: edge * edge)
        guard let ctx = CGContext(data: &pixels, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: edge,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: edge, height: edge))
        return pixels
    }

    static func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var total = 0
        for i in 0..<a.count { total += abs(Int(a[i]) - Int(b[i])) }
        return Double(total) / Double(a.count)
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
    private func windowInfo(_ wid: Int) -> (frame: CGRect, pid: Int)? {
        guard let result = try? rpc("dump", [:]),
              let windows = result["windows"] as? [String: Any],
              let window = windows[String(wid)] as? [String: Any],
              let f = window["frame"] as? [[NSNumber]], f.count == 2, f[0].count == 2, f[1].count == 2 else {
            return nil
        }
        let frame = CGRect(x: f[0][0].doubleValue, y: f[0][1].doubleValue, width: f[1][0].doubleValue, height: f[1][1].doubleValue)
        return (frame, (window["pid"] as? NSNumber)?.intValue ?? 0)
    }

    /// Apps other than the window's own that are on top of it at the centre or
    /// near a corner. nil when the server cannot say (older server, no window.at).
    private func coveringApps(_ frame: CGRect, pid: Int) -> [String]? {
        let inset = frame.insetBy(dx: frame.width * 0.1, dy: frame.height * 0.1)
        let samples = [CGPoint(x: frame.midX, y: frame.midY), CGPoint(x: inset.minX, y: inset.minY), CGPoint(x: inset.maxX, y: inset.minY),
                       CGPoint(x: inset.minX, y: inset.maxY), CGPoint(x: inset.maxX, y: inset.maxY)]
        var apps: [String] = []
        for p in samples {
            guard let top = try? rpc("window.at", ["x": p.x, "y": p.y]) else { return nil }
            guard top["found"] as? Bool == true, (top["pid"] as? NSNumber)?.intValue != pid,
                  let name = top["appName"] as? String, !apps.contains(name) else { continue }
            apps.append(name)
        }
        return apps
    }

    private func rect(fromDict d: [String: Any]) -> CGRect? {
        guard let x = (d["x"] as? NSNumber)?.doubleValue, let y = (d["y"] as? NSNumber)?.doubleValue,
              let w = (d["width"] as? NSNumber)?.doubleValue, let h = (d["height"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // Long edge of a low-quality capture. Vision input is downscaled past
    // roughly this size anyway, so more pixels only cost tokens.
    static let lowQualityMaxEdge = 1568

    // Conservative: vision APIs cap inline images at roughly 5 MB and 8000 px
    // an edge, and base64 adds a third on the wire.
    static let maxInlineImageBytes = 4_000_000
    static let highQualityMaxEdge = 7680

    /// The part of `region` on the display it overlaps most, or nil when it
    /// is off every display. Integral so it matches what screencapture -R gets.
    static func clipRegion(_ region: CGRect, to displays: [CGRect]) -> CGRect? {
        var best: CGRect?
        for display in displays {
            let part = display.intersection(region).integral
            guard !part.isNull, part.width >= 1, part.height >= 1 else { continue }
            if let current = best, current.width * current.height >= part.width * part.height { continue }
            best = part
        }
        return best
    }

    /// JPEG with the long edge at most `maxEdge`. Never upscales.
    static func downscaledJPEG(_ image: Data, maxEdge: Int, quality: Double = 0.6) -> Data? {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func pixelSize(_ image: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            return nil
        }
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
