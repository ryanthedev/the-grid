import Foundation
import MCP

/// MCP tool definitions for window.* direct RPC methods.
/// These map 1:1 to the grid-server's MessageHandler window methods.
enum WindowTools {

    static let definitions: [Tool] = [
        Tool(
            name: "window.find",
            description: "Find a window by app name, title substring, or process ID. Returns the first visible match with its window ID.",
            inputSchema: objectSchema(
                properties: [
                    "appName": prop("string", description: "Exact application name (e.g. 'Safari', 'Terminal')"),
                    "title": prop("string", description: "Window title substring to match"),
                    "pid": prop("integer", description: "Process ID (walks ancestor chain to find owning window)"),
                ]
            ),
            annotations: .init(readOnlyHint: true)
        ),

        Tool(
            name: "window.focus",
            description: "Focus a specific window by ID: raise it to front and activate its application.",
            inputSchema: objectSchema(
                properties: [
                    "windowId": prop("string", description: "Window ID to focus")
                ],
                required: ["windowId"]
            ),
            annotations: .init(readOnlyHint: false, idempotentHint: true)
        ),

        Tool(
            name: "window.close",
            description: "Close a window by pressing its close button via accessibility.",
            inputSchema: objectSchema(
                properties: [
                    "windowId": prop("string", description: "Window ID to close")
                ],
                required: ["windowId"]
            ),
            annotations: .init(readOnlyHint: false, destructiveHint: true)
        ),

        Tool(
            name: "window.minimize",
            description: "Minimize a window to the dock.",
            inputSchema: objectSchema(
                properties: [
                    "windowId": prop("string", description: "Window ID to minimize")
                ],
                required: ["windowId"]
            ),
            annotations: .init(readOnlyHint: false)
        ),

        Tool(
            name: "window.unminimize",
            description: "Restore a minimized window from the dock.",
            inputSchema: objectSchema(
                properties: [
                    "windowId": prop("string", description: "Window ID to restore")
                ],
                required: ["windowId"]
            ),
            annotations: .init(readOnlyHint: false)
        ),

        Tool(
            name: "window.raise",
            description: "Raise a window to front without changing keyboard focus.",
            inputSchema: objectSchema(
                properties: [
                    "windowId": prop("string", description: "Window ID to raise")
                ],
                required: ["windowId"]
            ),
            annotations: .init(readOnlyHint: false)
        ),

        Tool(
            name: "window.show",
            description: "Show a hidden window: unhide its application and bring the window to front.",
            inputSchema: objectSchema(
                properties: [
                    "windowId": prop("string", description: "Window ID to show")
                ],
                required: ["windowId"]
            ),
            annotations: .init(readOnlyHint: false)
        ),

        Tool(
            name: "window.hide",
            description: "Hide a window (order it out or hide its application).",
            inputSchema: objectSchema(
                properties: [
                    "windowId": prop("string", description: "Window ID to hide")
                ],
                required: ["windowId"]
            ),
            annotations: .init(readOnlyHint: false)
        ),

        Tool(
            name: "window.setOpacity",
            description: "Set window transparency. 0.0 = fully transparent, 1.0 = fully opaque.",
            inputSchema: objectSchema(
                properties: [
                    "windowId": prop("string", description: "Window ID"),
                    "opacity": prop("number", description: "Opacity value from 0.0 to 1.0"),
                ],
                required: ["windowId", "opacity"]
            ),
            annotations: .init(readOnlyHint: false)
        ),

        Tool(
            name: "window.getOpacity",
            description: "Get the current opacity of a window.",
            inputSchema: objectSchema(
                properties: [
                    "windowId": prop("string", description: "Window ID")
                ],
                required: ["windowId"]
            ),
            annotations: .init(readOnlyHint: true)
        ),

        Tool(
            name: "window.setLayer",
            description: "Set window stacking layer: 'above' stays on top, 'below' stays behind, 'normal' is default.",
            inputSchema: objectSchema(
                properties: [
                    "windowId": prop("string", description: "Window ID"),
                    "layer": prop("string", description: "Window layer", enumValues: ["below", "normal", "above"]),
                ],
                required: ["windowId", "layer"]
            ),
            annotations: .init(readOnlyHint: false)
        ),

        Tool(
            name: "window.getLayer",
            description: "Get the current stacking layer of a window.",
            inputSchema: objectSchema(
                properties: [
                    "windowId": prop("string", description: "Window ID")
                ],
                required: ["windowId"]
            ),
            annotations: .init(readOnlyHint: true)
        ),

        Tool(
            name: "window.setSticky",
            description: "Make a window appear on all macOS spaces (sticky) or only its current space.",
            inputSchema: objectSchema(
                properties: [
                    "windowId": prop("string", description: "Window ID"),
                    "sticky": prop("boolean", description: "true = show on all spaces, false = current space only"),
                ],
                required: ["windowId", "sticky"]
            ),
            annotations: .init(readOnlyHint: false)
        ),

        Tool(
            name: "window.isSticky",
            description: "Check if a window appears on all macOS spaces.",
            inputSchema: objectSchema(
                properties: [
                    "windowId": prop("string", description: "Window ID")
                ],
                required: ["windowId"]
            ),
            annotations: .init(readOnlyHint: true)
        ),
    ]

    /// Handle a window.* tool call by forwarding to the grid-server RPC.
    /// Tool names match grid-server RPC method names exactly.
    static func handle(
        name: String,
        arguments: [String: Value]?,
        rpcClient: RPCClient
    ) -> CallTool.Result {
        return callRPC(method: name, arguments: arguments, rpcClient: rpcClient)
    }
}
