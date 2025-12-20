//
// NotificationStore.swift
// GridServer
//
// Disk persistence for cached notification responses.
// Stores responses in ~/.local/state/thegrid/notifications/{id}.json
//

import Foundation

/// Manages disk persistence for notification responses
class NotificationStore {
    private let notificationsDir: URL
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.thegrid.notificationstore")

    init() {
        // ~/.local/state/thegrid/notifications/
        let stateDir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/thegrid/notifications")

        self.notificationsDir = stateDir

        // Ensure directory exists
        try? fileManager.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    /// Save a cached response to disk (atomic write)
    func save(_ response: CachedNotificationResponse) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let fileURL = self.fileURL(for: response.notificationId)
            let tempURL = fileURL.appendingPathExtension("tmp")

            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = .prettyPrinted
                let data = try encoder.encode(response)

                // Write to temp file first
                try data.write(to: tempURL, options: .atomic)

                // Rename to final location (atomic)
                if self.fileManager.fileExists(atPath: fileURL.path) {
                    try self.fileManager.removeItem(at: fileURL)
                }
                try self.fileManager.moveItem(at: tempURL, to: fileURL)

                Task {
                    await EventLog.shared.log("notif.cache.save", ["id": response.notificationId])
                }
            } catch {
                Task {
                    await EventLog.shared.log("notif.cache.err", [
                        "op": "save",
                        "id": response.notificationId,
                        "error": "\(error)"
                    ])
                }
            }
        }
    }

    /// Get a cached response by ID
    func get(_ notificationId: String) -> CachedNotificationResponse? {
        return queue.sync {
            let fileURL = fileURL(for: notificationId)

            guard fileManager.fileExists(atPath: fileURL.path) else {
                return nil
            }

            do {
                let data = try Data(contentsOf: fileURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let response = try decoder.decode(CachedNotificationResponse.self, from: data)

                Task {
                    await EventLog.shared.log("notif.cache.hit", ["id": notificationId])
                }

                return response
            } catch {
                Task {
                    await EventLog.shared.log("notif.cache.err", [
                        "op": "get",
                        "id": notificationId,
                        "error": "\(error)"
                    ])
                }
                return nil
            }
        }
    }

    /// Delete a cached response
    func delete(_ notificationId: String) -> Bool {
        return queue.sync {
            let fileURL = fileURL(for: notificationId)

            guard fileManager.fileExists(atPath: fileURL.path) else {
                return false
            }

            do {
                try fileManager.removeItem(at: fileURL)
                Task {
                    await EventLog.shared.log("notif.cache.delete", ["id": notificationId])
                }
                return true
            } catch {
                Task {
                    await EventLog.shared.log("notif.cache.err", [
                        "op": "delete",
                        "id": notificationId,
                        "error": "\(error)"
                    ])
                }
                return false
            }
        }
    }

    /// List all cached notification IDs
    func listCached() -> [String] {
        return queue.sync {
            do {
                let files = try fileManager.contentsOfDirectory(
                    at: notificationsDir,
                    includingPropertiesForKeys: nil
                )

                return files
                    .filter { $0.pathExtension == "json" }
                    .map { $0.deletingPathExtension().lastPathComponent }
            } catch {
                return []
            }
        }
    }

    /// Get all cached responses
    func getAllCached() -> [CachedNotificationResponse] {
        let ids = listCached()
        return ids.compactMap { get($0) }
    }

    // MARK: - Private

    private func fileURL(for notificationId: String) -> URL {
        // Sanitize ID for filesystem (replace unsafe chars)
        let safeId = notificationId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")

        return notificationsDir.appendingPathComponent("\(safeId).json")
    }
}
