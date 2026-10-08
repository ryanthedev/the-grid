import Foundation

// The MCP tool surface exposed by `thegrid mcp serve`. Tool names match the
// grid-server RPC method they wrap unless a handler says otherwise.

enum MCPPropType: String {
    case string
    case number
    case integer
    case boolean
}

struct MCPProp {
    let name: String
    let type: MCPPropType
    let description: String
    let enumValues: [String]?
    let required: Bool

    var schema: [String: Any] {
        var out: [String: Any] = ["type": type.rawValue, "description": description]
        if let enumValues {
            out["enum"] = enumValues
        }
        return out
    }
}

func req(_ name: String, _ type: MCPPropType, _ description: String, enum enumValues: [String]? = nil) -> MCPProp {
    MCPProp(name: name, type: type, description: description, enumValues: enumValues, required: true)
}

func opt(_ name: String, _ type: MCPPropType, _ description: String, enum enumValues: [String]? = nil) -> MCPProp {
    MCPProp(name: name, type: type, description: description, enumValues: enumValues, required: false)
}

struct MCPTool {
    enum Handler {
        // Forward args verbatim to the named RPC method.
        case rpc(String)
        // grid.resize.adjust with a signed delta.
        case resize(sign: Double)
        // screencapture + optional sips downscale, returned as image content.
        case screenshot
    }

    let name: String
    let description: String
    let props: [MCPProp]
    let handler: Handler

    init(_ name: String, _ description: String, _ props: [MCPProp] = [], handler: Handler? = nil) {
        self.name = name
        self.description = description
        self.props = props
        self.handler = handler ?? .rpc(name)
    }

    var definition: [String: Any] {
        var properties: [String: Any] = [:]
        for p in props {
            properties[p.name] = p.schema
        }
        var schema: [String: Any] = ["type": "object", "properties": properties]
        let required = props.filter { $0.required }.map { $0.name }
        if !required.isEmpty {
            schema["required"] = required
        }
        return ["name": name, "description": description, "inputSchema": schema]
    }
}

let direction = ["left", "right", "up", "down"]

