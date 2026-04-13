import Foundation
import MCP

/// MCP tool definitions for grid.* commands.
/// These map 1:1 to the grid-server's registered grid.* RPC methods.
enum GridTools {

    static let definitions: [Tool] = [
        // MARK: - Focus

        Tool(
            name: "grid.focus",
            description: "Move focus to an adjacent window in the grid.",
            inputSchema: objectSchema(
                properties: [
                    "direction": prop("string", description: "Direction to move focus", enumValues: ["left", "right", "up", "down"]),
                    "wrap": prop("boolean", description: "Wrap around grid edges"),
                    "extend": prop("boolean", description: "Extend selection to additional cell"),
                ],
                required: ["direction"]
            ),
            annotations: .init(readOnlyHint: false, idempotentHint: true)
        ),

        Tool(
            name: "grid.focus.cycle",
            description: "Cycle focus to the next or previous window in the grid.",
            inputSchema: objectSchema(
                properties: [
                    "forward": prop("boolean", description: "true for next, false for previous (default: true)")
                ]
            ),
            annotations: .init(readOnlyHint: false, idempotentHint: true)
        ),

        Tool(
            name: "grid.focus.cell",
            description: "Focus a specific grid cell by ID.",
            inputSchema: objectSchema(
                properties: [
                    "cell": prop("string", description: "Cell ID to focus"),
                    "space": prop("string", description: "Space ID (default: active space)"),
                ],
                required: ["cell"]
            ),
            annotations: .init(readOnlyHint: false, idempotentHint: true)
        ),

        // MARK: - Layout

        Tool(
            name: "grid.layout.apply",
            description: "Apply a named layout to the active space, arranging all windows into the grid.",
            inputSchema: objectSchema(
                properties: [
                    "layout": prop("string", description: "Layout ID to apply (e.g. 'tall-wide', 'even-3col')"),
                    "strategy": prop("string", description: "Window assignment strategy", enumValues: ["position", "preserve", "autoflow", "pinned"]),
                ],
                required: ["layout"]
            ),
            annotations: .init(readOnlyHint: false)
        ),

        Tool(
            name: "grid.layout.cycle",
            description: "Cycle to the next layout in the configured layout list.",
            inputSchema: emptySchema,
            annotations: .init(readOnlyHint: false)
        ),

        Tool(
            name: "grid.layout.refresh",
            description: "Reapply current layouts to all displays, snapping windows back to their grid cells.",
            inputSchema: objectSchema(
                properties: [
                    "display": prop("string", description: "Display UUID to refresh (default: all displays)")
                ]
            ),
            annotations: .init(readOnlyHint: false, idempotentHint: true)
        ),

        Tool(
            name: "grid.layout.list",
            description: "List all available layout IDs. Use grid.layout.get to see a layout's full definition.",
            inputSchema: emptySchema,
            annotations: .init(readOnlyHint: true)
        ),

        Tool(
            name: "grid.layout.current",
            description: "Get the current layout ID and space ID for the active display.",
            inputSchema: emptySchema,
            annotations: .init(readOnlyHint: true)
        ),

        Tool(
            name: "grid.layout.get",
            description: "Get the full definition of a layout: grid dimensions, cell positions, padding, and stack modes.",
            inputSchema: objectSchema(
                properties: [
                    "layout": prop("string", description: "Layout ID")
                ],
                required: ["layout"]
            ),
            annotations: .init(readOnlyHint: true)
        ),

        // MARK: - Cell

        Tool(
            name: "grid.cell.send",
            description: "Send the focused window to the adjacent cell in the given direction.",
            inputSchema: objectSchema(
                properties: [
                    "direction": prop("string", description: "Direction to send", enumValues: ["left", "right", "up", "down"])
                ],
                required: ["direction"]
            ),
            annotations: .init(readOnlyHint: false)
        ),

        Tool(
            name: "grid.cell.mode",
            description: "Set or cycle the stack mode of the focused cell. Modes: vertical (split top/bottom), horizontal (split left/right), tabs (tabbed).",
            inputSchema: objectSchema(
                properties: [
                    "mode": prop("string", description: "Target mode, or omit to cycle", enumValues: ["vertical", "horizontal", "tabs"])
                ]
            ),
            annotations: .init(readOnlyHint: false)
        ),

        // MARK: - Window Movement

        Tool(
            name: "grid.window.move",
            description: "Move the focused window to the adjacent cell. With extend, the window spans both cells.",
            inputSchema: objectSchema(
                properties: [
                    "direction": prop("string", description: "Direction to move", enumValues: ["left", "right", "up", "down"]),
                    "wrap": prop("boolean", description: "Wrap around grid edges"),
                    "extend": prop("boolean", description: "Extend window to span both source and target cells"),
                ],
                required: ["direction"]
            ),
            annotations: .init(readOnlyHint: false)
        ),

        Tool(
            name: "grid.window.swap",
            description: "Swap the focused window with the window in the adjacent cell.",
            inputSchema: objectSchema(
                properties: [
                    "direction": prop("string", description: "Direction of cell to swap with", enumValues: ["left", "right", "up", "down"])
                ],
                required: ["direction"]
            ),
            annotations: .init(readOnlyHint: false)
        ),

        // MARK: - Resize

        Tool(
            name: "grid.resize.grow",
            description: "Grow the focused window's split ratio.",
            inputSchema: objectSchema(
                properties: [
                    "amount": prop("number", description: "Amount to grow as fraction (default: 0.1, range 0.0-1.0)")
                ]
            ),
            annotations: .init(readOnlyHint: false)
        ),

        Tool(
            name: "grid.resize.shrink",
            description: "Shrink the focused window's split ratio.",
            inputSchema: objectSchema(
                properties: [
                    "amount": prop("number", description: "Amount to shrink as fraction (default: 0.1, range 0.0-1.0)")
                ]
            ),
            annotations: .init(readOnlyHint: false)
        ),

        Tool(
            name: "grid.resize.cell",
            description: "Adjust a cell boundary in the given direction.",
            inputSchema: objectSchema(
                properties: [
                    "direction": prop("string", description: "Direction of boundary to adjust", enumValues: ["left", "right", "up", "down"]),
                    "amount": prop("number", description: "Amount to adjust as fraction (default: 0.05)"),
                ],
                required: ["direction"]
            ),
            annotations: .init(readOnlyHint: false)
        ),

        Tool(
            name: "grid.resize.reset",
            description: "Reset split ratios to equal sizes.",
            inputSchema: objectSchema(
                properties: [
                    "cell": prop("boolean", description: "Reset cell ratios instead of window splits"),
                    "all": prop("boolean", description: "Reset all cells, not just the focused one"),
                ]
            ),
            annotations: .init(readOnlyHint: false)
        ),

        // MARK: - Record

        Tool(
            name: "grid.record.start",
            description: "Start a screen recording of a cell, window, display, or all screens.",
            inputSchema: objectSchema(
                properties: [
                    "target": prop("string", description: "What to record", enumValues: ["cell", "window", "screen", "all"]),
                    "id": prop("string", description: "Target ID (cell ID, window ID, or screen index)"),
                    "format": prop("string", description: "Output format", enumValues: ["gif", "mp4", "mov"]),
                    "duration": prop("integer", description: "Auto-stop after N seconds"),
                    "fps": prop("integer", description: "Frames per second"),
                    "width": prop("integer", description: "Output width in pixels"),
                    "quality": prop("string", description: "Quality preset", enumValues: ["low", "medium", "high"]),
                    "cursor": prop("boolean", description: "Include cursor in recording"),
                    "output": prop("string", description: "Output file path"),
                ]
            ),
            annotations: .init(readOnlyHint: false)
        ),

        Tool(
            name: "grid.record.stop",
            description: "Stop the active recording and return the output file path.",
            inputSchema: emptySchema,
            annotations: .init(readOnlyHint: false)
        ),

        Tool(
            name: "grid.record.toggle",
            description: "Toggle recording: start if idle, stop if recording. Returns recording result on stop.",
            inputSchema: objectSchema(
                properties: [
                    "target": prop("string", description: "What to record", enumValues: ["cell", "window", "screen", "all"]),
                    "format": prop("string", description: "Output format", enumValues: ["gif", "mp4", "mov"]),
                ]
            ),
            annotations: .init(readOnlyHint: false)
        ),

        // MARK: - State & Config

        Tool(
            name: "grid.state.reset",
            description: "Clear all grid state for the active space (cell assignments, layout, focus tracking).",
            inputSchema: emptySchema,
            annotations: .init(readOnlyHint: false, destructiveHint: true)
        ),

        Tool(
            name: "grid.state.show",
            description: "Export the full grid state: cell assignments, current layouts, focus tracking per space.",
            inputSchema: emptySchema,
            annotations: .init(readOnlyHint: true)
        ),

        Tool(
            name: "grid.config.show",
            description: "Export the grid configuration summary: layouts, spacing, settings.",
            inputSchema: emptySchema,
            annotations: .init(readOnlyHint: true)
        ),

        // MARK: - Screenshot

        Tool(
            name: "grid.screenshot",
            description: "Capture a screenshot and return it as an inline image Claude can view. Targets: 'full' (entire screen), 'window' (specific window by ID), 'cell' (grid cell by ID — captures the focused window in that cell). Returns a small compressed JPEG by default to save context. Use quality='high' for full resolution PNG.",
            inputSchema: objectSchema(
                properties: [
                    "target": prop("string", description: "What to capture: 'full', 'window', or 'cell' (default: full)", enumValues: ["full", "window", "cell"]),
                    "id": prop("string", description: "Window ID for target=window, or cell ID for target=cell"),
                    "cursor": prop("boolean", description: "Include cursor (full screen only)"),
                    "display": prop("integer", description: "Display index, 0-based (full screen only, default: main display)"),
                    "quality": prop("string", description: "Image quality: 'low' (default) returns compressed JPEG ≤1024px to save context, 'high' returns full-resolution PNG", enumValues: ["low", "high"]),
                ]
            ),
            annotations: .init(readOnlyHint: true)
        ),

        // MARK: - Utility

        Tool(
            name: "grid.terminal",
            description: "Toggle the grid terminal overlay.",
            inputSchema: emptySchema,
            annotations: .init(readOnlyHint: false)
        ),

    ]

