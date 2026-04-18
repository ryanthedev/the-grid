# Discovery: Phase 1 - Swift Package + RPC Client

## Files Found

Existing files relevant to this phase:
- `/Users/r/repos/theGrid/grid-server/Sources/GridCLI/RPCClient.swift` — source to port
- `/Users/r/repos/theGrid/grid-notify/Package.swift` — reference pattern for standalone Swift package
- `/Users/r/repos/theGrid/grid-notify/Sources/GridNotify/` — reference layout (Sources/ProductName/)

No `grid-mcp/` directory exists yet — to be created from scratch.

## Current State

- `grid-mcp/` package does not exist
- RPCClient.swift in GridCLI is self-contained (no GridCLI-specific dependencies), ports cleanly
- MCP Swift SDK (modelcontextprotocol/swift-sdk) is at version 0.12.0, requires Swift 6.1+ (we have 6.2.3 — compatible)
- SDK is available at `https://github.com/modelcontextprotocol/swift-sdk` (public, fetchable)
- StdioTransport is a concrete actor type, init with no required args
- Server API confirmed: `Server(name:version:capabilities:)` then `withMethodHandler` for registration, `start(transport:)` to run
- For Phase 1 we only need ListTools and CallTool handlers — minimal tool list (just ping) to satisfy DW-1.2
- RPCClient uses blocking POSIX I/O on a Unix socket — fine for Phase 1; async wrapper can wait for Phase 2

## Assumption Verification

- **Swift MCP SDK supports Swift 6.2** — CONFIRMED. SDK requires swift-tools-version 6.1, uses Swift 6 concurrency. We have Swift 6.2.3. Compatible.

## Gaps

- None. Plan assumptions match reality exactly.

## Prerequisites

- [x] RPCClient source exists and is portable
- [x] MCP SDK version 0.12.0 available and Swift 6.2 compatible
- [x] grid-notify package provides structural pattern to follow
- [x] No existing grid-mcp/ directory (clean slate — expected)

## Recommendation

BUILD

Create `grid-mcp/` from scratch following the grid-notify package pattern. Port RPCClient directly. Wire up MCP server with StdioTransport. Register ListTools (empty list for Phase 1) and CallTool handlers so initialize handshake works and ping can be tested.
