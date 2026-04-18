# Review: Phase 2 - MCP Tool Definitions + Dispatch

## Requirement Fulfillment

| DW-ID | Done-When Item | Status | Evidence |
|-------|---------------|--------|----------|
| DW-2.1 | `tools/list` returns all Grid tools with correct names, descriptions, and inputSchemas | SATISFIED | `main.swift:27-29` wires `ListTools` handler to `registry.allTools()`. Registry returns 26 GridTools + 14 WindowTools + 8 QueryTools = 48 tools total. All have names, descriptions, and `objectSchema`/`emptySchema` inputSchemas built via `prop()` helpers. |
| DW-2.2 | `tools/call` with `grid.focus` dispatches the RPC and returns the result | SATISFIED | `ToolRegistry.swift:19` routes `grid.*` to `GridTools.handle`. `GridTools.swift:311` calls `callRPC(method: name, ...)` which calls `rpcClient.call("grid.focus", ...)` and returns JSON text. `grid.focus` is registered in server at `MessageHandler.swift:1479`. |
| DW-2.3 | `tools/call` with `grid.layout.list` returns layout data | SATISFIED | `GridTools.swift:83-87` defines `grid.layout.list` tool. `GridTools.handle` passes it through to `callRPC`. Server registers `grid.layout.list` at `MessageHandler.swift:1674`. |
| DW-2.4 | `tools/call` with `window.find` returns window data matching query | SATISFIED | `WindowTools.swift:9-19` defines `window.find` with `appName`, `title`, `pid` params matching server handler at `MessageHandler.swift:226`. `ToolRegistry.swift:23` routes `window.*` to `WindowTools.handle` which calls `callRPC`. |
| DW-2.5 | `tools/call` with an invalid method name returns MCP response with `isError: true` and non-empty content text | SATISFIED | `ToolRegistry.swift:31-35`: falls through all prefix checks and `QueryTools.canHandle`, returns `CallTool.Result(content: [.text("Unknown tool: \(name)")], isError: true)`. |

**All requirements met:** YES

## Spec Match

- [x] ToolRegistry.swift implements `allTools()` + `dispatch()` exactly as specified
- [x] GridTools.swift covers all 26 tools from pseudocode (focus, focus.cycle, focus.cell, layout.apply/cycle/refresh/list/current/get, cell.send/mode, window.move/swap, resize.grow/shrink/cell/reset, record.start/stop/toggle, state.reset/show, config.show, terminal, pick, notify.toggle)
- [x] WindowTools.swift covers all 14 window tools from pseudocode
- [x] QueryTools.swift covers all 8 query tools from pseudocode
- [x] main.swift replaces placeholder handlers with ToolRegistry
- [x] `convertValueToDict`, `serializeResult`, `objectSchema`, `prop`, `emptySchema` helpers implemented (named slightly differently from pseudocode but functionally equivalent)
- [x] `grid.resize.grow/shrink` → `grid.resize.adjust` translation implemented (`GridTools.swift:307-331`)

**Unplanned addition:** `callRPC()` shared helper (`ToolRegistry.swift:80-103`) extracted to avoid the identical do/catch block repeated across GridTools, WindowTools, QueryTools. This is a quality improvement, not scope creep.

**Deviation from pseudocode:** Pseudocode shows each module has its own local do/catch dispatch. Implementation consolidates into `callRPC()` in ToolRegistry.swift. This is strictly better — eliminates triplication.

**Test coverage:** Plan specifies "per-phase manual verification". No automated tests written. Consistent with plan level.

## Dead Code

None found. All imports (`Foundation`, `MCP`) are used. No commented-out blocks, debug prints, or unreachable code. The `case .data: return nil` branch in `convertValue` (`ToolRegistry.swift:65`) handles a real Value enum case — not dead code.

## Correctness Dimensions

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Concurrency | FAIL | See below |
| Error Handling | PASS | `callRPC` catches `RPCError` and generic `Error` separately, mapping both to `isError: true` with non-empty content. `serializeResult` has a fallback `"{}"` on JSONSerialization failure. |
| Resources | PASS | `RPCClient.disconnect()` called in `deinit`. Socket fd closed on all error paths in `connect()`. No new resource acquisition in Phase 2 code. |
| Boundaries | PASS | `convertValueToDict` handles nil arguments (returns `[:]`). `serializeResult` handles JSONSerialization failure. Empty param tools work via `emptySchema`. `handledNames` Set lookup is O(1). |
| Security | N/A | No untrusted network input. Tool names come from the MCP protocol layer (SDK-validated). Arguments are passed to local grid-server via Unix socket. No shell construction, no path traversal vectors. |

