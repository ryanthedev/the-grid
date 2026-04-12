# Pseudocode: Phase 1 - Swift Package + RPC Client

## DW Verification

| DW-ID | Done-When Item | Status | Pseudocode Section |
|-------|---------------|--------|-------------------|
| DW-1.1 | `swift build` succeeds in `grid-mcp/` | COVERED | Package.swift |
| DW-1.2 | Running binary + MCP `initialize` on stdin produces valid response on stdout | COVERED | main.swift — Server Setup |
| DW-1.3 | RPCClient connects to grid-server socket and can call `ping` | COVERED | RPCClient.swift + main.swift ping test |

**All items COVERED:** YES

## Files to Create

- `grid-mcp/Package.swift`
- `grid-mcp/Sources/GridMCP/main.swift`
- `grid-mcp/Sources/GridMCP/RPCClient.swift`

## Pseudocode

### grid-mcp/Package.swift [DW-1.1]

```
swift-tools-version: 6.1
package name: GridMCP
platforms: macOS 13
dependencies:
  - modelcontextprotocol/swift-sdk from 0.12.0
targets:
  - executableTarget "GridMCP"
      path: Sources/GridMCP
      dependencies: .product("MCP", package: "swift-sdk")
      swiftSettings: .swiftLanguageMode(.v6)
```

### grid-mcp/Sources/GridMCP/RPCClient.swift [DW-1.3]

Direct port of `grid-server/Sources/GridCLI/RPCClient.swift`.
No changes to logic — same RPCError enum, same RPCClient class with:
- init(socketPath: String = "/tmp/grid-server.sock", timeout: TimeInterval = 30)
- connect() throws
- call(_ method: String, params: [String: Any] = [:]) throws -> [String: Any]
- disconnect()
- private readLine() throws -> Data

### grid-mcp/Sources/GridMCP/main.swift [DW-1.2, DW-1.3]

```
parse CLI args:
  socketPath = env GRID_SOCKET ?? "--socket" arg ?? "/tmp/grid-server.sock"

create RPCClient(socketPath: socketPath)

create Server(
  name: "grid-mcp",
  version: "0.1.0",
  capabilities: Server.Capabilities(tools: .init())
)

register ListTools handler:
  return ListTools.Result(tools: [])  // empty for Phase 1; Phase 2 adds real tools

register CallTool handler:
  if params.name == "ping":
    result = try rpcClient.call("ping")
    return CallTool.Result(content: [.text(text: "pong", annotations: nil, _meta: nil)])
  else:
    return CallTool.Result(content: [.text(text: "unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)

create transport = StdioTransport()
try await server.start(transport: transport)
```

Note on concurrency: RPCClient uses blocking POSIX I/O. The CallTool handler runs in an async context. We wrap the blocking call in `Task.detached` or accept that blocking in an async task is fine for Phase 1 (grid-server responds quickly, no UI thread at risk in a CLI tool). Phase 2 can add a proper async wrapper if needed.

Note on @main vs top-level: Use top-level async entrypoint (`@main` struct with `static func main() async throws`) to avoid Swift 6 concurrency warnings with global mutable state. Or simply use a top-level `main.swift` with `Task { ... }` and `RunLoop.main.run()` — the latter is simpler and matches grid-notify pattern.

Chosen: top-level `main.swift` with structured async:
```swift
import MCP
// parse args
// create rpcClient and server
// register handlers (closures capture rpcClient)
// await server.start(transport: StdioTransport())
```

Swift 6 requires Sendable for captured values in @Sendable closures. RPCClient is a class — mark `final class RPCClient: @unchecked Sendable` since its internal locking is provided by the single-threaded nature of the Phase 1 ping use case. Add a note to make it actor-based in Phase 2 if needed.

## Design Notes

- Keeping RPCClient as a direct port (blocking POSIX) is fine for Phase 1 — the server responds to ping in <1ms
- Tool list is empty for Phase 1 — MCP initialize handshake does not require any tools to be listed
- The `ping` CallTool path validates DW-1.3 without requiring a separate test binary
- Socket path resolution order: `GRID_SOCKET` env var, then `--socket` flag, then default `/tmp/grid-server.sock`
- No logging infrastructure for Phase 1 — Phase 4 can add it if desired (MCP server stderr is available)
