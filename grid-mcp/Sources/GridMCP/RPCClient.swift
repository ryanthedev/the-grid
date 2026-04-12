import Foundation

enum RPCError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case writeFailed(String)
    case readFailed(String)
    case invalidResponse(String)
    case serverError(code: Int, message: String)
    case timeout

    var description: String {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .writeFailed(let msg): return "Write failed: \(msg)"
        case .readFailed(let msg): return "Read failed: \(msg)"
        case .invalidResponse(let msg): return "Invalid response: \(msg)"
        case .serverError(_, let msg): return msg
        case .timeout: return "Request timed out"
        }
    }
}

// Sendable: each call() opens a fresh Unix socket connection,
// so there is no shared mutable state between concurrent calls.
final class RPCClient: Sendable {
    let socketPath: String
    let timeout: TimeInterval

    init(socketPath: String = "/tmp/grid-server.sock", timeout: TimeInterval = 30) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    func call(_ method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        // Open a fresh connection per call — local Unix sockets are cheap,
        // and this eliminates shared state for concurrent MCP tool calls.
        let fd = try openConnection()
        defer { close(fd) }

        let requestId = UUID().uuidString
        let envelope: [String: Any] = [
            "type": "request",
            "request": [
                "id": requestId,
                "method": method,
                "params": params
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: envelope)
        var outData = jsonData
        outData.append(0x0A)

        let written = outData.withUnsafeBytes { buf in
            write(fd, buf.baseAddress!, buf.count)
        }
        if written < 0 {
            throw RPCError.writeFailed("Failed to write to socket")
        }

        let lineData = try readLine(fd: fd)

        guard let response = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            throw RPCError.invalidResponse("Response is not a JSON object")
        }

        guard let type = response["type"] as? String, type == "response" else {
            throw RPCError.invalidResponse("Response type is not 'response'")
        }

        guard let respObj = response["response"] as? [String: Any] else {
            throw RPCError.invalidResponse("Missing response object")
        }

        if let errObj = respObj["error"] as? [String: Any] {
            let code = errObj["code"] as? Int ?? -1
            let message = errObj["message"] as? String ?? "Unknown error"
            throw RPCError.serverError(code: code, message: message)
        }

        return respObj["result"] as? [String: Any] ?? [:]
    }

    private func openConnection() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw RPCError.connectionFailed("Failed to create socket")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw RPCError.connectionFailed("Socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for i in 0..<pathBytes.count {
                    dest[i] = pathBytes[i]
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Foundation.connect(fd, sockPtr, addrLen)
            }
        }

        if result < 0 {
            close(fd)
            throw RPCError.connectionFailed("Cannot connect to \(socketPath) - is the server running?")
        }

        return fd
    }

    private func readLine(fd: Int32) throws -> Data {
        var buffer = Data()
        var byte: UInt8 = 0

        while true {
            let n = read(fd, &byte, 1)
            if n < 0 {
                throw RPCError.readFailed("Failed to read from socket")
            }
            if n == 0 {
                throw RPCError.readFailed("Connection closed by server")
            }
            if byte == 0x0A {
                return buffer
            }
            buffer.append(byte)
        }
    }
}
