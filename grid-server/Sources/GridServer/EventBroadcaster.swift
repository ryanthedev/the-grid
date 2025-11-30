import Foundation
import Logging

/// Manages broadcasting events to connected clients
class EventBroadcaster {
    private weak var socketServer: SocketServer?
    private let logger: Logger
    private var eventTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.thegrid.eventtimer")

    init(logger: Logger) {
        self.logger = logger
    }

    /// Set the socket server reference
    func setSocketServer(_ server: SocketServer) {
        self.socketServer = server
    }

    /// Broadcast an event to all connected clients
    func broadcast(event: Event, excludeSocket: Int32? = nil) {
        guard let server = socketServer else {
            logger.warning("Cannot broadcast event: No socket server")
            return
        }

        logger.debug("Broadcasting event", metadata: ["type": "\(event.eventType)"])

        let message = Message(event: event)
        let clientSockets = server.getClientSockets()

        for socket in clientSockets {
            if let exclude = excludeSocket, socket == exclude {
                continue
            }
            server.sendMessage(message, to: socket)
        }
    }

    /// Send an event to all clients
    func sendEvent(type: String, data: [String: Any]? = nil) {
        let event = Event(
            eventType: type,
            data: data.map { AnyCodable($0) }
        )
        broadcast(event: event)
    }

    /// Start sending periodic heartbeat events (for testing/POC)
    func startHeartbeat(interval: TimeInterval = 10.0) {
        stopHeartbeat()

        logger.info("Starting heartbeat events", metadata: ["interval": "\(interval)s"])

        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.sendHeartbeat()
        }
        timer.resume()

        eventTimer = timer
    }

    /// Stop sending heartbeat events
    func stopHeartbeat() {
        eventTimer?.cancel()
        eventTimer = nil
        logger.debug("Stopped heartbeat events")
    }

    /// Send a heartbeat event
    private func sendHeartbeat() {
        let data: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "uptime": ProcessInfo.processInfo.systemUptime
        ]

        sendEvent(type: "heartbeat", data: data)
    }

    /// Send a custom event
    func sendCustomEvent(type: String, payload: [String: Any]) {
        sendEvent(type: type, data: payload)
    }
}
