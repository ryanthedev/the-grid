# Review: Phase 2 - MCP Tool Definitions + Dispatch (Retry)

## Requirement Fulfillment

| DW-ID | Done-When Item | Status | Evidence |
|-------|---------------|--------|----------|
| DW-2.1 | `tools/list` returns all Grid tools with correct names, descriptions, and inputSchemas | SATISFIED | `main.swift:27-29` wires `ListTools` handler to `registry.allTools()`. Registry concatenates `GridTools.definitions` (25 tools) + `WindowTools.definitions` (14 tools) + `QueryTools.definitions` (9 tools including `pick.show`). Each tool has a name, description, and `objectSchema`/`emptySchema` inputSchema built via `prop()` helpers. |
| DW-2.2 | `tools/call` with `grid.focus` dispatches the RPC and returns the result | SATISFIED | `ToolRegistry.swift:19` routes `grid.*` prefix to `GridTools.handle`. `GridTools.swift:298` calls `callRPC(method: name, ...)` which invokes `rpcClient.call("grid.focus", params: params)` and returns JSON text. `grid.focus` is a registered grid-server RPC. |
| DW-2.3 | `tools/call` with `grid.layout.list` returns layout data | SATISFIED | `GridTools.swift:83-87` defines `grid.layout.list` with `emptySchema`. `GridTools.handle` passes it through to `callRPC` → `rpcClient.call("grid.layout.list", ...)`. Server registers this handler. |
| DW-2.4 | `tools/call` with `window.find` returns window data matching query | SATISFIED | `WindowTools.swift:9-19` defines `window.find` with `appName`, `title`, `pid` params. `ToolRegistry.swift:23` routes `window.*` to `WindowTools.handle` → `callRPC`. Server's `MessageHandler` registers `window.find`. |
| DW-2.5 | `tools/call` with an invalid method name returns MCP response with `isError: true` and non-empty content text | SATISFIED | `ToolRegistry.swift:31-35`: all prefix checks and `QueryTools.canHandle` fall through to `CallTool.Result(content: [.text("Unknown tool: \(name)")], isError: true)`. Content is always non-empty. |

**All requirements met:** YES

## Previous Findings Verification

| Finding | Status |
|---------|--------|
| RPCClient had no synchronization for concurrent calls | FIXED — `RPCClient` now opens a fresh connection per call (`openConnection()` in `call()`, `defer { close(fd) }`). Class is marked `final class RPCClient: Sendable` (not `@unchecked Sendable`). No shared mutable state. |
| grid.pick called wrong RPC method | FIXED — `grid.pick` removed from `GridTools.definitions`. `pick.show` now lives in `QueryTools` with the correct RPC method name. |
| grid.notify.toggle had no backing RPC | FIXED — removed from all tool definitions entirely. Not present in `GridTools.swift`. |

## Spec Match

The pseudocode listed `grid.pick` and `grid.notify.toggle` as tools in `GridTools`. The implementation removes them (correct behavior given no backing RPC exists). This is an intentional, documented deviation — the dispatch prompt explicitly states these were removed as fixes. The pseudocode was wrong; the implementation is correct.

- [x] ToolRegistry.swift: `allTools()` and `dispatch()` implemented exactly as specified
- [x] GridTools.swift: 25 tools covering focus, layout, cell, window movement, resize, record, state, config, terminal — all pseudocode sections present
- [x] WindowTools.swift: 14 window tools matching pseudocode exactly
- [x] QueryTools.swift: 8 query tools from pseudocode plus `pick.show` addition (net 9 total)
- [x] main.swift: `ListTools` and `CallTool` handlers wired to `ToolRegistry`
- [x] `convertValueToDict`, `serializeResult`, `objectSchema`, `prop`, `emptySchema`, `callRPC` helpers all implemented
- [x] `grid.resize.grow`/`grid.resize.shrink` → `grid.resize.adjust` delta translation implemented (`GridTools.swift:294-319`)

**Unplanned addition:** `callRPC()` shared helper extracted into `ToolRegistry.swift:80-103` to eliminate identical do/catch blocks across all three tool groups. Quality improvement, not scope creep.

**Test coverage:** Plan specifies "per-phase manual verification". No automated tests required or written. Consistent with plan.

