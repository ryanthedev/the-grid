# Pseudocode: Phase 2 - MCP Tool Definitions + Dispatch

## DW Verification

| DW-ID | Done-When Item | Status | Pseudocode Section |
|-------|---------------|--------|-------------------|
| DW-2.1 | `tools/list` returns all Grid tools with correct names, descriptions, and inputSchemas | COVERED | ToolRegistry, All tool group files |
| DW-2.2 | `tools/call` with `grid.focus` dispatches the RPC and returns the result | COVERED | ToolDispatcher, GridTools |
| DW-2.3 | `tools/call` with `grid.layout.list` returns layout data | COVERED | ToolDispatcher, GridTools |
| DW-2.4 | `tools/call` with `window.find` returns window data matching query | COVERED | ToolDispatcher, WindowTools |
| DW-2.5 | `tools/call` with an invalid method name returns MCP response with `isError: true` and non-empty content text | COVERED | ToolDispatcher default case |

**All items COVERED:** YES

## Files to Create/Modify

- `grid-mcp/Sources/GridMCP/Tools/ToolRegistry.swift` — central registry of all tools + dispatch
- `grid-mcp/Sources/GridMCP/Tools/GridTools.swift` — grid.* command tools
- `grid-mcp/Sources/GridMCP/Tools/WindowTools.swift` — window.* direct RPC tools
- `grid-mcp/Sources/GridMCP/Tools/QueryTools.swift` — read-only query tools (ping, getServerInfo, metadata.get, display.*, dump)
- `grid-mcp/Sources/GridMCP/main.swift` — replace placeholder handlers with ToolRegistry

## Pseudocode

### ToolRegistry.swift [DW-2.1, DW-2.2, DW-2.3, DW-2.4, DW-2.5]

Central registry that collects all Tool definitions and dispatches tool calls.

```
// ToolRegistry.swift
// Single source of truth for all MCP tool definitions and dispatch

struct ToolRegistry:
    // Reference to the RPC client for making calls
    let rpcClient: RPCClient

    // Collect all Tool definitions from sub-modules
    func allTools() -> [Tool]:
        return GridTools.definitions
             + WindowTools.definitions
             + QueryTools.definitions

    // Dispatch a tool call by name to the correct handler
    // Returns CallTool.Result
    func dispatch(name: String, arguments: [String: Value]?) -> CallTool.Result:
        // Check grid.* tools first (most common)
        if name starts with "grid.":
            return GridTools.handle(name, arguments, rpcClient)

        // Check window.* tools
        if name starts with "window.":
            return WindowTools.handle(name, arguments, rpcClient)

        // Check query tools (ping, getServerInfo, metadata.get, display.*, dump, mouse.warp, space.focus)
        if QueryTools.canHandle(name):
            return QueryTools.handle(name, arguments, rpcClient)

        // Unknown tool [DW-2.5]
        return CallTool.Result(
            content: [.text("Unknown tool: \(name)")],
            isError: true
        )
```

### GridTools.swift [DW-2.2, DW-2.3]

All grid.* command tools. These map to the grid server's registerGridHandlers RPCs.