    /// Handle a grid.* tool call by forwarding to the grid-server RPC.
    /// Tool names match grid-server RPC method names exactly.
    static func handle(
        name: String,
        arguments: [String: Value]?,
        rpcClient: RPCClient
    ) -> CallTool.Result {
        // grid.screenshot is implemented locally (screencapture), not via RPC.
        if name == "grid.screenshot" {
            return handleScreenshot(arguments: arguments, rpcClient: rpcClient)
        }

        // grid.resize.grow and grid.resize.shrink are not direct RPCs.
        // The server has grid.resize.adjust with a signed delta.
        // Convert grow/shrink to the adjust RPC.
        if name == "grid.resize.grow" || name == "grid.resize.shrink" {
            return handleResizeGrowShrink(name: name, arguments: arguments, rpcClient: rpcClient)
        }

        return callRPC(method: name, arguments: arguments, rpcClient: rpcClient)
    }

    // MARK: - Screenshot

    /// Capture a screenshot using macOS screencapture and return as MCP image content.
    /// Default: compressed JPEG ≤1024px to save context. quality=high: full-res PNG.
    private static func handleScreenshot(
        arguments: [String: Value]?,
        rpcClient: RPCClient
    ) -> CallTool.Result {
        let target = arguments?["target"]?.stringValue ?? "full"
        let id = arguments?["id"]?.stringValue
        let includeCursor = arguments?["cursor"]?.boolValue ?? false
        let displayIndex = arguments?["display"]?.intValue
        let quality = arguments?["quality"]?.stringValue ?? "low"
        let highQuality = quality == "high"

        // Build a unique temp file path for this capture.
        let uuid = UUID().uuidString
        let pngPath = "/tmp/grid-screenshot-\(uuid).png"

        // Build screencapture args based on target.
        var args: [String] = ["-x"]  // silent (no shutter sound)

        switch target {
        case "full":
            if includeCursor { args.append("-C") }
            if let idx = displayIndex {
                // screencapture -D is 1-based
                args += ["-D", "\(idx + 1)"]
            }
            args.append(pngPath)

        case "window":
            guard let windowIdStr = id, let windowId = UInt32(windowIdStr) else {
                return errorResult("window target requires a numeric 'id' (window ID)")
            }
            args += ["-l", "\(windowId)"]
            args.append(pngPath)

        case "cell":
            guard let cellId = id else {
                return errorResult("cell target requires 'id' (cell ID, e.g. 'left', 'right')")
            }
            // Resolve the focused window in this cell via grid.state.show RPC.
            guard let windowId = resolveWindowIdForCell(cellId: cellId, rpcClient: rpcClient) else {
                return errorResult("could not find a focused window in cell '\(cellId)'")
            }
            args += ["-l", "\(windowId)"]
            args.append(pngPath)

        default:
            return errorResult("unknown target '\(target)'; use 'full', 'window', or 'cell'")
        }

        // Run screencapture synchronously.
        do {
            try runProcessSync("/usr/sbin/screencapture", arguments: args)
        } catch {
            return errorResult("screencapture failed: \(error)")
        }

        defer { try? FileManager.default.removeItem(atPath: pngPath) }
        guard FileManager.default.fileExists(atPath: pngPath) else {
            return errorResult("screenshot file not found at \(pngPath)")
        }

        if highQuality {
            // Return full-resolution PNG.
            guard let pngData = FileManager.default.contents(atPath: pngPath), !pngData.isEmpty else {
                return errorResult("screenshot file empty at \(pngPath)")
            }
            let base64String = pngData.base64EncodedString()
            return CallTool.Result(
                content: [.image(data: base64String, mimeType: "image/png", annotations: nil, _meta: nil)]
            )
        }

        // Low quality: resize to ≤1024px and convert to compressed JPEG via sips.
        let jpegPath = "/tmp/grid-screenshot-\(uuid).jpg"
        defer { try? FileManager.default.removeItem(atPath: jpegPath) }

        do {
            // Resize longest edge to 1024px (no-op if already smaller), output as JPEG.
            try runProcessSync("/usr/bin/sips", arguments: [
                "--resampleHeightWidthMax", "1024",
                "--setProperty", "format", "jpeg",
                "--setProperty", "formatOptions", "60",
                pngPath,
                "--out", jpegPath,
            ])
        } catch {
            return errorResult("sips resize/compress failed: \(error)")
        }

        guard let jpegData = FileManager.default.contents(atPath: jpegPath), !jpegData.isEmpty else {
            return errorResult("compressed screenshot empty at \(jpegPath)")
        }
        let base64String = jpegData.base64EncodedString()

        return CallTool.Result(
            content: [.image(data: base64String, mimeType: "image/jpeg", annotations: nil, _meta: nil)]
        )
    }

