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
        // grid.resize.cell: the tool says `amount`, the RPC wants `delta`.
        case resizeCell
        // screencapture + optional in-process downscale, returned as image content.
        case screenshot
        // Forward to the named RPC method and print the result's "outline" as plain text.
        case outline(String)
        // Run several tools in order from one call.
        case batch
        // Poll a window until an expectation holds.
        case wait
    }

    let name: String
    let description: String
    let props: [MCPProp]
    let handler: Handler
    // Actions that change the UI can carry an observation back in the same call.
    let observable: Bool
    // Pointer tools also take image pixels of a screenshot in place of screen points.
    let pixelAddressable: Bool

    init(_ name: String, _ description: String, _ props: [MCPProp] = [], handler: Handler? = nil) {
        self.name = name
        self.description = description
        self.observable = MCPTool.observableTools.contains(name)
        self.pixelAddressable = MCPTool.pixelTools.contains(name)
        self.props = props + (pixelAddressable ? MCPTool.pixelProps(drag: name == "input.mouse.drag") : []) + (observable ? MCPTool.observeProps : [])
        self.handler = handler ?? .rpc(name)
    }

    static let observableTools: Set<String> = [
        "input.mouse.click", "input.mouse.drag", "input.mouse.scroll", "input.key.type", "input.key.press",
        "ui.press", "ui.setValue", "ui.click", "ui.select", "ui.scrollTo", "window.focus", "menu.invoke", "window.pull",
    ]

    static let pixelTools: Set<String> = ["input.mouse.click", "input.mouse.move", "input.mouse.scroll", "input.mouse.drag", "window.at"]

    static func pixelProps(drag: Bool) -> [MCPProp] {
        let shot = opt("shot", .integer, "Which screenshot the pixels belong to (its 'shot' number; default: the latest one)")
        if drag {
            return [opt("fromPx", .number, "Start X in pixels of the screenshot, instead of fromX"), opt("fromPy", .number, "Start Y in pixels of the screenshot"),
                    opt("toPx", .number, "End X in pixels of the screenshot, instead of toX"), opt("toPy", .number, "End Y in pixels of the screenshot"), shot]
        }
        return [opt("px", .number, "X in pixels of the screenshot you are looking at, instead of x: the server converts it"),
                opt("py", .number, "Y in pixels of the screenshot you are looking at, instead of y"), shot]
    }

    static let observeProps: [MCPProp] = [
        opt("observe", .string, "Look at the result in this same call, after settleMs: 'snapshot' (ui.snapshot outline; resets that window's refs) or 'screenshot'. The window is windowId, else the ref's window, else the focused window.", enum: ["snapshot", "screenshot"]),
        opt("settleMs", .integer, "With observe: wait this long for the UI to react first (default: 250)"),
        opt("expectText", .string, "Judge the action by its effect: text that must appear in the target window's accessibility tree afterwards (title, value, description or label; case-insensitive). Polled until timeoutMs; if it never appears the call fails and says so."),
        opt("expectGone", .string, "Text that must no longer be in the target window afterwards (a dialog's button, a row you deleted)"),
        opt("expectTitle", .string, "Text the target window's title must contain afterwards (a page load, a saved document's new name)"),
        opt("timeoutMs", .integer, "How long to wait for expect* to hold (default: 3000)"),
    ]

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
        opt("amount", .number, "Amount to adjust as fraction (default: 0.05; negative shrinks)"),
    ], handler: .resizeCell),
    MCPTool("grid.resize.reset", "Reset split ratios to equal sizes.", [
        opt("all", .boolean, "Reset all cells, not just the focused one"),
        opt("cell", .boolean, "Reset cell ratios instead of window splits"),
    ]),
    MCPTool("grid.screenshot", "Capture a screenshot and return it as an inline image Claude can view, plus a JSON block with the captured region in screen points (frame) and the image's pixel size (image) for mapping pixels to input.* coordinates: x = frame.x + px * frame.width / image.width. Targets: 'full' (one display), 'window' (specific window by ID), 'cell' (grid cell by ID — captures the focused window in that cell), 'region' (a rect in global screen points — zoom into part of a wide display).", [
        opt("target", .string, "What to capture: 'full', 'window', 'cell', or 'region' (default: full)", enum: ["full", "window", "cell", "region"]),
        opt("id", .string, "Window ID for target=window, or cell ID for target=cell"),
        opt("x", .number, "Region left edge in screen points (target=region)"),
        opt("y", .number, "Region top edge in screen points (target=region)"),
        opt("width", .number, "Region width in screen points (target=region)"),
        opt("height", .number, "Region height in screen points (target=region)"),
        opt("cursor", .boolean, "Include cursor (full screen only)"),
        opt("display", .integer, "Display index, 0-based, in display.list order (full screen only; default: the active display)"),
        opt("settleMs", .integer, "Wait this many milliseconds before capturing"),
        opt("waitTitle", .string, "target=window: wait until the window title contains this text (page loaded, document opened) before capturing; the result reports titleMatched"),
        opt("waitStable", .boolean, "Wait until two frames 150 ms apart look the same before capturing (tolerates a blinking caret); the result reports stable"),
        opt("timeoutMs", .integer, "Ceiling for waitTitle / waitStable (default: 5000)"),
        opt("quality", .string, "Quality preset: 'low' (default, long edge <=1568px JPEG), 'high' (full resolution; PNG, or JPEG when the PNG would be too large to send)", enum: ["low", "high"]),
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
    MCPTool("window.find", "Find windows by app name, title substring, or process ID. Returns every visible match in `matches` (windowId, title, appName, frame) — check the titles when an app has several windows or profiles; windowId at the top level is only the first of them.", [
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
    MCPTool("window.at", "The window a click at this point would reach (the frontmost one there), which is not necessarily the one you screenshotted.", [
        opt("x", .number, "X in screen points"),
        opt("y", .number, "Y in screen points"),
    ]),
    MCPTool("mouse.warp", "Warp the mouse cursor to the center of a window.", [
        req("windowId", .string, "Window ID to warp cursor to"),
    ]),
    MCPTool("pick.show", "Show the app/action picker overlay and return the user's selection."),

    // Input tools. Coordinates are global screen points (top-left origin),
    // the same space display and window frames use -- not screenshot pixels.
    MCPTool("input.mouse.position", "Get the current mouse position in global screen points."),
    MCPTool("input.mouse.move", "Move the mouse to a point: x/y in global screen points (top-left origin), or px/py in pixels of your last screenshot.", [
        opt("x", .number, "X in screen points"),
        opt("y", .number, "Y in screen points"),
    ]),
    MCPTool("input.mouse.click", "Click at a point: x/y in global screen points, or px/py in pixels of the screenshot you are looking at (no arithmetic needed), or the current mouse position when neither is given. Use count=2 for a double-click. A click goes to whatever window is on top at that point, which may not be the window you screenshotted: pass windowId.", [
        opt("x", .number, "X in screen points"),
        opt("y", .number, "Y in screen points"),
        opt("button", .string, "Mouse button (default: left)", enum: ["left", "right", "middle"]),
        opt("count", .integer, "Click count (default: 1; 2 = double-click)"),
        opt("modifiers", .string, "Modifiers held during the click, e.g. 'cmd' or 'cmd+shift'"),
        opt("windowId", .string, "Window the pointer must reach: it is raised and focused first, and nothing is posted if another app's window covers the point"),
    ]),
    MCPTool("input.mouse.drag", "Press at one point, move in steps, release at another. Global screen points.", [
        opt("fromX", .number, "Start X in screen points"),
        opt("fromY", .number, "Start Y in screen points"),
        opt("toX", .number, "End X in screen points"),
        opt("toY", .number, "End Y in screen points"),
        opt("button", .string, "Mouse button (default: left)", enum: ["left", "right", "middle"]),
        opt("steps", .integer, "Intermediate move events (default: 12)"),
        opt("modifiers", .string, "Modifiers held during the drag, e.g. 'alt'"),
        opt("windowId", .string, "Window the pointer must reach: it is raised and focused first, and nothing is posted if another app's window covers the point (checked at the start point)"),
    ]),
    MCPTool("input.mouse.scroll", "Scroll by pixel deltas at a point (or the current mouse position). Positive dy scrolls content up (toward the top), negative dy scrolls down.", [
        opt("x", .number, "X in screen points"),
        opt("y", .number, "Y in screen points"),
        opt("dx", .integer, "Horizontal pixels (default: 0)"),
        opt("dy", .integer, "Vertical pixels (default: 0)"),
        opt("modifiers", .string, "Modifiers held while scrolling"),
        opt("windowId", .string, "Window the pointer must reach: it is raised and focused first, and nothing is posted if another app's window covers the point"),
    ]),
    MCPTool("input.key.type", "Type literal text into the focused window. Modifiers are cleared, so text never triggers shortcuts; use input.key.press for chords like cmd+s or enter. Pass windowId to focus that window first; focus is confirmed with the OS before posting and again before every 5-character chunk, and typing stops the moment it is lost.", [
        req("text", .string, "Text to type"),
        opt("allowSecure", .boolean, "With windowId: typing is refused when the caret is in a password field unless this is true"),
        opt("windowId", .string, "Window that must hold keyboard focus; it is focused and verified first, and nothing is typed if that fails"),
    ]),
    MCPTool("input.key.press", "Press a key or chord in the focused window: 'enter', 'escape', 'tab', 'cmd+s', 'cmd+shift+t', 'ctrl+c'. Modifiers: cmd, alt/opt, ctrl, shift, fn. Pass windowId to focus that window first; focus is confirmed with the OS before posting and again before every repeat, and pressing stops the moment it is lost.", [
        req("key", .string, "Key or chord, modifiers joined with '+'"),
        opt("count", .integer, "Repeat count (default: 1, max: 100)"),
        opt("windowId", .string, "Window that must hold keyboard focus; it is focused and verified first, and nothing is pressed if that fails"),
    ]),

    MCPTool("batch", "Run several tools in order in one call and stop at the first failure. Use for sequences that need no look in between (click a field, type, press enter); put observe on the last step to see the outcome.", [
        req("steps", .string, "JSON array string of steps: [{\"tool\":\"ui.click\",\"args\":{\"ref\":\"7:3\"}},{\"tool\":\"input.key.type\",\"args\":{\"text\":\"hi\",\"windowId\":\"7\",\"observe\":\"snapshot\"}}] (max 20)"),
    ], handler: .batch),

    // UI tools: the window's accessibility tree. Reads text and finds controls
    // without a screenshot; refs live until the next full snapshot of that window.
    MCPTool("ui.snapshot", "Read a window's accessibility tree as a text outline, one node per line: [ref] role \"title\" value=… desc=… (x,y WxH in global screen points) and flags (press, focused, disabled). Prefer this over a screenshot for reading text and locating controls. Pass ref instead of windowId to expand one subtree when the outline was truncated.", [
        opt("windowId", .string, "Window ID to snapshot"),
        opt("ref", .string, "Snapshot only this node's subtree (keeps existing refs valid)"),
        opt("includeOffscreen", .boolean, "Also list content scrolled out of view, flagged 'offscreen' (then ui.scrollTo it)"),
        opt("maxNodes", .integer, "Node budget (default: 400, max: 2000)"),
        opt("maxDepth", .integer, "Depth limit (default: 30)"),
    ], handler: .outline("ui.snapshot")),
    MCPTool("ui.query", "Find nodes instead of reading the whole outline: the same walk as ui.snapshot, returning only matches (flat, with refs you can act on). Give any of role ('button' or 'AXButton'), text (case-insensitive substring of title, value, description or borrowed label), pressable. Looks at offscreen content too. Use this whenever you know what you are looking for.", [
        req("windowId", .string, "Window ID to search"),
        opt("role", .string, "Role or subrole, with or without the AX prefix: button, textfield, row, checkbox, AXSwitch"),
        opt("text", .string, "Case-insensitive substring to find in a node's title, value, description or label"),
        opt("pressable", .boolean, "Only nodes that can (true) or cannot (false) be pressed"),
        opt("limit", .integer, "Maximum matches to return (default: 20)"),
    ], handler: .outline("ui.query")),
    MCPTool("ui.wait", "Wait until a window shows some text, stops showing it, or has a title — instead of sleeping and looking. Returns as soon as every given expectation holds; fails with which one did not at timeoutMs.", [
        req("windowId", .string, "Window to watch"),
        opt("expectText", .string, "Text that must appear in the window's accessibility tree"),
        opt("expectGone", .string, "Text that must no longer be there"),
        opt("expectTitle", .string, "Text the window's title must contain"),
        opt("timeoutMs", .integer, "Give up after this long (default: 3000, max: 30000)"),
    ], handler: .wait),
    MCPTool("ui.value", "Read one node's full value by ref. The outline clips values at 120 characters; use this for a whole text field or document (capped at 64 KB).", [
        req("ref", .string, "Node ref from ui.snapshot"),
    ]),
    MCPTool("ui.press", "Press a control by ref via accessibility (AXPress). Does not move the cursor, and ordinary buttons do not take keyboard focus from the user; opening a menu or pop-up does activate that app. Works on nodes flagged 'press'; if it fails, use ui.click.", [
        req("ref", .string, "Node ref from ui.snapshot"),
    ]),
    MCPTool("ui.select", "Select a table row, list item or tab by ref (AXSelected), as a click on it would, without the pointer or keyboard focus.", [
        req("ref", .string, "Node ref from ui.snapshot"),
    ]),
    MCPTool("ui.scrollTo", "Scroll a node's container until the node is visible. Refs for hidden content come from ui.snapshot with includeOffscreen=true.", [
        req("ref", .string, "Node ref from ui.snapshot"),
    ]),
    MCPTool("ui.setValue", "Set a control's value by ref via accessibility. Text replaces a field's whole value; numbers work on sliders, scroll bars (0-1), checkboxes and disclosure triangles (0/1) — use this when a node is not flagged 'press'.", [
        req("ref", .string, "Node ref from ui.snapshot"),
        req("value", .string, "New value"),
        opt("allowSecure", .boolean, "Writing to a password field is refused unless this is true"),
    ]),
    MCPTool("ui.click", "Click the center of a node's current frame with a synthesized mouse click. Use when ui.press is not supported; this moves the cursor. The ref's window is raised and focused first, and the click is refused if another app's window still covers the point.", [
        req("ref", .string, "Node ref from ui.snapshot"),
        opt("button", .string, "Mouse button (default: left)", enum: ["left", "right", "middle"]),
        opt("count", .integer, "Click count (default: 1; 2 = double-click)"),
    ]),

    // Clipboard tools. Text only. The clipboard is the user's: read before writing and give it back.
    MCPTool("clip.read", "Read the clipboard as text: { changeCount, types, hasText, text, bytes }. At most 64 KB of text is returned; a longer clipboard comes back cut, with truncated=true, bytes (the full size) and returnedBytes. changeCount goes up every time anything changes the clipboard: compare it with an earlier read or with clip.write's result to tell whether a copy (cmd+c, a menu's Copy) really happened. REFUSED when the clipboard is marked concealed or transient (org.nspasteboard.ConcealedType / TransientType): that is how password managers mark secrets, and the refusal is not to be worked around. Images and files are reported in types but not read.", [
        opt("type", .string, "Only 'text' in this version (default)", enum: ["text"]),
    ]),
    MCPTool("clip.write", "Replace the clipboard with text (up to 1 MB) and return { changeCount, previousChangeCount, bytes }. This destroys what the user had copied, of every type: clip.read first, and clip.write their text back when you are done if it was text. Use it to paste long or exact text (then input.key.press cmd+v with windowId) where typing would be slow or an app mangles keystrokes.", [
        req("text", .string, "Text to put on the clipboard"),
    ]),

    // Space tools. Both actions read their effect back and fail when the window server ignored them.
    MCPTool("space.list", "List every display's spaces (desktops) and the windows on each: per display its uuid, frame, isActive and currentSpaceId; per space its id, index, type ('user' or 'fullscreen'), isCurrent and windows (windowId, appName, title). Read-only. Use it when a window is 'not reachable through accessibility' or will not focus: it is probably on a space where isCurrent is false. A 'fullscreen' space is a video, a presentation or a fullscreen app: leave it alone."),
    MCPTool("space.switch", "Show another space on its display: the space's own display switches, other displays are untouched. REFUSED when that display is currently showing a fullscreen space (switching would take the user's video or fullscreen app off screen) unless leaveFullscreen=true, which you pass only when the user asked for exactly that. Only 'user' spaces can be targets. The result is read back from the window server: the call fails if the space did not become current, so a success is real. Afterwards windows on that space are reachable by ui.* and window.focus.", [
        req("spaceId", .string, "Space id from space.list"),
        opt("leaveFullscreen", .boolean, "Override the refusal for a display that is showing a fullscreen space. Only when the user explicitly asked to leave it."),
    ]),
    MCPTool("window.pull", "Bring a window from another space to the current space of the active display, without switching spaces. REFUSED for a window that is on a fullscreen space, and when the active display is itself showing a fullscreen space; nothing is ever pulled off or onto one. The move is read back: the call fails if the window is still where it was (recent macOS ignores this move for windows on a space that is not visible; then use space.switch to go to the window instead). Does not focus the window: follow with window.focus.", [
        req("windowId", .string, "Window ID to bring here (from space.list or window.find)"),
    ]),

    // Menu tools: the app's menu bar as an index of commands. Reading opens nothing.
    MCPTool("menu.snapshot", "List every command in an app's menu bar, one line each, without opening a menu or activating the app: `File > Export As > PDF…  [cmd+shift+P]  enabled`. The bracket is the keyboard shortcut in input.key.press syntax; flags are enabled/disabled and checked. Use it to learn what an app can do and to find a command's exact path for menu.invoke. A few hundred lines for a big app: pass text. An app in the background reports its document commands (Save, Select All) disabled because it has no key window; menu.invoke brings it forward and checks again. The Apple menu is left out.", [
        opt("app", .string, "App name as window.find shows it ('TextEdit', any case) or bundle identifier. Give this or windowId."),
        opt("windowId", .string, "Any window of the app"),
        opt("text", .string, "Case-insensitive substring of the path or the shortcut: 'export', 'view > ', 'cmd+shift'"),
        opt("enabled", .boolean, "Only commands that are enabled (true) or disabled (false) right now"),
        opt("limit", .integer, "Maximum lines to return (default: 1000)"),
    ], handler: .outline("menu.snapshot")),
    MCPTool("menu.invoke", "Run a menu command by its path, e.g. 'File > Export As > PDF…'. This ACTIVATES the app (it takes keyboard focus from the user): with windowId that window is focused first, so document commands act on it; with app alone the app comes forward with whatever window it had. Matching ignores case, treats '…' and '...' alike, and lets you leave a trailing ellipsis off. No menu is opened on screen and the cursor does not move. Disabled commands and submenus are refused, and a wrong path answers with the items that do exist at that level. A success means the press was delivered: state the effect you expect with expectText / expectGone / expectTitle (they need windowId).", [
        req("path", .string, "Menu path from menu.snapshot, segments joined with '>': 'Edit > Find > Find…'"),
        opt("app", .string, "App name or bundle identifier. Give this or windowId."),
        opt("windowId", .string, "The window the command should act on; it is focused and verified first"),
    ]),
]

let mcpToolsByName: [String: MCPTool] = Dictionary(uniqueKeysWithValues: mcpTools.map { ($0.name, $0) })
