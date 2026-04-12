import Foundation
import MCP

/// Central registry of all MCP tool definitions and dispatch.
/// Collects tools from sub-modules and routes CallTool requests to the correct handler.
struct ToolRegistry: Sendable {
    let rpcClient: RPCClient

    /// All tool definitions for tools/list response.
    func allTools() -> [Tool] {
        return GridTools.definitions
            + WindowTools.definitions
            + QueryTools.definitions
    }

    /// Dispatch a tools/call request to the correct handler.
    /// Returns isError: true for unknown tool names.
    func dispatch(name: String, arguments: [String: Value]?) -> CallTool.Result {
        if name.hasPrefix("grid.") {
            return GridTools.handle(name: name, arguments: arguments, rpcClient: rpcClient)
        }

        if name.hasPrefix("window.") {
            return WindowTools.handle(name: name, arguments: arguments, rpcClient: rpcClient)
        }

        if QueryTools.canHandle(name: name) {
            return QueryTools.handle(name: name, arguments: arguments, rpcClient: rpcClient)
        }

        // Unknown tool
        return CallTool.Result(
            content: [.text(text: "Unknown tool: \(name)", annotations: nil, _meta: nil)],
            isError: true
        )
    }
}

// MARK: - Value Conversion Helpers

/// Convert MCP Value arguments to [String: Any] for RPCClient.
func convertValueToDict(_ values: [String: Value]?) -> [String: Any] {
    guard let values else { return [:] }
    var result: [String: Any] = [:]
    for (key, value) in values {
        if let converted = convertValue(value) {
            result[key] = converted
        }
    }
    return result
}

/// Convert a single Value to Any.
private func convertValue(_ value: Value) -> Any? {
    switch value {
    case .string(let s): return s
    case .int(let i): return i
    case .double(let d): return d
    case .bool(let b): return b
    case .null: return nil
    case .array(let arr): return arr.compactMap { convertValue($0) }
    case .object(let obj): return convertValueToDict(obj)
    case .data: return nil
    }
}

/// Serialize [String: Any] RPC result to JSON string for MCP text content.
func serializeResult(_ dict: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(
        withJSONObject: dict,
        options: [.sortedKeys]
    ) else {
        return "{}"
    }
    return String(data: data, encoding: .utf8) ?? "{}"
}

/// Shared dispatch: call RPCClient with converted arguments, return MCP result.
/// Used by all tool groups since the pattern is identical.
func callRPC(
    method: String,
    arguments: [String: Value]?,
    rpcClient: RPCClient
) -> CallTool.Result {
    do {
        let params = convertValueToDict(arguments)
        let result = try rpcClient.call(method, params: params)
        let json = serializeResult(result)
        return CallTool.Result(
            content: [.text(text: json, annotations: nil, _meta: nil)]
        )
    } catch let error as RPCError {
        return CallTool.Result(
            content: [.text(text: "Error: \(error.description)", annotations: nil, _meta: nil)],
            isError: true
        )
    } catch {
        return CallTool.Result(
            content: [.text(text: "RPC failed: \(error)", annotations: nil, _meta: nil)],
            isError: true
        )
    }
}

// MARK: - Schema Builder Helpers

/// Build a JSON Schema "object" Value with typed properties.
func objectSchema(
    properties: [String: Value],
    required: [String] = []
) -> Value {
    var schema: [String: Value] = [
        "type": .string("object"),
        "properties": .object(properties)
    ]
    if !required.isEmpty {
        schema["required"] = .array(required.map { .string($0) })
    }
    return .object(schema)
}

/// Build a property definition with type and optional description/enum.
func prop(
    _ type: String,
    description: String? = nil,
    enumValues: [String]? = nil
) -> Value {
    var dict: [String: Value] = ["type": .string(type)]
    if let desc = description {
        dict["description"] = .string(desc)
    }
    if let enums = enumValues {
        dict["enum"] = .array(enums.map { .string($0) })
    }
    return .object(dict)
}

/// An empty object schema (no parameters).
let emptySchema = objectSchema(properties: [:])
