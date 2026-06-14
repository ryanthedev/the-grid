import Foundation
import Logging

/// Unix domain socket server that handles multiple client connections
class SocketServer {
    private let socketPath: String
    private var serverSocket: Int32?
    private var isRunning = false
    private var clientSockets: Set<Int32> = []
    private let clientQueue = DispatchQueue(label: "com.thegrid.client", attributes: .concurrent)
    private let socketQueue = DispatchQueue(label: "com.thegrid.socket")
    // #46: a single serial queue funnels EVERY write (request replies AND event
    // broadcasts) so two send() calls for the same client fd cannot interleave
    // bytes of two JSONL frames. The full-write loop below handles partial
    // writes; this queue handles concurrency between writers.
    private let writeQueue = DispatchQueue(label: "com.thegrid.socket.write")

    weak var messageHandler: MessageHandler?
    weak var eventBroadcaster: EventBroadcaster?

    init(socketPath: String, logger: Logger? = nil) {
        self.socketPath = socketPath
    }

    /// Start the socket server
    func start() throws {
        // Clean up any existing socket file
        cleanupSocket()

        // Create socket
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw SocketError.socketCreationFailed(errno)
        }
        serverSocket = sock

        // Set socket options
        var reuseAddr: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        // Bind socket
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        guard socketPath.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw SocketError.socketPathTooLong
        }

        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            socketPath.withCString { pathPtr in
                strcpy(ptr, pathPtr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult >= 0 else {
            throw SocketError.bindFailed(errno)
        }

        // Listen (backlog=128 to handle parallel client connections)
        guard listen(sock, 128) >= 0 else {
            throw SocketError.listenFailed(errno)
        }

        isRunning = true
        Task {
            JSONLogger.shared.log("sock.start", data: ["path": socketPath])
        }

        // Accept connections on background queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptConnections()
        }
    }

    /// Stop the socket server
    func stop() {
        isRunning = false

        // Close all client sockets
        socketQueue.sync {
            for clientSocket in clientSockets {
                close(clientSocket)
            }
            clientSockets.removeAll()
        }

        // Close server socket
        if let sock = serverSocket {
            close(sock)
            serverSocket = nil
        }

        cleanupSocket()
        Task {
            JSONLogger.shared.log("sock.stop", data: [:])
        }
    }

    /// Accept incoming connections
    private func acceptConnections() {
        guard let sock = serverSocket else { return }

        while isRunning {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(sock, sockaddrPtr, &clientAddrLen)
                }
            }

            guard clientSocket >= 0 else {
                if isRunning {
                    Task {
                        JSONLogger.shared.log("sock.err", data: ["op": "accept", "errno": errno])
                    }
                }
                continue
            }

            // #1: SO_NOSIGPIPE on the accepted socket. macOS has no MSG_NOSIGNAL,
            // so without this a write to a client that hung up raises SIGPIPE.
            // With it, send() returns -1/EPIPE which the sock.err branch handles
            // and the server stays alive.
            SocketServer.setNoSigPipe(clientSocket)

            // Log client connect event
            Task {
                JSONLogger.shared.log("sock.connect", data: ["cid": clientSocket])
            }

            socketQueue.async(flags: .barrier) { [weak self] in
                self?.clientSockets.insert(clientSocket)
            }

            // Handle client on separate queue
            clientQueue.async { [weak self] in
                self?.handleClient(socket: clientSocket)
            }
        }
    }

    /// Handle communication with a single client
    private func handleClient(socket: Int32) {
        defer {
            close(socket)
            socketQueue.async(flags: .barrier) { [weak self] in
                self?.clientSockets.remove(socket)
            }

            // Log client disconnect event
            Task {
                JSONLogger.shared.log("sock.disconnect", data: ["cid": socket])
            }
        }

        var buffer = Data()
        let readSize = 4096

        while isRunning {
            var chunk = [UInt8](repeating: 0, count: readSize)
            let bytesRead = recv(socket, &chunk, readSize, 0)

            if bytesRead <= 0 {
                // Connection closed or error
                break
            }

            buffer.append(contentsOf: chunk[0..<bytesRead])

            // Process complete messages (newline-delimited JSON)
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let messageData = buffer[..<newlineIndex]
                buffer.removeSubrange(...newlineIndex)

                if !messageData.isEmpty {
                    processMessage(data: messageData, clientSocket: socket)
                }
            }
        }
    }

    /// Process a received message
    private func processMessage(data: Data, clientSocket: Int32) {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let message = try decoder.decode(Message.self, from: data)

            switch message.type {
            case .request:
                if let request = message.request {
                    handleRequest(request, clientSocket: clientSocket)
                }
            case .event:
                // Clients can send events too (for future use)
                if let event = message.event {
                    eventBroadcaster?.broadcast(event: event, excludeSocket: clientSocket)
                }
            case .response:
                // Responses from client (not typical in server mode, but supported)
                Task {
                    JSONLogger.shared.log("warn.client_response", data: ["socket": clientSocket])
                }
            }
        } catch {
            Task {
                JSONLogger.shared.log("msg.err", data: ["op": "parse", "socket": clientSocket, "error": "\(error)"])
            }

            // Send error response if possible
            let errorResponse = Response(
                id: "unknown",
                error: ErrorInfo(code: -32700, message: "Parse error: \(error.localizedDescription)")
            )
            sendMessage(Message(response: errorResponse), to: clientSocket)
        }
    }

    /// Handle a request from a client
    private func handleRequest(_ request: Request, clientSocket: Int32) {
        guard let handler = messageHandler else {
            let errorResponse = Response(
                id: request.id,
                error: ErrorInfo(code: -32603, message: "Internal error: No message handler")
            )
            sendMessage(Message(response: errorResponse), to: clientSocket)
            return
        }

        handler.handle(request: request) { [weak self] response in
            self?.sendMessage(Message(response: response), to: clientSocket)
        }
    }

    /// Enable SO_NOSIGPIPE on a socket fd so a write to a hung-up peer returns
    /// EPIPE instead of raising a fatal SIGPIPE (#1).
    static func setNoSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Send a message to a specific client. Serialized per-server through
    /// writeQueue (#46) so frames cannot interleave, and written via a
    /// full-write loop so a partial send() never truncates a JSONL frame.
    func sendMessage(_ message: Message, to socket: Int32) {
        let bytes: [UInt8]
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(message)
            data.append(UInt8(ascii: "\n"))
            bytes = [UInt8](data)
        } catch {
            Task {
                JSONLogger.shared.log("msg.err", data: ["op": "encode", "error": "\(error)"])
            }
            return
        }

        // Serialize all writes to all client fds. The loop below is the only
        // place send() is called, so frames are written atomically per message.
        writeQueue.sync {
            let result = FullWrite.writeAll(bytes) { ptr, len in
                let n = send(socket, ptr, len, 0)
                return (n, errno)
            }
            switch result {
            case .ok:
                break
            case .disconnected:
                // Peer hung up between request and reply (#1). Not fatal —
                // drop the frame; handleClient's recv loop will reap the fd.
                Task {
                    JSONLogger.shared.log("sock.err", data: ["op": "send", "socket": socket, "reason": "disconnected"])
                }
            case .failed(let err):
                Task {
                    JSONLogger.shared.log("sock.err", data: ["op": "send", "socket": socket, "errno": Int(err)])
                }
            }
        }
    }

    /// Broadcast a message to all connected clients
    func broadcast(_ message: Message) {
        socketQueue.sync {
            for socket in clientSockets {
                sendMessage(message, to: socket)
            }
        }
    }

    /// Get all connected client sockets
    func getClientSockets() -> [Int32] {
        return socketQueue.sync {
            Array(clientSockets)
        }
    }

    /// Clean up socket file
    private func cleanupSocket() {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: socketPath) {
            try? fileManager.removeItem(atPath: socketPath)
        }
    }
}

/// Socket server errors
enum SocketError: Error {
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case socketPathTooLong

    var localizedDescription: String {
        switch self {
        case .socketCreationFailed(let errno):
            return "Failed to create socket: \(String(cString: strerror(errno)))"
        case .bindFailed(let errno):
            return "Failed to bind socket: \(String(cString: strerror(errno)))"
        case .listenFailed(let errno):
            return "Failed to listen on socket: \(String(cString: strerror(errno)))"
        case .socketPathTooLong:
            return "Socket path is too long"
        }
    }
}