```
// GridTools.swift
// MCP tool definitions for grid.* commands

enum GridTools:

    // ---- Tool Definitions ----

    static let definitions: [Tool] = [
        // Focus
        Tool(name: "grid.focus",
             description: "Move focus to an adjacent window in the grid. Direction: left, right, up, down.",
             inputSchema: {
                type: "object",
                properties: {
                    direction: { type: "string", enum: ["left","right","up","down"] },
                    wrap: { type: "boolean", description: "Wrap around edges" },
                    extend: { type: "boolean", description: "Extend selection" }
                },
                required: ["direction"]
             },
             annotations: { readOnlyHint: false, idempotentHint: true }),

        Tool(name: "grid.focus.cycle",
             description: "Cycle focus to the next or previous window in the grid.",
             inputSchema: {
                type: "object",
                properties: {
                    forward: { type: "boolean", description: "true for next, false for previous. Default: true" }
                }
             },
             annotations: { readOnlyHint: false, idempotentHint: true }),

        Tool(name: "grid.focus.cell",
             description: "Focus a specific cell by ID.",
             inputSchema: {
                type: "object",
                properties: {
                    cell: { type: "string", description: "Cell ID to focus" },
                    space: { type: "string", description: "Space ID (default: active space)" }
                },
                required: ["cell"]
             },
             annotations: { readOnlyHint: false, idempotentHint: true }),

        // Layout
        Tool(name: "grid.layout.apply",
             description: "Apply a layout by ID to the active space.",
             inputSchema: {
                type: "object",
                properties: {
                    layout: { type: "string", description: "Layout ID to apply" },
                    strategy: { type: "string", enum: ["position","preserve","autoflow","pinned"], description: "Assignment strategy" }
                },
                required: ["layout"]
             },
             annotations: { readOnlyHint: false }),

        Tool(name: "grid.layout.cycle",
             description: "Cycle to the next layout in the active space.",
             inputSchema: { type: "object", properties: {} },
             annotations: { readOnlyHint: false }),

        Tool(name: "grid.layout.refresh",
             description: "Refresh all layouts, reapplying them to match current state.",
             inputSchema: {
                type: "object",
                properties: {
                    display: { type: "string", description: "Optional display UUID to refresh" }
                }
             },
             annotations: { readOnlyHint: false }),

        Tool(name: "grid.layout.list",
             description: "List all available layout IDs.",
             inputSchema: { type: "object", properties: {} },
             annotations: { readOnlyHint: true }),

        Tool(name: "grid.layout.current",
             description: "Get the current layout and space for the active display.",
             inputSchema: { type: "object", properties: {} },
             annotations: { readOnlyHint: true }),

        Tool(name: "grid.layout.get",
             description: "Get the full definition of a layout including grid, cells, and padding.",
             inputSchema: {
                type: "object",
                properties: {
                    layout: { type: "string", description: "Layout ID" }
                },
                required: ["layout"]
             },
             annotations: { readOnlyHint: true }),

        // Cell
        Tool(name: "grid.cell.send",
             description: "Send the focused window to the adjacent cell in the given direction.",
             inputSchema: {
                type: "object",
                properties: {
                    direction: { type: "string", enum: ["left","right","up","down"] }
                },
                required: ["direction"]
             },
             annotations: { readOnlyHint: false }),

        Tool(name: "grid.cell.mode",
             description: "Set or cycle the stack mode of the focused cell (vertical, horizontal, tabs).",
             inputSchema: {
                type: "object",
                properties: {
                    mode: { type: "string", enum: ["vertical","horizontal","tabs"], description: "Target mode. Omit to cycle." }
                }
             },
             annotations: { readOnlyHint: false }),

        // Window movement
        Tool(name: "grid.window.move",
             description: "Move the focused window to the adjacent cell. Can extend to occupy both cells.",
             inputSchema: {
                type: "object",
                properties: {
                    direction: { type: "string", enum: ["left","right","up","down"] },
                    wrap: { type: "boolean", description: "Wrap around edges" },
                    extend: { type: "boolean", description: "Extend to occupy both cells" }
                },
                required: ["direction"]
             },
             annotations: { readOnlyHint: false }),

        Tool(name: "grid.window.swap",
             description: "Swap the focused window with the window in the adjacent cell.",
             inputSchema: {
                type: "object",
                properties: {
                    direction: { type: "string", enum: ["left","right","up","down"] }
                },
                required: ["direction"]
             },
             annotations: { readOnlyHint: false }),

        // Resize
        Tool(name: "grid.resize.grow",
             description: "Grow the focused split by a given amount (default 0.1).",
             inputSchema: {
                type: "object",
                properties: {
                    amount: { type: "number", description: "Amount to grow (0.0-1.0, default 0.1)" }
                }
             },
             annotations: { readOnlyHint: false }),

        Tool(name: "grid.resize.shrink",
             description: "Shrink the focused split by a given amount (default 0.1).",
             inputSchema: {
                type: "object",
                properties: {
                    amount: { type: "number", description: "Amount to shrink (0.0-1.0, default 0.1)" }
                }
             },
             annotations: { readOnlyHint: false }),

        Tool(name: "grid.resize.cell",
             description: "Adjust a cell boundary in the given direction.",
             inputSchema: {
                type: "object",
                properties: {
                    direction: { type: "string", enum: ["left","right","up","down"] },
                    amount: { type: "number", description: "Amount to adjust (default 0.05)" }
                },
                required: ["direction"]
             },
             annotations: { readOnlyHint: false }),

        Tool(name: "grid.resize.reset",
             description: "Reset splits to equal sizes.",
             inputSchema: {
                type: "object",
                properties: {
                    cell: { type: "boolean", description: "Reset cell ratios instead of splits" },
                    all: { type: "boolean", description: "Reset all cells" }
                }
             },
             annotations: { readOnlyHint: false }),

        // Record (Phase 3 extends these, but tool definitions go here)
        Tool(name: "grid.record.start",
             description: "Start a screen recording.",
             inputSchema: {
                type: "object",
                properties: {
                    target: { type: "string", enum: ["cell","window","screen","all"], description: "What to record (default: cell)" },
                    id: { type: "string", description: "Target ID (cell ID, window ID, screen index)" },
                    format: { type: "string", enum: ["gif","mp4","mov"], description: "Output format" },
                    duration: { type: "integer", description: "Duration in seconds (auto-stops)" },
                    fps: { type: "integer", description: "Frames per second" },
                    width: { type: "integer", description: "Output width in pixels" },
                    quality: { type: "string", enum: ["low","medium","high"], description: "Quality preset" },
                    cursor: { type: "boolean", description: "Show cursor" },
                    output: { type: "string", description: "Output file path" }
                }
             },
             annotations: { readOnlyHint: false }),

        Tool(name: "grid.record.stop",
             description: "Stop the current recording and return the output file path.",
             inputSchema: { type: "object", properties: {} },
             annotations: { readOnlyHint: false }),

        Tool(name: "grid.record.toggle",
             description: "Toggle recording: start if idle, stop if recording.",
             inputSchema: {
                type: "object",
                properties: {
                    target: { type: "string", enum: ["cell","window","screen","all"] },
                    format: { type: "string", enum: ["gif","mp4","mov"] }
                }
             },
             annotations: { readOnlyHint: false }),

        // State
        Tool(name: "grid.state.reset",
             description: "Clear all grid state for the active space.",
             inputSchema: { type: "object", properties: {} },
             annotations: { readOnlyHint: false, destructiveHint: true }),

        Tool(name: "grid.state.show",
             description: "Export the full grid state as JSON (cell assignments, layouts, focus).",
             inputSchema: { type: "object", properties: {} },
             annotations: { readOnlyHint: true }),

        Tool(name: "grid.config.show",
             description: "Export the grid configuration summary.",
             inputSchema: { type: "object", properties: {} },
             annotations: { readOnlyHint: true }),

        // Terminal
        Tool(name: "grid.terminal",
             description: "Toggle the grid terminal overlay.",
             inputSchema: { type: "object", properties: {} },
             annotations: { readOnlyHint: false }),

        // Pick
        Tool(name: "grid.pick",
             description: "Show the app/action picker overlay.",
             inputSchema: { type: "object", properties: {} },
             annotations: { readOnlyHint: false }),

        // Notify
        Tool(name: "grid.notify.toggle",
             description: "Toggle the notification panel.",
             inputSchema: { type: "object", properties: {} },
             annotations: { readOnlyHint: false }),
    ]

    // ---- Dispatch ----

    static func handle(name, arguments, rpcClient) -> CallTool.Result:
        do:
            // All grid.* tools pass through to the grid-server's registered grid.* RPC
            // The RPC method name matches the MCP tool name exactly
            let params = convertValueToDict(arguments)
            let result = try rpcClient.call(name, params: params)
            let json = serializeToJSON(result)
            return CallTool.Result(content: [.text(json)])
        catch RPCError.serverError(_, let msg):
            return CallTool.Result(content: [.text("Error: \(msg)")], isError: true)
        catch:
            return CallTool.Result(content: [.text("RPC failed: \(error)")], isError: true)
```

