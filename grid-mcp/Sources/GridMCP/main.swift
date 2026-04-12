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
let registry = ToolRegistry(rpcClient: rpcClient)

let server = Server(
    name: "grid-mcp",
    version: "0.2.0",
    capabilities: Server.Capabilities(tools: .init())
)

// Register tools/list handler — returns all Grid tool definitions
await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: registry.allTools())
}

// Register tools/call handler — dispatches to the correct Grid RPC
await server.withMethodHandler(CallTool.self) { params in
    registry.dispatch(name: params.name, arguments: params.arguments)
}

// server.start launches the message loop in a background task and returns.
// waitUntilCompleted keeps the process alive until the client disconnects.
let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