### Concurrency: FAIL

The MCP `Server` is an `actor` (`Server.swift:9`), but it dispatches each incoming request in a detached `Task {}` to avoid blocking the receive loop (`Server.swift:234-236`):

```swift
// Handle request in a separate task to avoid blocking the receive loop
Task {
    _ = try? await self.handleRequest(request, sendResponse: true)
}
```

This means concurrent MCP tool calls can run simultaneously. `RPCClient` is marked `@unchecked Sendable` with the comment "serialized by the MCP server actor in Phase 1" (`RPCClient.swift:23-24`), but that assumption is false — the server dispatches handlers concurrently.

The `RPCClient` has unprotected mutable state:
- `fileDescriptor: Int32` (`RPCClient.swift:28`) — read/written without synchronization
- `connect()` is called lazily in `call()` (`RPCClient.swift:72-74`): two concurrent callers can both see `fileDescriptor < 0` and both attempt to open the socket

Concurrent calls on the same RPCClient will interleave `write()` and `read()` on the same socket file descriptor, corrupting the JSON-RPC framing. The server reads newline-delimited messages; interleaved writes from concurrent callers produce garbled messages.

**Fix required before PASS:** Add a serial dispatch queue or `NSLock` around the `call()` body in `RPCClient`, or open a new socket connection per call.

## Defensive Programming: PASS (with note)

1. External input at boundaries: `convertValueToDict` handles all `Value` cases defensively. Arguments flowing in from MCP protocol are validated by the SDK before reaching handlers.
2. Return values checked: `JSONSerialization.data(...)` failure handled via `try?` with `"{}"` fallback. Socket `write()` result checked.
3. Error paths: `callRPC` handles both `RPCError` and generic errors. Socket read handles `n == 0` (server disconnect) and `n < 0` (read error).
4. Assertions: None needed — all conditions are runtime-environmental (network, server availability).
5. Resources: Socket closed in `deinit` and on connect failure.

Note: `serializeResult` returning `"{}"` on JSONSerialization failure silently swallows the error. The caller gets a valid-looking but empty JSON response rather than an `isError: true` result. This is acceptable for a non-critical tool (Claude will see `{}` and can retry), but is worth noting.

## Design Quality: PASS

**`callRPC` extraction (ToolRegistry.swift:80-103):** The three tool groups all have identical dispatch logic. Extracting it as a module-level function in ToolRegistry.swift is correct by the "repeated code → extract shared method" rule. The function is genuinely deep (4 parameters, do/catch, type conversion, serialization) relative to its interface.

**`ToolRegistry` dispatch (ToolRegistry.swift:18-36):** The prefix-dispatch (`hasPrefix("grid.")`, `hasPrefix("window.")`) plus fallback `canHandle` set is clean. No leakage between layers.

**`handledNames` static Set (QueryTools.swift:82):** Computed once at load time from `definitions`, ensuring it stays in sync. Correct.

**`@unchecked Sendable` comment is wrong** (`RPCClient.swift:23-24`): The comment says handlers are "serialized by the MCP server actor" which is incorrect given the SDK's concurrent task dispatch. This is a documentation correctness issue, tied to the concurrency FAIL above.

## Testing: N/A

Plan specifies manual verification per phase, no automated tests required. No tests were written, consistent with plan. No ratio assessment applicable.

## Issues (FAIL)

1. **Concurrent RPCClient access — data race on socket fd**
   - File: `grid-mcp/Sources/GridMCP/RPCClient.swift:28, 72-74, 87-96, 136`
   - Root cause: MCP Server dispatches each request in a new `Task {}` (not serialized by actor isolation), but `RPCClient` has no synchronization on `fileDescriptor` or the write/read sequence.
   - Fix: Add an `NSLock` or serial `DispatchQueue` around `call()`. Alternatively, use one socket connection per call (connect, call, disconnect) which is simpler and eliminates the race entirely, at the cost of connection overhead per call. Given that grid-server is local over a Unix socket, per-call connections are fast and eliminate the shared-state problem.
   - Severity: HIGH — concurrent tool calls (e.g., Claude calling `metadata.get` and `dump` simultaneously) will corrupt the socket stream and produce garbled responses or server errors.

**Verdict: FAIL — DW items all satisfied, but concurrency dimension fails due to unprotected shared mutable state in RPCClient under the MCP server's concurrent task dispatch model.**
