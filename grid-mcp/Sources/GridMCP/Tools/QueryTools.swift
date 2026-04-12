import Foundation
import MCP

/// MCP tool definitions for read-only queries and miscellaneous RPCs.
/// Covers: ping, getServerInfo, metadata, displays, dump, space.focus, mouse.warp.
enum QueryTools {

    static let definitions: [Tool] = [
        Tool(
            name: "ping",
            description: "Test connectivity to the grid server. Returns server version and timestamp.",
            inputSchema: emptySchema,
            annotations: .init(readOnlyHint: true)
        ),

        Tool(
            name: "getServerInfo",
            description: "Get grid server name, version, commit hash, and capabilities.",
            inputSchema: emptySchema,
            annotations: .init(readOnlyHint: true)
        ),

        Tool(
            name: "metadata.get",
            description: "Get cached window manager metadata: focused window ID, active display UUID, active space ID, last update time.",
            inputSchema: emptySchema,
            annotations: .init(readOnlyHint: true)
        ),

        Tool(
            name: "display.list",
            description: "List all connected displays with their UUID, name, frame, visible frame, scale factor, and current space.",
            inputSchema: emptySchema,
            annotations: .init(readOnlyHint: true)
        ),

        Tool(
            name: "display.get",
            description: "Get a single display by UUID, or the currently active display.",
            inputSchema: objectSchema(
                properties: [
                    "uuid": prop("string", description: "Display UUID"),
                    "active": prop("boolean", description: "Set true to get the currently active display"),
                ]
            ),
            annotations: .init(readOnlyHint: true)
        ),

        Tool(
            name: "dump",
            description: "Get the complete window manager state: all windows (with frame, app, title, spaces), all displays, all apps. Large response.",
            inputSchema: emptySchema,
            annotations: .init(readOnlyHint: true)
        ),

        Tool(
            name: "space.focus",
            description: "Switch to a specific macOS space by its numeric ID.",
            inputSchema: objectSchema(
                properties: [
                    "spaceId": prop("string", description: "Space ID to switch to")
                ],
                required: ["spaceId"]
            ),
            annotations: .init(readOnlyHint: false)
        ),

        Tool(
            name: "mouse.warp",
            description: "Warp the mouse cursor to the center of a window.",
            inputSchema: objectSchema(
                properties: [
                    "windowId": prop("string", description: "Window ID to warp cursor to")
                ],
                required: ["windowId"]
            ),
            annotations: .init(readOnlyHint: false)
        ),

        Tool(
            name: "pick.show",
            description: "Show the app/action picker overlay and return the user's selection.",
            inputSchema: emptySchema,
            annotations: .init(readOnlyHint: false)
        ),
    ]

    /// Set of tool names this module handles, for fast lookup.
    private static let handledNames: Set<String> = Set(definitions.map { $0.name })

    /// Check if this module handles a given tool name.
    static func canHandle(name: String) -> Bool {
        return handledNames.contains(name)
    }

    /// Handle a query tool call by forwarding to the grid-server RPC.
    /// Tool names match grid-server RPC method names exactly.
    static func handle(
        name: String,
        arguments: [String: Value]?,
        rpcClient: RPCClient
    ) -> CallTool.Result {
        return callRPC(method: name, arguments: arguments, rpcClient: rpcClient)
    }
}
