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
        // grid.resize.grow and grid.resize.shrink are not direct RPCs.
        // The server has grid.resize.adjust with a signed delta.
        // Convert grow/shrink to the adjust RPC.
        if name == "grid.resize.grow" || name == "grid.resize.shrink" {
            return handleResizeGrowShrink(name: name, arguments: arguments, rpcClient: rpcClient)
        }

        return callRPC(method: name, arguments: arguments, rpcClient: rpcClient)
    }

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