### WindowTools.swift [DW-2.4]

Window manipulation tools that map to direct RPCs in MessageHandler.

```
// WindowTools.swift
// MCP tool definitions for window.* and related direct RPCs

enum WindowTools:

    static let definitions: [Tool] = [
        Tool(name: "window.find",
             description: "Find a window by app name, title substring, or PID. Returns first match.",
             inputSchema: {
                type: "object",
                properties: {
                    appName: { type: "string", description: "Exact application name" },
                    title: { type: "string", description: "Window title substring" },
                    pid: { type: "integer", description: "Process ID (walks ancestor chain)" }
                }
             },
             annotations: { readOnlyHint: true }),

        Tool(name: "window.focus",
             description: "Focus a specific window by ID (raise and activate).",
             inputSchema: {
                type: "object",
                properties: {
                    windowId: { type: "string", description: "Window ID" }
                },
                required: ["windowId"]
             },
             annotations: { readOnlyHint: false, idempotentHint: true }),

        Tool(name: "window.close",
             description: "Close a window by pressing its close button.",
             inputSchema: {
                type: "object",
                properties: {
                    windowId: { type: "string", description: "Window ID" }
                },
                required: ["windowId"]
             },
             annotations: { readOnlyHint: false, destructiveHint: true }),

        Tool(name: "window.minimize",
             description: "Minimize a window to the dock.",
             inputSchema: {
                type: "object",
                properties: {
                    windowId: { type: "string", description: "Window ID" }
                },
                required: ["windowId"]
             },
             annotations: { readOnlyHint: false }),

        Tool(name: "window.unminimize",
             description: "Restore a minimized window from the dock.",
             inputSchema: {
                type: "object",
                properties: {
                    windowId: { type: "string", description: "Window ID" }
                },
                required: ["windowId"]
             },
             annotations: { readOnlyHint: false }),

        Tool(name: "window.raise",
             description: "Raise a window to front without changing keyboard focus.",
             inputSchema: {
                type: "object",
                properties: {
                    windowId: { type: "string", description: "Window ID" }
                },
                required: ["windowId"]
             },
             annotations: { readOnlyHint: false }),

        Tool(name: "window.show",
             description: "Show a hidden window (unhide and activate).",
             inputSchema: {
                type: "object",
                properties: {
                    windowId: { type: "string", description: "Window ID" }
                },
                required: ["windowId"]
             },
             annotations: { readOnlyHint: false }),

        Tool(name: "window.hide",
             description: "Hide a window (order out or hide app).",
             inputSchema: {
                type: "object",
                properties: {
                    windowId: { type: "string", description: "Window ID" }
                },
                required: ["windowId"]
             },
             annotations: { readOnlyHint: false }),

        Tool(name: "window.setOpacity",
             description: "Set window transparency (0.0 = invisible, 1.0 = opaque).",
             inputSchema: {
                type: "object",
                properties: {
                    windowId: { type: "string", description: "Window ID" },
                    opacity: { type: "number", description: "Opacity value 0.0-1.0" }
                },
                required: ["windowId", "opacity"]
             },
             annotations: { readOnlyHint: false }),

        Tool(name: "window.getOpacity",
             description: "Get current window opacity.",
             inputSchema: {
                type: "object",
                properties: {
                    windowId: { type: "string", description: "Window ID" }
                },
                required: ["windowId"]
             },
             annotations: { readOnlyHint: true }),

        Tool(name: "window.setLayer",
             description: "Set window layer (above/normal/below other windows).",
             inputSchema: {
                type: "object",
                properties: {
                    windowId: { type: "string", description: "Window ID" },
                    layer: { type: "string", enum: ["below","normal","above"] }
                },
                required: ["windowId", "layer"]
             },
             annotations: { readOnlyHint: false }),

        Tool(name: "window.getLayer",
             description: "Get current window layer.",
             inputSchema: {
                type: "object",
                properties: {
                    windowId: { type: "string", description: "Window ID" }
                },
                required: ["windowId"]
             },
             annotations: { readOnlyHint: true }),

        Tool(name: "window.setSticky",
             description: "Make a window appear on all spaces (sticky) or only its current space.",
             inputSchema: {
                type: "object",
                properties: {
                    windowId: { type: "string", description: "Window ID" },
                    sticky: { type: "boolean", description: "true = all spaces, false = current space only" }
                },
                required: ["windowId", "sticky"]
             },
             annotations: { readOnlyHint: false }),

        Tool(name: "window.isSticky",
             description: "Check if a window appears on all spaces.",
             inputSchema: {
                type: "object",
                properties: {
                    windowId: { type: "string", description: "Window ID" }
                },
                required: ["windowId"]
             },
             annotations: { readOnlyHint: true }),
    ]

    static func handle(name, arguments, rpcClient) -> CallTool.Result:
        do:
            // Direct RPC: tool name matches the grid-server method name
            let params = convertValueToDict(arguments)
            let result = try rpcClient.call(name, params: params)
            let json = serializeToJSON(result)
            return CallTool.Result(content: [.text(json)])
        catch RPCError.serverError(_, let msg):
            return CallTool.Result(content: [.text("Error: \(msg)")], isError: true)
        catch:
            return CallTool.Result(content: [.text("RPC failed: \(error)")], isError: true)
```