## Dead Code

None found. All imports (`Foundation`, `MCP`) used in every file. No commented-out blocks, debug prints, or unreachable code. `case .data: return nil` in `convertValue` (`ToolRegistry.swift:65`) covers a real `Value` enum case.

## Correctness Dimensions

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Concurrency | PASS | `RPCClient` opens a fresh Unix socket connection per `call()` invocation (`openConnection()` called at `RPCClient.swift:37`, `defer { close(fd) }` at line 38). No shared mutable fields. Class declared `Sendable` (not `@unchecked`). Concurrent MCP tool calls each get independent connections and independent file descriptors. The previous FAIL is resolved. |
| Error Handling | PASS | `callRPC` catches `RPCError` (typed, with `.description`) and generic `Error` separately, both mapped to `isError: true` with non-empty content. `openConnection()` closes `fd` before throwing. `serializeResult` has `"{}"` fallback. `readLine` handles `n < 0` and `n == 0` (server disconnect). |
| Resources | PASS | Every `openConnection()` either returns an fd that `defer { close(fd) }` releases, or throws after closing the fd. No resource leak paths. `RPCClient` has no persistent connections to manage. |
| Boundaries | PASS | `convertValueToDict` handles nil arguments (returns `[:]`). `serializeResult` handles JSONSerialization failure. `handledNames` Set lookup is O(1). Empty-schema tools (e.g., `ping`, `dump`) pass `[:]` params safely. `pathBytes.count` checked against `sun_path` capacity before copy. |
| Security | N/A | No untrusted network input. Tool calls originate from Claude Code over the MCP stdio transport (SDK-validated). Arguments forwarded to local grid-server over a Unix socket. No shell construction, no path traversal. |

## Defensive Programming: PASS

1. External input at boundaries: `convertValueToDict` handles all `Value` enum cases. MCP SDK validates JSON-RPC framing before handlers are invoked.
2. Return values checked: `write()` result checked (`RPCClient.swift:57-59`). `JSONSerialization.data` failure handled in `serializeResult`.
3. Error paths: `callRPC` handles both `RPCError` and generic errors. `openConnection` closes `fd` on connect failure. `readLine` handles server disconnect.
4. Assertions: None needed — all failure conditions are environmental (server down, socket busy), not programmer errors.
5. Resources: Socket fd closed via `defer` in `call()` and explicitly before throwing in `openConnection()`.

One minor note: `serializeResult` returns `"{}"` on `JSONSerialization` failure, silently discarding the RPC result. Claude will see an empty JSON object rather than `isError: true`. This is low severity for a local macOS tool server, acceptable given the plan's light testing posture.

## Design Quality: PASS

**Per-call connections:** Opening a fresh Unix socket per `call()` is idiomatic for local IPC where connections are cheap. It eliminates shared state, simplifies the class to a pure value (`Sendable`), and avoids reconnect logic entirely. The tradeoff (connection overhead per call) is negligible on a Unix domain socket.

**`callRPC` extraction:** Correctly applies the "repeated code → extract shared method" rule. All three tool groups had identical dispatch logic. The extracted function is genuinely deep relative to its interface.

**`handleResizeGrowShrink`:** The grow/shrink → `grid.resize.adjust` translation is correctly isolated as a private method. The `doubleValue`/`intValue` accessors are confirmed present on the MCP SDK's `Value` type (`Value.swift` in swift-sdk). The fallback to `amount = 0.1` is an appropriate default matching the server's behavior.

**Dispatch routing:** Prefix dispatch (`hasPrefix("grid.")`, `hasPrefix("window.")`) plus Set-based `canHandle` fallback is clean. No routing ambiguity (no tool names overlap prefixes).

No unknown unknowns. No pass-through methods without added abstraction.

## Testing: N/A

Plan specifies manual verification per phase. No automated tests written, consistent with plan level. No ratio assessment applicable.

## Self-Check

- [x] All 5 DW items from dispatch prompt are in the table (DW-2.1 through DW-2.5)
- [x] No DW items omitted
- [x] Every SATISFIED item has concrete file:line evidence
- [x] Verdict matches rules: all DW satisfied, no correctness FAIL, no HIGH design findings → PASS

**Verdict: PASS**
