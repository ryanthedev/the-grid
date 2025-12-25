import Foundation
import Logging

/// Manages broadcasting events to connected clients
class EventBroadcaster {
    private weak var socketServer: SocketServer?
    private var eventTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.thegrid.eventtimer")

    init(logger: Logger? = nil) {
    }

    /// Set the socket server reference
    func setSocketServer(_ server: SocketServer) {
        self.socketServer = server
    }

    /// Broadcast an event to all connected clients
    func broadcast(event: Event, excludeSocket: Int32? = nil) {
        guard let server = socketServer else {
            Task {
                JSONLogger.shared.log("warn.broadcast", data: ["msg": "no_socket_server"])
            }
            return
        }

        Task {
            JSONLogger.shared.log("event.broadcast", data: ["type": event.eventType])
        }

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

        Task {
            JSONLogger.shared.log("event.heartbeat", data: ["op": "start", "interval": interval])
        }

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
        Task {
            JSONLogger.shared.log("event.heartbeat", data: ["op": "stop"])
        }
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
