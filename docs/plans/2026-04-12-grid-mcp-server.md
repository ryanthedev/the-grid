# Plan: Grid MCP Server + Skill
**Created:** 2026-04-12
**Status:** in-progress
**Started:** 2026-04-12
**Current Phase:** 3
**Complexity:** medium
---
## Context
Build a stdio MCP server for theGrid that exposes the full window management surface as MCP tools, connecting directly to grid-server via Unix socket RPC. Also create a global Claude Code skill (`~/.claude/skills/grid/`) that teaches Claude how to use these tools effectively — when to screenshot, how to interpret layouts, workflow patterns for window management.

## Constraints
- Swift, new standalone package (`grid-mcp/`) following the grid-notify pattern
- Use official `modelcontextprotocol/swift-sdk` (0.12.0+, Swift 6.0+ — we have 6.2)
- Stdio transport (stdin/stdout JSON-RPC 2.0, newline-delimited)
- Direct Unix socket RPC client to grid-server (reuse RPCClient pattern from GridCLI)
- Full command surface: focus, layout, resize, record, window ops, state, cell, pick, terminal
- Skill is a global `~/.claude/skills/thegrid/SKILL.md` file (invoked as `/thegrid`)
- MCP server registered in `~/.claude/settings.local.json` under `mcpServers.thegrid`
---
## Chosen Approach
**Official Swift MCP SDK** — handles protocol negotiation, JSON-RPC framing, stdio transport. We focus only on mapping Grid RPCs to MCP tools. **Fallback:** hand-roll the protocol if SDK introduces compatibility issues.

## Rejected Approaches
- **Hand-rolled protocol:** Too much boilerplate for JSON-RPC 2.0 + capability negotiation with no upside.
- **CLI wrapper:** Slower (process spawning per call), can't subscribe to events, loses rich structured data.
- **Built into grid-server:** Couples MCP protocol to server lifecycle, server already handles its own socket transport.
---
## Implementation Phases

### Phase 1: Swift Package + RPC Client
**Model:** sonnet
**Skills:** `none -- straightforward package scaffolding and port of existing RPCClient`

**Goal:** Create the `grid-mcp` Swift package with MCP SDK dependency, port the RPCClient from GridCLI, and get a minimal MCP server that starts on stdio and responds to `initialize`.

**Scope:**
- IN: Package.swift, main entry point, RPCClient (adapted from GridCLI), basic Server setup with StdioTransport
- OUT: Tool definitions, skill file, Makefile integration

**File hints:** `grid-mcp/Package.swift`, `grid-mcp/Sources/GridMCP/`, `grid-server/Sources/GridCLI/RPCClient.swift` — port from here
**Depends on:** nothing | **Unlocks:** Phase 2

**Done when:**
- [ ] DW-1.1: `swift build` succeeds in `grid-mcp/`
- [ ] DW-1.2: Running the binary and sending an MCP `initialize` request on stdin produces a valid response on stdout
- [ ] DW-1.3: RPCClient connects to grid-server socket and can call `ping`

**Difficulty:** LOW
**Uncertainty:** None — SDK and RPCClient patterns are well-established

### Phase 2: MCP Tool Definitions + Dispatch
**Model:** opus
**Skills:** `none -- domain-specific tool mapping, no generic skill applies`

**Goal:** Define MCP tools for the full Grid command surface and implement the dispatch layer that maps MCP tool calls to Grid RPC calls and transforms results back.

**Scope:**
- IN: Tool definitions (name, description, inputSchema) for all Grid RPCs, CallTool handler dispatching to RPCClient, result transformation
- OUT: Screenshot/recording file handling (Phase 3), skill file

**Constraints:** Tool names should use dot-separated namespaces matching Grid RPC methods (e.g., `grid.focus`, `grid.layout.apply`). Input schemas must match the params the Grid server expects.

**Approach notes:** Two RPC layers to expose:

*Direct RPCs (MessageHandler):* `ping`, `getServerInfo`, `metadata.get`, `display.list`, `display.get`, `window.find`, `dump`, `window.setOpacity/getOpacity/fadeOpacity`, `window.setLayer/getLayer`, `window.show/hide/minimize/unminimize/close/raise/focus`, `window.setSticky/isSticky`, `borders.*`, `space.create/destroy/focus`