### QueryTools.swift [DW-2.1]

Read-only query tools: ping, getServerInfo, metadata, displays, dump, space.focus, mouse.warp.

```
// QueryTools.swift
// MCP tool definitions for read-only queries and misc RPCs

enum QueryTools:

    static let definitions: [Tool] = [
        Tool(name: "ping",
             description: "Test connectivity to the grid server. Returns server version.",
             inputSchema: { type: "object", properties: {} },
             annotations: { readOnlyHint: true }),

        Tool(name: "getServerInfo",
             description: "Get server name, version, commit, and capabilities.",
             inputSchema: { type: "object", properties: {} },
             annotations: { readOnlyHint: true }),

        Tool(name: "metadata.get",
             description: "Get cached metadata: focused window ID, active display UUID, active space ID.",
             inputSchema: { type: "object", properties: {} },
             annotations: { readOnlyHint: true }),

        Tool(name: "display.list",
             description: "List all connected displays with frame, resolution, and space info.",
             inputSchema: { type: "object", properties: {} },
             annotations: { readOnlyHint: true }),

        Tool(name: "display.get",
             description: "Get a single display by UUID or the active display.",
             inputSchema: {
                type: "object",
                properties: {
                    uuid: { type: "string", description: "Display UUID" },
                    active: { type: "boolean", description: "Set true to get the active display" }
                }
             },
             annotations: { readOnlyHint: true }),

        Tool(name: "dump",
             description: "Get the complete window manager state (all windows, displays, apps, spaces).",
             inputSchema: { type: "object", properties: {} },
             annotations: { readOnlyHint: true }),

        Tool(name: "space.focus",
             description: "Switch to a specific macOS space by ID.",
             inputSchema: {
                type: "object",
                properties: {
                    spaceId: { type: "string", description: "Space ID" }
                },
                required: ["spaceId"]
             },
             annotations: { readOnlyHint: false }),

        Tool(name: "mouse.warp",
             description: "Warp the mouse cursor to the center of a window.",
             inputSchema: {
                type: "object",
                properties: {
                    windowId: { type: "string", description: "Window ID to warp to" }
                },
                required: ["windowId"]
             },
             annotations: { readOnlyHint: false }),
    ]

    static let handledNames = Set(definitions.map { $0.name })

    static func canHandle(name) -> Bool:
        return handledNames.contains(name)

    static func handle(name, arguments, rpcClient) -> CallTool.Result:
        do:
            let params = convertValueToDict(arguments)
            let result = try rpcClient.call(name, params: params)
            let json = serializeToJSON(result)
            return CallTool.Result(content: [.text(json)])
        catch RPCError.serverError(_, let msg):
            return CallTool.Result(content: [.text("Error: \(msg)")], isError: true)
        catch:
            return CallTool.Result(content: [.text("RPC failed: \(error)")], isError: true)
```

