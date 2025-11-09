import Foundation
import Logging

/// Handles incoming requests and routes them to appropriate handlers
class MessageHandler {
    typealias RequestHandler = (Request, @escaping (Response) -> Void) -> Void

    private var handlers: [String: RequestHandler] = [:]
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
        registerBuiltInHandlers()
    }

    /// Register a handler for a specific method
    func register(method: String, handler: @escaping RequestHandler) {
        handlers[method] = handler
        logger.debug("Registered handler", metadata: ["method": "\(method)"])
    }

    /// Handle a request and call completion with the response
    func handle(request: Request, completion: @escaping (Response) -> Void) {
        logger.info("Handling request", metadata: ["id": "\(request.id)", "method": "\(request.method)"])

        guard let handler = handlers[request.method] else {
            let response = Response(
                id: request.id,
                error: ErrorInfo(
                    code: -32601,
                    message: "Method not found: \(request.method)"
                )
            )
            completion(response)
            return
        }

        // Execute handler
        handler(request) { response in
            completion(response)
        }
    }

    /// Register built-in handlers for demonstration
    private func registerBuiltInHandlers() {
        // Ping handler - simple echo to test connectivity
        register(method: "ping") { request, completion in
            let response = Response(
                id: request.id,
                result: AnyCodable(["pong": true, "timestamp": Date().timeIntervalSince1970])
            )
            completion(response)
        }

        // Echo handler - returns the params back
        register(method: "echo") { request, completion in
            let response = Response(
                id: request.id,
                result: AnyCodable(request.params ?? [:])
            )
            completion(response)
        }

        // Get spaces - placeholder for future macOS Spaces API integration
        register(method: "getSpaces") { [weak self] request, completion in
            self?.logger.info("getSpaces called (placeholder)")

            let mockSpaces = [
                ["id": 1, "name": "Space 1", "index": 0],
                ["id": 2, "name": "Space 2", "index": 1],
                ["id": 3, "name": "Space 3", "index": 2]
            ]

            let response = Response(
                id: request.id,
                result: AnyCodable(["spaces": mockSpaces])
            )
            completion(response)
        }

        // Get windows - placeholder for future macOS Windows API integration
        register(method: "getWindows") { [weak self] request, completion in
            self?.logger.info("getWindows called (placeholder)")

            let mockWindows = [
                ["id": 101, "title": "Terminal", "app": "Terminal", "space": 1],
                ["id": 102, "title": "Safari", "app": "Safari", "space": 1],
                ["id": 103, "title": "VSCode", "app": "Code", "space": 2]
            ]

            let response = Response(
                id: request.id,
                result: AnyCodable(["windows": mockWindows])
            )
            completion(response)
        }

        // Subscribe - placeholder for event subscriptions
        register(method: "subscribe") { [weak self] request, completion in
            self?.logger.info("Subscribe called", metadata: ["params": "\(request.params ?? [:])"])

            let response = Response(
                id: request.id,
                result: AnyCodable(["subscribed": true])
            )
            completion(response)
        }

        // Get server info
        register(method: "getServerInfo") { request, completion in
            let info: [String: Any] = [
                "name": "GridServer",
                "version": "0.1.0",
                "platform": "macOS",
                "capabilities": [
                    "spaces": false,  // Not yet implemented
                    "windows": false,  // Not yet implemented
                    "events": true
                ]
            ]

            let response = Response(
                id: request.id,
                result: AnyCodable(info)
            )
            completion(response)
        }
    }
}
