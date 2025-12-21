//
// NotificationManager.swift
// GridServer
//
// Core notification management: creation, responses, timeouts, caching.
//

import Foundation

/// Manages notification lifecycle
class NotificationManager: NotificationWindowDelegate {
    // MARK: - Properties

    private var activeNotifications: [String: NotificationState] = [:]
    private var windows: [String: NotificationWindow] = [:]
    private let store: NotificationStore
    private weak var socketServer: SocketServer?

    private let queue = DispatchQueue(label: "com.thegrid.notificationmanager")

    // MARK: - Initialization

    init(socketServer: SocketServer) {
        self.store = NotificationStore()
        self.socketServer = socketServer

        Task {
            await EventLog.shared.log("notif.mgr.init", [:])
        }
    }

    // MARK: - Public Methods

    /// Create a notification or return cached response
    func create(
        _ params: CreateNotificationParams,
        socketID: Int32,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let id = params.notificationId

            // 1. Check cache - if response exists, return immediately
            if let cached = self.store.get(id) {
                let result: [String: Any] = [
                    "status": "cached",
                    "response": [
                        "notificationId": cached.notificationId,
                        "button": cached.button as Any,
                        "text": cached.text as Any,
                        "cancelled": cached.cancelled,
                        "timedOut": cached.timedOut,
                        "timestamp": ISO8601DateFormatter().string(from: cached.timestamp)
                    ]
                ]
                completion(.success(result))
                return
            }

            // 2. Check active - if same ID active, return pending status
            if self.activeNotifications[id] != nil {
                let result: [String: Any] = [
                    "status": "pending",
                    "notificationId": id
                ]
                completion(.success(result))
                return
            }

            // 3. Create notification state
            let state = NotificationState(
                id: id,
                title: params.title,
                body: params.body,
                buttons: params.buttons,
                hasTextInput: params.textInput,
                textMaxLength: params.textMaxLength,
                timeout: params.timeout,
                position: params.position,
                originSocket: socketID
            )

            self.activeNotifications[id] = state

            Task {
                await EventLog.shared.log("notif.create", [
                    "id": id,
                    "hasButtons": params.buttons != nil,
                    "hasText": params.textInput
                ])
            }

            // 4. Create window on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                let window = NotificationWindow(
                    notificationId: id,
                    title: params.title,
                    body: params.body,
                    buttons: params.buttons,
                    hasTextInput: params.textInput,
                    textMaxLength: params.textMaxLength,
                    position: params.position
                )
                window.notificationDelegate = self

                self.queue.async {
                    self.windows[id] = window
                }

                window.show()