*Grid commands (GridCommandRouter, dispatched via `grid.*` RPC):* `grid.focus` (direction), `grid.focus.cycle`, `grid.focus.cell`, `grid.layout.apply/cycle/refresh/list/current/get`, `grid.cell.send/mode`, `grid.window.move/swap`, `grid.resize.grow/shrink/cell/reset`, `grid.record.start/stop/toggle`, `grid.terminal`, `grid.pick`, `grid.notify.toggle`, `grid.nudge.enter/exit`, `grid.state.reset`

*Explicitly excluded:* `grid.nudge.*` (requires interactive key hold session, not suited for MCP request/response), `borders.*` (internal rendering detail), `space.create/destroy` (destructive, rarely needed by AI)

Each tool's inputSchema should be a JSON Schema object matching the Grid RPC params.

**File hints:** `grid-mcp/Sources/GridMCP/Tools/` — one file per tool group
**Depends on:** Phase 1 | **Unlocks:** Phase 3

**Done when:**
- [ ] DW-2.1: `tools/list` returns all Grid tools with correct names, descriptions, and inputSchemas
- [ ] DW-2.2: `tools/call` with `grid.focus` dispatches the RPC and returns the result
- [ ] DW-2.3: `tools/call` with `grid.layout.list` returns layout data
- [ ] DW-2.4: `tools/call` with `window.find` returns window data matching query
- [ ] DW-2.5: `tools/call` with an invalid method name returns MCP response with `isError: true` and non-empty content text

**Difficulty:** MEDIUM
**Uncertainty:** Some Grid RPCs return complex nested structures — may need result simplification for AI consumption

### Phase 3: Screenshot + Recording Tools
**Model:** sonnet
**Skills:** `none -- project-specific recording integration`

**Goal:** Wire up the recording tools so screenshots and GIF/video captures return file paths (and optionally base64 image content) that Claude can consume.

**Scope:**
- IN: `grid.record.start`, `grid.record.stop`, `grid.record.toggle` tool implementations, screenshot convenience tool, returning image content as MCP image type
- OUT: Skill file (Phase 4)

**Approach notes:** GridRecorder always uses `screencapture -v` (video mode) — it has no PNG capture path. The `grid.screenshot` tool must implement its own capture: shell out to `screencapture -x -C` (silent, no cursor) for full screen, or use `screencapture -x -l <windowID>` for a specific window, or `screencapture -x -R x,y,w,h` for a cell region. The MCP server resolves cell/window bounds via `metadata.get` or `dump` RPCs, then runs screencapture directly. For screenshots, read the PNG file and return as base64 image content in the MCP response so Claude can see it directly. For recordings (GIF/MP4), delegate to `grid.record.*` RPCs and return just the file path.

**File hints:** `grid-mcp/Sources/GridMCP/Tools/`, `grid-server/Sources/GridServer/Grid/GridRecorder.swift` — understand recording flow
**Depends on:** Phase 2 | **Unlocks:** Phase 4

**Done when:**
- [ ] DW-3.1: `grid.screenshot` captures current screen/cell/window and returns base64 image content
- [ ] DW-3.2: `grid.record.start` with format=gif initiates a recording and returns status
- [ ] DW-3.3: `grid.record.stop` stops recording and returns the output file path
- [ ] DW-3.4: MCP response for `grid.screenshot` contains a content item with `type: "image"` and valid base64 PNG data (verifiable by piping to `base64 -d | file -`)

**Difficulty:** MEDIUM
**Uncertainty:** None — screenshot uses `screencapture` directly (confirmed recorder has no PNG path)

### Phase 4: Skill + Integration
**Model:** sonnet
**Skills:** `none -- skill is a markdown file, no code generation skill applies`

**Goal:** Create the global Claude Code skill and register the MCP server, plus add Makefile targets for building/installing the MCP server.

