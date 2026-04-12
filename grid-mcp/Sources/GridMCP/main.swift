import Foundation
import MCP

// Resolve socket path: GRID_SOCKET env var > --socket flag > default
func resolveSocketPath() -> String {
    if let env = ProcessInfo.processInfo.environment["GRID_SOCKET"] {
        return env
    }
    let args = CommandLine.arguments
    if let idx = args.firstIndex(of: "--socket"), idx + 1 < args.count {
        return args[idx + 1]
    }
    return "/tmp/grid-server.sock"
}

let socketPath = resolveSocketPath()
let rpcClient = RPCClient(socketPath: socketPath)

let server = Server(
    name: "grid-mcp",
    version: "0.1.0",
    capabilities: Server.Capabilities(tools: .init())
)

// Register tools/list handler — empty for Phase 1; Phase 2 adds real tools
await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: [])
}

// Register tools/call handler — routes ping to grid-server for DW-1.3 validation
await server.withMethodHandler(CallTool.self) { params in
    switch params.name {
    case "ping":
        do {
            let result = try rpcClient.call("ping")
            let status = result["status"] as? String ?? "ok"
            return CallTool.Result(
                content: [.text(text: "ping: \(status)", annotations: nil, _meta: nil)]
            )
        } catch {
            return CallTool.Result(
                content: [.text(text: "ping failed: \(error)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    default:
        return CallTool.Result(
            content: [.text(text: "unknown tool: \(params.name)", annotations: nil, _meta: nil)],
            isError: true
        )
    }
}

// server.start launches the message loop in a background task and returns.
// waitUntilCompleted keeps the process alive until the client disconnects.
let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