                // 5. Start timeout timer if specified
                if let timeout = params.timeout, timeout > 0 {
                    self.startTimeoutTimer(for: id, timeout: timeout)
                }
            }

            // Return pending status immediately
            let result: [String: Any] = [
                "status": "pending",
                "notificationId": id
            ]
            completion(.success(result))
        }
    }

    /// Get a cached response
    func get(_ notificationId: String) -> CachedNotificationResponse? {
        return store.get(notificationId)
    }

    /// Cancel a pending notification
    func cancel(_ notificationId: String) -> Bool {
        return queue.sync {
            guard let state = activeNotifications[notificationId] else {
                return false
            }

            // Stop timeout timer
            state.timeoutTimer?.cancel()

            // Cache cancelled response
            let response = CachedNotificationResponse(
                notificationId: notificationId,
                cancelled: true
            )
            store.save(response)

            // Send cancelled event to origin socket
            sendEvent(
                eventType: "notify.cancelled",
                notificationId: notificationId,
                to: state.originSocket
            )

            // Dismiss window and cleanup
            dismissAndCleanup(notificationId)

            Task {
                await EventLog.shared.log("notif.cancel", ["id": notificationId])
            }

            return true
        }
    }

    /// List notifications
    func list(filter: NotificationListFilter) -> [[String: Any]] {
        return queue.sync {
            var result: [[String: Any]] = []

            // Active notifications
            if filter == .active || filter == .all {
                for (id, state) in activeNotifications {
                    result.append([
                        "notificationId": id,
                        "status": "active",
                        "title": state.title,
                        "createdAt": ISO8601DateFormatter().string(from: state.createdAt)
                    ])
                }
            }

            // Cached notifications
            if filter == .cached || filter == .all {
                for cached in store.getAllCached() {
                    // Skip if also in active (shouldn't happen but be safe)
                    if activeNotifications[cached.notificationId] != nil {
                        continue
                    }
                    result.append([
                        "notificationId": cached.notificationId,
                        "status": "cached",
                        "button": cached.button as Any,
                        "text": cached.text as Any,
                        "cancelled": cached.cancelled,
                        "timedOut": cached.timedOut,
                        "timestamp": ISO8601DateFormatter().string(from: cached.timestamp)
                    ])
                }
            }

            return result
        }
    }

    /// Clear a cached response
    func clear(_ notificationId: String) -> Bool {
        return store.delete(notificationId)
    }

    /// Get status info (for debugging)
    func status() -> [String: Any] {
        return queue.sync {
            return [
                "activeCount": activeNotifications.count,
                "activeIds": Array(activeNotifications.keys),
                "cachedCount": store.listCached().count
            ]
        }
    }

    // MARK: - NotificationWindowDelegate

    func notificationWindow(_ window: NotificationWindow, didClickButton button: String) {
        handleResponse(id: window.notificationId, button: button, text: nil)
    }

    func notificationWindow(_ window: NotificationWindow, didSubmitText text: String) {
        handleResponse(id: window.notificationId, button: nil, text: text)
    }

    // MARK: - Private Methods

    private func handleResponse(id: String, button: String?, text: String?) {
        queue.async { [weak self] in
            guard let self = self,
                  let state = self.activeNotifications[id] else {
                return
            }

            // Stop timeout timer
            state.timeoutTimer?.cancel()

            // Cache response
            let response = CachedNotificationResponse(
                notificationId: id,
                button: button,
                text: text
            )
            self.store.save(response)

            // Send response event to origin socket
            var eventData: [String: Any] = [
                "notificationId": id,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
            if let button = button {
                eventData["button"] = button
            }
            if let text = text {
                eventData["text"] = text
            }

            self.sendEvent(
                eventType: "notify.response",
                data: eventData,
                to: state.originSocket
            )

            // Dismiss window and cleanup
            self.dismissAndCleanup(id)
        }
    }

    private func handleTimeout(id: String) {
        queue.async { [weak self] in
            guard let self = self,
                  let state = self.activeNotifications[id] else {
                return
            }

            // Cache timeout response
            let response = CachedNotificationResponse(
                notificationId: id,
                timedOut: true
            )
            self.store.save(response)

            // Send timeout event to origin socket
            self.sendEvent(
                eventType: "notify.timeout",
                notificationId: id,
                to: state.originSocket
            )

            // Dismiss window and cleanup
            self.dismissAndCleanup(id)

            Task {
                await EventLog.shared.log("notif.timeout", ["id": id])
            }
        }
    }

    private func startTimeoutTimer(for id: String, timeout: Int) {
        queue.async { [weak self] in
            guard let self = self,
                  let state = self.activeNotifications[id] else {
                return
            }

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(timeout))
            timer.setEventHandler { [weak self] in
                self?.handleTimeout(id: id)
            }
            timer.resume()

            state.timeoutTimer = timer
        }
    }

    private func dismissAndCleanup(_ id: String) {
        // Remove from active
        activeNotifications.removeValue(forKey: id)

        // Dismiss window on main thread
        DispatchQueue.main.async { [weak self] in
            if let window = self?.windows[id] {
                window.dismiss()
            }
            self?.queue.async {
                self?.windows.removeValue(forKey: id)
            }
        }
    }

    private func sendEvent(eventType: String, notificationId: String, to socket: Int32) {
        let data: [String: Any] = [
            "notificationId": notificationId,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        sendEvent(eventType: eventType, data: data, to: socket)
    }

    private func sendEvent(eventType: String, data: [String: Any], to socket: Int32) {
        guard let socketServer = socketServer else {
            Task {
                await EventLog.shared.log("notif.sock.fail", [
                    "reason": "no_server",
                    "socket": socket
                ])
            }
            return
        }

        // Check if socket is still connected
        guard socketServer.isSocketConnected(socket) else {
            Task {
                await EventLog.shared.log("notif.sock.fail", [
                    "reason": "disconnected",
                    "socket": socket
                ])
            }
            return
        }

        let event = Event(eventType: eventType, data: AnyCodable(data))
        socketServer.sendEvent(event, to: socket)
    }
}