### main.swift modifications [DW-2.1, DW-2.5]

Replace placeholder handlers with ToolRegistry-based dispatch.

```
// main.swift changes:

// Create registry
let registry = ToolRegistry(rpcClient: rpcClient)

// Replace tools/list handler
server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: registry.allTools())
}

// Replace tools/call handler
server.withMethodHandler(CallTool.self) { params in
    return registry.dispatch(name: params.name, arguments: params.arguments)
}
```

### Helper: convertValueToDict

Shared utility to convert MCP `[String: Value]?` to `[String: Any]` for RPCClient.

```
func convertValueToDict(values: [String: Value]?) -> [String: Any]:
    guard let values else: return [:]
    var result: [String: Any] = [:]
    for (key, value) in values:
        switch value:
        case .string(let s): result[key] = s
        case .int(let i): result[key] = i
        case .double(let d): result[key] = d
        case .bool(let b): result[key] = b
        case .null: break
        case .array(let arr): result[key] = arr.map { convertValue($0) }
        case .object(let obj): result[key] = convertValueToDict(obj)
    return result
```

### Helper: serializeToJSON

Convert `[String: Any]` RPC result to JSON string for MCP text content.

```
func serializeToJSON(dict: [String: Any]) -> String:
    let data = JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    return String(data: data, encoding: .utf8) ?? "{}"
```