**Scope:**
- IN: `~/.claude/skills/thegrid/SKILL.md`, MCP server registration in settings, Makefile targets (`mcp-dev`, `mcp-install`)
- OUT: nothing — final phase

**Approach notes:** The skill should teach Claude: (1) what tools are available and their purpose, (2) when to use screenshots vs queries, (3) how to interpret layout/cell/window data, (4) common workflows (check what's on screen, rearrange windows, capture a demo GIF). Register the MCP server binary path in `~/.claude/settings.local.json` under `mcpServers.thegrid`.

**File hints:** `~/.claude/skills/thegrid/SKILL.md`, `~/.claude/settings.local.json`, `Makefile`
**Depends on:** Phase 3 | **Unlocks:** nothing

**Done when:**
- [ ] DW-4.1: `~/.claude/skills/thegrid/SKILL.md` exists with tool reference, workflow patterns, and interpretation guidance
- [ ] DW-4.2: MCP server is registered in Claude Code settings and starts successfully
- [ ] DW-4.3: `make mcp-dev` builds and deploys the MCP server binary
- [ ] DW-4.4: `/thegrid` is listed as an available skill in Claude Code and invocation loads the skill context
- [ ] DW-4.5: End-to-end test: Claude Code uses the MCP tool `grid.layout.list` and gets real data back

**Difficulty:** LOW
**Uncertainty:** None

---
## Test Coverage
**Level:** Per-phase manual verification
## Test Plan
- [ ] Phase 1: MCP initialize handshake works over stdio
- [ ] Phase 2: Tool list is complete, sample tool calls return correct data
- [ ] Phase 3: Screenshot returns viewable image, recording start/stop works
- [ ] Phase 4: Claude Code session uses MCP tools successfully

## Assumptions
| Assumption | Confidence | Verify Before Phase | Fallback If Wrong |
|------------|------------|--------------------|--------------------|
| Swift MCP SDK supports Swift 6.2 | HIGH | Phase 1 | Hand-roll protocol |
| Grid recording can do single-frame PNG | LOW (confirmed NO) | Phase 3 | Use macOS `screencapture` directly (chosen approach) |
| MCP image content type works with Claude Code | HIGH | Phase 3 | Return file path + use Read tool |

## Decision Log
| Decision | Alternatives Considered | Rationale | Phase |
|----------|------------------------|-----------|-------|
| Official Swift MCP SDK | Hand-rolled, CLI wrapper | Handles all protocol boilerplate, maintained by Anthropic | All |
| Separate package (grid-mcp/) | Built into grid-server, new target in existing package | Follows grid-notify pattern, independent lifecycle | All |
| Direct RPC client | CLI wrapper | Faster, richer data, event subscription possible | All |
| Dot-separated tool names | Flat names, slash-separated | Matches existing Grid RPC method naming | Phase 2 |
---
## Notes
- The MCP server binary will need to know the grid-server socket path. Default to `/tmp/grid-server.sock`, support `--socket` flag or `GRID_SOCKET` env var.
- Consider adding a `grid.state.describe` convenience tool that returns a human-readable summary of the current window layout for Claude's context.
- Event subscription (server push) is not part of MCP tools — tools are request/response only. If event streaming is desired later, MCP resources with subscriptions could work.
---
## Execution Log

### Phase 1: Swift Package + RPC Client (Gate: Full)
- [x] BUILD: Discovery + pseudocode + implementation complete
- [x] REVIEW: Verification passed
- [x] Committed
Commit: 523af33
Summary: New `grid-mcp/` Swift package with MCP SDK, ported RPCClient, minimal stdio MCP server that responds to initialize and pings grid-server end-to-end.

### Phase 2: MCP Tool Definitions + Dispatch (Gate: Full)
- [x] BUILD: Discovery + pseudocode + implementation complete
- [x] REVIEW: fail→pass (2 attempts — fixed concurrency, wrong RPC names)
- [x] Committed
Commit: 13b888b
Summary: 47 MCP tools across GridTools (24), WindowTools (14), QueryTools (9). RPCClient refactored to per-call connections. Removed grid.pick/grid.notify.toggle (no backing RPCs), added pick.show.
