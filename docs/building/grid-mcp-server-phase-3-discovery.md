# Discovery: Phase 3 - Screenshot + Recording Tools

## Files Found

### Existing (grid-mcp)
- `grid-mcp/Sources/GridMCP/Tools/GridTools.swift` — contains `grid.record.start/stop/toggle` tool definitions and dispatch via `callRPC`
- `grid-mcp/Sources/GridMCP/Tools/ToolRegistry.swift` — dispatch router; `grid.*` prefix routes to GridTools; helpers `callRPC`, `serializeResult`, `convertValueToDict`
- `grid-mcp/Sources/GridMCP/Tools/QueryTools.swift` — `dump`, `metadata.get`, `display.list` tools (needed to resolve cell bounds)
- `grid-mcp/Sources/GridMCP/RPCClient.swift` — synchronous Unix socket RPC client
- `grid-mcp/Sources/GridMCP/main.swift` — MCP server entry

### Existing (grid-server — for understanding, not modifying)
- `grid-server/Sources/GridServer/Grid/GridRecorder.swift` — uses `screencapture -v` (video only, no PNG path)
- `grid-server/Sources/GridServer/MessageHandler.swift` — registers `grid.record.start/stop/toggle` RPC methods
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` — parses record commands, delegates to GridRecorder

### MCP SDK
- `.build/checkouts/swift-sdk/Sources/MCP/Server/Tools.swift` — confirms `Tool.Content.image(data: String, mimeType: String, annotations:, _meta:)` is the correct type

## Current State

**grid.record.start/stop/toggle:** Already fully implemented as tool stubs in GridTools.swift. They dispatch through `callRPC` which forwards to grid-server. The grid-server has registered RPC handlers for all three. These tools are working — no changes needed.

**grid.screenshot:** Does NOT exist yet. This is a new tool that:
- Has no backing RPC (grid-server has no PNG screenshot path)
- Must be implemented entirely in grid-mcp, using `screencapture` directly
- Must return `Tool.Content.image(data: base64, mimeType: "image/png", ...)`

**ToolRegistry dispatch:** Routes `grid.*` to `GridTools.handle()`. Since `grid.screenshot` will be a `grid.*` tool, it goes through `GridTools.handle()` — which currently falls through to `callRPC`. This will fail for `grid.screenshot` since there's no server RPC. Need to intercept it before the `callRPC` fallthrough.

## Recording Tool Verification

The grid-server RPC handlers for recording:
- `grid.record.start`: parses target, id, format, fps, width, quality, output, cursor flags → builds command string → routes through `GridCommandRouter.dispatch()` → `GridRecorder.startRecording()` or `record()` → returns `{"action": "started"}` or `RecordingResult` JSON
- `grid.record.stop`: dispatches `@record stop` → `GridRecorder.stop()` → returns `RecordingResult` JSON `{filePath, format, size, duration}`
- `grid.record.toggle`: same as start but for toggle — returns `{"action": "started"}` or `RecordingResult`

The current MCP tools for recording pass through `callRPC` and get back the JSON result as text content. The response already includes `filePath` for stop/toggle. No enhancement needed for DW-3.3.

## Gaps

1. `grid.screenshot` tool definition is missing from `GridTools.definitions`
2. `GridTools.handle()` has no special case for `grid.screenshot` — it would incorrectly call `callRPC` which would fail
3. A new `ScreenshotTools.swift` file (or additions to GridTools) is needed to implement screenshot logic

## Implementation Plan

The cleanest approach:
- Add `grid.screenshot` tool definition to `GridTools.definitions`
- Intercept `grid.screenshot` in `GridTools.handle()` before the `callRPC` fallthrough
- Implement `handleScreenshot()` in GridTools (or a separate `ScreenshotTools.swift`)

The screenshot logic:
1. Parse params: `target` (full/cell/window, default: full), `id` (cell id or window id), `cursor` (bool)
2. Resolve bounds if needed: call RPC `dump` or `metadata.get` to get window/cell frame
3. Build `screencapture` args based on target type
4. Run `screencapture` synchronously (blocking, since RPCClient.call is synchronous)
5. Read output PNG file, base64-encode, return as `Tool.Content.image`
6. Clean up temp file

Screenshot modes:
- `full` / no target: `screencapture -x -C /tmp/grid-screenshot-{uuid}.png`
- `window` with id: `screencapture -x -l {windowID} /tmp/grid-screenshot-{uuid}.png`
- `cell` with id: get cell bounds via `dump` RPC, then `screencapture -x -R x,y,w,h /tmp/...`

Note: `-x` = silent (no sound), `-C` = include cursor (only for full screen mode)

## Prerequisites

- [x] Phase 2 complete — all grid.* tools defined and dispatching
- [x] `callRPC` helper available in ToolRegistry.swift
- [x] MCP SDK `Tool.Content.image(data:mimeType:annotations:_meta:)` confirmed available
- [x] `screencapture` available at `/usr/sbin/screencapture` on macOS
- [x] `dump` RPC returns window frame data (needed for window/cell targeting)

## Recommendation

BUILD — all prerequisites met. The main work is adding `grid.screenshot` tool + implementation. Recording tools (DW-3.2, DW-3.3) already work via existing `callRPC` passthrough.