let mcpTools: [MCPTool] = [
    // Grid tools
    MCPTool("grid.focus", "Move focus to an adjacent window in the grid.", [
        req("direction", .string, "Direction to move focus", enum: direction),
        opt("wrap", .boolean, "Wrap around grid edges"),
        opt("extend", .boolean, "Extend selection to additional cell"),
    ]),
    MCPTool("grid.focus.cycle", "Cycle focus to the next or previous window in the grid.", [
        opt("forward", .boolean, "true for next, false for previous (default: true)"),
    ]),
    MCPTool("grid.focus.cell", "Focus a specific grid cell by ID.", [
        req("cell", .string, "Cell ID to focus"),
        opt("space", .string, "Space ID (default: active space)"),
    ]),
    MCPTool("grid.layout.apply", "Apply a named layout to the active space, arranging all windows into the grid.", [
        req("layout", .string, "Layout ID to apply (e.g. 'tall-wide', 'even-3col')"),
        opt("strategy", .string, "Window assignment strategy", enum: ["position", "preserve", "autoflow", "pinned"]),
    ]),
    MCPTool("grid.layout.cycle", "Cycle to the next layout in the configured layout list."),
    MCPTool("grid.layout.list", "List all available layout IDs. Use grid.layout.get to see a layout's full definition."),
    MCPTool("grid.layout.current", "Get the current layout ID and space ID for the active display."),
    MCPTool("grid.layout.get", "Get the full definition of a layout: grid dimensions, cell positions, padding, and stack modes.", [
        req("layout", .string, "Layout ID"),
    ]),
    MCPTool("grid.layout.refresh", "Reapply current layouts to all displays, snapping windows back to their grid cells.", [
        opt("display", .string, "Display UUID to refresh (default: all displays)"),
    ]),
    MCPTool("grid.cell.send", "Send the focused window to the adjacent cell in the given direction.", [
        req("direction", .string, "Direction to send", enum: direction),
    ]),
    MCPTool("grid.cell.mode", "Set or cycle the stack mode of the focused cell. Modes: vertical (split top/bottom), horizontal (split left/right), tabs (tabbed).", [
        opt("mode", .string, "Target mode, or omit to cycle", enum: ["vertical", "horizontal", "tabs"]),
    ]),
    MCPTool("grid.window.move", "Move the focused window to the adjacent cell. With extend, the window spans both cells.", [
        req("direction", .string, "Direction to move", enum: direction),
        opt("wrap", .boolean, "Wrap around grid edges"),
        opt("extend", .boolean, "Extend window to span both source and target cells"),
    ]),
    MCPTool("grid.window.swap", "Swap the focused window with the window in the adjacent cell.", [
        req("direction", .string, "Direction of cell to swap with", enum: direction),
    ]),
    MCPTool("grid.resize.grow", "Grow the focused window's split ratio.", [
        opt("amount", .number, "Amount to grow as fraction (default: 0.1, range 0.0-1.0)"),
    ], handler: .resize(sign: 1)),
    MCPTool("grid.resize.shrink", "Shrink the focused window's split ratio.", [
        opt("amount", .number, "Amount to shrink as fraction (default: 0.1, range 0.0-1.0)"),
    ], handler: .resize(sign: -1)),
    MCPTool("grid.resize.cell", "Adjust a cell boundary in the given direction.", [
        req("direction", .string, "Direction of boundary to adjust", enum: direction),
        opt("amount", .number, "Amount to adjust as fraction (default: 0.05)"),
    ]),
    MCPTool("grid.resize.reset", "Reset split ratios to equal sizes.", [
        opt("all", .boolean, "Reset all cells, not just the focused one"),
        opt("cell", .boolean, "Reset cell ratios instead of window splits"),
    ]),
    MCPTool("grid.screenshot", "Capture a screenshot and return it as an inline image Claude can view, plus a JSON block with the captured region in screen points (frame) and the image's pixel size (image) for mapping pixels to input.* coordinates: x = frame.x + px * frame.width / image.width. Targets: 'full' (one display), 'window' (specific window by ID), 'cell' (grid cell by ID — captures the focused window in that cell).", [
        opt("target", .string, "What to capture: 'full', 'window', or 'cell' (default: full)", enum: ["full", "window", "cell"]),
        opt("id", .string, "Window ID for target=window, or cell ID for target=cell"),
        opt("cursor", .boolean, "Include cursor (full screen only)"),
        opt("display", .integer, "Display index, 0-based, in display.list order (full screen only; default: the active display)"),
        opt("quality", .string, "Quality preset: 'low' (default, <=1024px JPEG), 'high' (full-res PNG)", enum: ["low", "high"]),
    ], handler: .screenshot),
    MCPTool("grid.record.start", "Start a screen recording of a cell, window, display, or all screens.", [
        opt("target", .string, "What to record", enum: ["cell", "window", "screen", "all"]),
        opt("id", .string, "Target ID (cell ID, window ID, or screen index)"),
        opt("output", .string, "Output file path"),
        opt("format", .string, "Output format", enum: ["gif", "mp4", "mov"]),
        opt("fps", .integer, "Frames per second"),
        opt("quality", .string, "Quality preset", enum: ["low", "medium", "high"]),
        opt("duration", .integer, "Auto-stop after N seconds"),
        opt("cursor", .boolean, "Include cursor in recording"),
        opt("width", .integer, "Output width in pixels"),
    ]),
    MCPTool("grid.record.stop", "Stop the active recording and return the output file path."),
    MCPTool("grid.record.toggle", "Toggle recording: start if idle, stop if recording. Returns recording result on stop.", [
        opt("target", .string, "What to record", enum: ["cell", "window", "screen", "all"]),
        opt("format", .string, "Output format", enum: ["gif", "mp4", "mov"]),
    ]),
    MCPTool("grid.config.show", "Export the grid configuration summary: layouts, spacing, settings."),
    MCPTool("grid.state.show", "Export the full grid state: cell assignments, current layouts, focus tracking per space."),
    MCPTool("grid.state.reset", "Clear all grid state for the active space (cell assignments, layout, focus tracking)."),
    MCPTool("grid.terminal", "Toggle the grid terminal overlay."),

    // Window tools
    MCPTool("window.find", "Find a window by app name, title substring, or process ID. Returns the first visible match with its window ID.", [
        opt("appName", .string, "Exact application name (e.g. 'Safari', 'Terminal')"),
        opt("title", .string, "Window title substring to match"),
        opt("pid", .integer, "Process ID (walks ancestor chain to find owning window)"),
    ]),
    MCPTool("window.focus", "Focus a specific window by ID: raise it to front and activate its application.", [
        req("windowId", .string, "Window ID to focus"),
    ]),
    MCPTool("window.close", "Close a window by pressing its close button via accessibility.", [
        req("windowId", .string, "Window ID to close"),
    ]),
    MCPTool("window.minimize", "Minimize a window to the dock.", [
        req("windowId", .string, "Window ID to minimize"),
    ]),
    MCPTool("window.unminimize", "Restore a minimized window from the dock.", [
        req("windowId", .string, "Window ID to restore"),
    ]),
    MCPTool("window.raise", "Raise a window to front without changing keyboard focus.", [
        req("windowId", .string, "Window ID to raise"),
    ]),
    MCPTool("window.show", "Show a hidden window: unhide its application and bring the window to front.", [
        req("windowId", .string, "Window ID to show"),
    ]),
    MCPTool("window.hide", "Hide a window (order it out or hide its application).", [
        req("windowId", .string, "Window ID to hide"),
    ]),

    // Query tools
    MCPTool("ping", "Test connectivity to the grid server. Returns server version and timestamp."),
    MCPTool("getServerInfo", "Get grid server name, version, commit hash, and capabilities."),
    MCPTool("metadata.get", "Get cached window manager metadata: focused window ID, active display UUID, active space ID, last update time."),
    MCPTool("display.list", "List all connected displays with their UUID, name, frame, visible frame, scale factor, and current space."),
    MCPTool("display.get", "Get a single display by UUID, or the currently active display.", [
        opt("uuid", .string, "Display UUID"),
        opt("active", .boolean, "Set true to get the currently active display"),
    ]),
    MCPTool("dump", "Get the complete window manager state: all windows (with frame, app, title, spaces), all displays, all apps. Large response."),
    MCPTool("mouse.warp", "Warp the mouse cursor to the center of a window.", [
        req("windowId", .string, "Window ID to warp cursor to"),
    ]),
    MCPTool("pick.show", "Show the app/action picker overlay and return the user's selection."),

    // Input tools. Coordinates are global screen points (top-left origin),
    // the same space display and window frames use -- not screenshot pixels.
    MCPTool("input.mouse.position", "Get the current mouse position in global screen points."),
    MCPTool("input.mouse.move", "Move the mouse to a point in global screen points (top-left origin). Convert screenshot pixels with the frame/image block grid.screenshot returns.", [
        req("x", .number, "X in screen points"),
        req("y", .number, "Y in screen points"),
    ]),
    MCPTool("input.mouse.click", "Click at a point in global screen points, or at the current mouse position when x/y are omitted. Use count=2 for a double-click.", [
        opt("x", .number, "X in screen points"),
        opt("y", .number, "Y in screen points"),
        opt("button", .string, "Mouse button (default: left)", enum: ["left", "right", "middle"]),
        opt("count", .integer, "Click count (default: 1; 2 = double-click)"),
        opt("modifiers", .string, "Modifiers held during the click, e.g. 'cmd' or 'cmd+shift'"),
    ]),
    MCPTool("input.mouse.drag", "Press at one point, move in steps, release at another. Global screen points.", [
        req("fromX", .number, "Start X in screen points"),
        req("fromY", .number, "Start Y in screen points"),
        req("toX", .number, "End X in screen points"),
        req("toY", .number, "End Y in screen points"),
        opt("button", .string, "Mouse button (default: left)", enum: ["left", "right", "middle"]),
        opt("steps", .integer, "Intermediate move events (default: 12)"),
        opt("modifiers", .string, "Modifiers held during the drag, e.g. 'alt'"),
    ]),
    MCPTool("input.mouse.scroll", "Scroll by pixel deltas at a point (or the current mouse position). Positive dy scrolls content up (toward the top), negative dy scrolls down.", [
        opt("x", .number, "X in screen points"),
        opt("y", .number, "Y in screen points"),
        opt("dx", .integer, "Horizontal pixels (default: 0)"),
        opt("dy", .integer, "Vertical pixels (default: 0)"),
        opt("modifiers", .string, "Modifiers held while scrolling"),
    ]),
    MCPTool("input.key.type", "Type literal text into the focused window. Modifiers are cleared, so text never triggers shortcuts; use input.key.press for chords like cmd+s or enter.", [
        req("text", .string, "Text to type"),
    ]),
    MCPTool("input.key.press", "Press a key or chord in the focused window: 'enter', 'escape', 'tab', 'cmd+s', 'cmd+shift+t', 'ctrl+c'. Modifiers: cmd, alt/opt, ctrl, shift, fn.", [
        req("key", .string, "Key or chord, modifiers joined with '+'"),
        opt("count", .integer, "Repeat count (default: 1)"),
    ]),
]

let mcpToolsByName: [String: MCPTool] = Dictionary(uniqueKeysWithValues: mcpTools.map { ($0.name, $0) })