### Helper: buildInputSchema

Build a `Value` representing a JSON Schema object from property descriptions.

```
// The inputSchema must be a Value.object with "type": "object", "properties": {...}
// Each property is a Value.object with "type", optional "enum", optional "description"
// "required" is a Value.array of strings

func schema(properties: [(name, type, desc, enumValues?, required?)]) -> Value:
    var props: [String: Value] = [:]
    var requiredList: [Value] = []

    for prop in properties:
        var propDict: [String: Value] = ["type": .string(prop.type)]
        if let desc = prop.desc:
            propDict["description"] = .string(desc)
        if let enums = prop.enumValues:
            propDict["enum"] = .array(enums.map { .string($0) })
        props[prop.name] = .object(propDict)
        if prop.required:
            requiredList.append(.string(prop.name))

    var schemaDict: [String: Value] = [
        "type": .string("object"),
        "properties": .object(props)
    ]
    if !requiredList.isEmpty:
        schemaDict["required"] = .array(requiredList)

    return .object(schemaDict)
```

## Design Notes

1. **Single dispatch pattern**: All three tool groups (Grid, Window, Query) use the same pattern: convert MCP Value args to [String: Any], call RPCClient, serialize result as JSON text. This is intentional — the grid-server already handles validation and error messages.

2. **Tool names match RPC method names**: This is the key simplification. `grid.focus` MCP tool calls the `grid.focus` RPC method directly. No translation layer needed. Same for `window.find`, `dump`, etc.

3. **No result transformation**: For Phase 2, results are returned as JSON text. The grid-server already returns well-structured JSON. Phase 3 will add image content for screenshots.

4. **Error propagation**: RPCClient throws `RPCError.serverError` for server-side errors — these get mapped to `isError: true` MCP responses with the server's error message as text content.

5. **Annotations**: Read-only tools get `readOnlyHint: true`, destructive tools get `destructiveHint: true`. This helps Claude Code decide when to auto-approve tool calls.