    /// Find the lastFocusedWid for a cell ID in the active space via grid.state.show RPC.
    /// Returns nil if no window is found.
    private static func resolveWindowIdForCell(cellId: String, rpcClient: RPCClient) -> UInt32? {
        do {
            let result = try rpcClient.call("grid.state.show")
            guard let state = result["state"] as? [String: Any],
                  let spaces = state["spaces"] as? [String: Any] else { return nil }

            // Walk all spaces to find the cell. Return the lastFocusedWid.
            for (_, spaceValue) in spaces {
                guard let space = spaceValue as? [String: Any],
                      let cells = space["cells"] as? [String: Any],
                      let cell = cells[cellId] as? [String: Any] else { continue }

                // lastFocusedWid may be Int (from grid state JSON) or false (no window).
                if let wid = cell["lastFocusedWid"] as? Int, wid > 0 {
                    return UInt32(wid)
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Run an external process synchronously; throws if exit code is non-zero.
    private static func runProcessSync(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ScreenshotError.processFailed(process.terminationStatus, output)
        }
    }

    /// Build an error CallTool.Result with isError set.
    private static func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: "Error: \(message)", annotations: nil, _meta: nil)],
            isError: true
        )
    }

    // MARK: - Resize

    /// Convert grid.resize.grow/shrink to grid.resize.adjust RPC.
    private static func handleResizeGrowShrink(
        name: String,
        arguments: [String: Value]?,
        rpcClient: RPCClient
    ) -> CallTool.Result {
        var amount = 0.1
        if let args = arguments, let amountVal = args["amount"] {
            if let d = amountVal.doubleValue {
                amount = d
            } else if let i = amountVal.intValue {
                amount = Double(i)
            }
        }

        let delta = name == "grid.resize.shrink" ? -amount : amount
        let adjustArgs: [String: Value] = ["delta": .double(delta)]
        return callRPC(method: "grid.resize.adjust", arguments: adjustArgs, rpcClient: rpcClient)
    }
}

// MARK: - Screenshot Error

private enum ScreenshotError: Error, CustomStringConvertible {
    case processFailed(Int32, String)

    var description: String {
        switch self {
        case .processFailed(let code, let output):
            let detail = output.isEmpty ? "" : ": \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            return "exit \(code)\(detail)"
        }
    }
}
