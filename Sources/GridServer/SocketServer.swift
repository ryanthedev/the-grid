import Foundation
import Logging

/// Unix domain socket server that handles multiple client connections
class SocketServer {
    private let socketPath: String
    private let logger: Logger
    private var serverSocket: Int32?
    private var isRunning = false
    private var clientSockets: Set<Int32> = []
    private let clientQueue = DispatchQueue(label: "com.thegrid.client", attributes: .concurrent)
    private let socketQueue = DispatchQueue(label: "com.thegrid.socket")

    weak var messageHandler: MessageHandler?
    weak var eventBroadcaster: EventBroadcaster?

    init(socketPath: String, logger: Logger) {
        self.socketPath = socketPath
        self.logger = logger
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

        // Listen
        guard listen(sock, 5) >= 0 else {
            throw SocketError.listenFailed(errno)
        }

        isRunning = true
        logger.info("Socket server started", metadata: ["path": "\(socketPath)"])

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
        logger.info("Socket server stopped")
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
                    logger.error("Failed to accept connection", metadata: ["errno": "\(errno)"])
                }
                continue
            }

            logger.info("Client connected", metadata: ["socket": "\(clientSocket)"])

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
            logger.info("Client disconnected", metadata: ["socket": "\(socket)"])
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

            logger.debug("Received message", metadata: ["type": "\(message.type)", "socket": "\(clientSocket)"])

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
                logger.warning("Received response from client", metadata: ["socket": "\(clientSocket)"])
            }
        } catch {
            logger.error("Failed to parse message", metadata: ["error": "\(error)", "socket": "\(clientSocket)"])

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

    /// Send a message to a specific client
    func sendMessage(_ message: Message, to socket: Int32) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(message)
            data.append(UInt8(ascii: "\n"))

            let sent = data.withUnsafeBytes { ptr in
                send(socket, ptr.baseAddress, data.count, 0)
            }

            if sent < 0 {
                logger.error("Failed to send message", metadata: ["errno": "\(errno)", "socket": "\(socket)"])
            }
        } catch {
            logger.error("Failed to encode message", metadata: ["error": "\(error)"])
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
