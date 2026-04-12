# Discovery: Phase 2 - MCP Tool Definitions + Dispatch

## Files Found
- `grid-mcp/Sources/GridMCP/main.swift` — MCP server entry point with placeholder ListTools/CallTool handlers
- `grid-mcp/Sources/GridMCP/RPCClient.swift` — Unix socket RPC client (call method returns `[String: Any]`)
- `grid-mcp/Package.swift` — Package definition with MCP SDK 0.12.0+ dependency
- `grid-server/Sources/GridServer/MessageHandler.swift` — All direct RPC handlers (ping, getServerInfo, metadata.get, display.*, window.*, space.*, mouse.*, borders.*)
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` — Grid command dispatch (focus, layout, cell, window, resize, record, terminal, notify, pick, state, nudge)
- `grid-server/Sources/GridServer/MessageHandler.swift:1377-1908` — Grid RPC handlers (grid.focus, grid.layout.*, grid.cell.*, grid.window.*, grid.resize.*, grid.record.*, grid.terminal, grid.state.*, grid.config.*)

## Current State

### Phase 1 Complete
- MCP server starts on stdio, responds to `initialize`
- RPCClient connects to grid-server via Unix socket
- Placeholder `tools/list` returns empty array
- Placeholder `tools/call` only handles "ping"

### Grid Server RPC Surface (what we need to expose)

**Direct RPCs (MessageHandler):**
- `ping` — echo
- `getServerInfo` — server version/capabilities
- `metadata.get` — cached metadata (focused window, active display/space)
- `display.list` — all connected displays
- `display.get` — single display by UUID or active
- `window.find` — search windows by appName/title/pid
- `dump` — complete window manager state
- `window.focus` — focus a specific window by ID
- `window.close` — close a window
- `window.minimize` / `window.unminimize` — minimize/unminimize
- `window.raise` — raise without focus
- `window.show` / `window.hide` — show/hide
- `window.setOpacity` / `window.getOpacity` / `window.fadeOpacity` — opacity
- `window.setLayer` / `window.getLayer` — layer (above/normal/below)
- `window.setSticky` / `window.isSticky` — sticky across spaces
- `space.focus` — focus a space
- `mouse.warp` — warp cursor to window center

**Grid RPCs (registered via registerGridHandlers):**
- `grid.focus` — directional focus (left/right/up/down, flags: wrap/extend/mouse)
- `grid.focus.cycle` — cycle focus next/prev
- `grid.focus.cell` — focus a specific cell
- `grid.layout.apply` — apply layout by ID
- `grid.layout.cycle` — cycle to next layout
- `grid.layout.refresh` — refresh layouts
- `grid.layout.current` — get current layout+space
- `grid.layout.list` — list available layout IDs
- `grid.layout.get` — get layout definition
- `grid.cell.send` — send window to adjacent cell
- `grid.cell.mode` — set/cycle cell stack mode
- `grid.window.move` — move window between cells
- `grid.window.swap` — swap windows between cells
- `grid.resize.adjust` — grow/shrink focused split
- `grid.resize.cell` — adjust cell boundary
- `grid.resize.reset` — reset splits to equal
- `grid.record.start` / `grid.record.stop` / `grid.record.toggle` — recording
- `grid.terminal` — toggle terminal
- `grid.state.reset` — reset grid state
- `grid.state.show` — export grid state
- `grid.config.show` — export config summary

### Excluded per plan
- `grid.nudge.*` (interactive key hold session)
- `borders.*` (internal rendering detail)
- `space.create/destroy` (destructive, rarely needed)

## Gaps
- No `Tools/` directory exists yet — needs to be created
- Phase 1's CallTool handler is a flat switch in main.swift — needs to be replaced with a proper dispatch system
- The MCP SDK's `Value` enum is used for inputSchema (not JSON Schema strings) — need to construct `Value.object(...)` for each tool's schema
- RPCClient.call returns `[String: Any]` — need to serialize as JSON string for MCP text content

## Prerequisites
- [x] Phase 1 complete (MCP server starts, RPCClient works)
- [x] MCP SDK available (0.12.0+)
- [x] Grid server RPC surface documented above
- [x] Swift 6.1+ (confirmed in Package.swift)

## Recommendation
BUILD — All prerequisites met, clear mapping from Grid RPCs to MCP tools.
