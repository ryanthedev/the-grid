import Foundation

// MARK: - NotificationStore

// Actor that owns all notification state. Callers interact only through the
// high-level interface; storage layout, debounce mechanics, and atomic file
// writes are fully hidden.
actor NotificationStore {

    // MARK: - Storage

    // O(1) lookup for targeted mutations (dismiss, pin, priority)
    private var byID: [String: GridNotification] = [:]
    // Preserves insertion order for stable list rendering
    private var orderedIDs: [String] = []

    // MARK: - Persistence

    private let storePath: String
    private var saveTask: Task<Void, Never>?
    private var isDirty: Bool = false
    private let debounceInterval: Duration = .milliseconds(500)
    private static let storeVersion = 1

    // MARK: - Init

    // Production init: derives path from XDG state directory.
    init() {
        storePath = "\(XDG.stateHome)/thegrid/notifications.json"
    }

    // Test-only init: accepts an explicit path so tests never touch real state.
    init(storePath: String) {
        self.storePath = storePath
    }

    // MARK: - Load

    // Reads persisted state from disk. Called once at app startup.
    // On missing file: silent no-op (fresh start).
    // On decode error: logs and keeps empty state rather than crashing.
    func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storePath) else {
            jlog("notify.store.load.new")
            return
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: storePath))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(GridNotificationStoreData.self, from: data)

            // Rebuild in-memory storage from the decoded flat array
            byID = [:]
            for notification in decoded.notifications {
                byID[notification.id] = notification
            }

            // Restore order, validating for consistency:
            // - Drop IDs not present in byID (stale references)
            // - Append any byID keys missing from orderedIDs
            var validatedIDs = decoded.orderedIDs.filter { byID[$0] != nil }
            let orderedSet = Set(validatedIDs)
            let orphaned = byID.keys.filter { !orderedSet.contains($0) }.sorted()
            validatedIDs.append(contentsOf: orphaned)
            orderedIDs = validatedIDs

            jlog("notify.store.load", data: ["count": byID.count])
        } catch {
            jlog("err.notify.store.load", msg: "\(error)")
            // Keep empty state; don't propagate the error
        }
    }

    // MARK: - Persistence (debounced)

    // Schedules a deferred write. Multiple rapid mutations collapse into one write.
    private func markDirty() {
        isDirty = true
        saveTask?.cancel()
        saveTask = Task {
            do {
                try await Task.sleep(for: debounceInterval)
                self.persistNow()
            } catch {
                // Cancelled -- a newer save is pending; nothing to do
            }
        }
    }

    // Writes current state atomically. Callers: markDirty (debounced), flush (immediate).
    private func persistNow() {
        guard isDirty else { return }
        isDirty = false

        let now = Date()
        let storeData = GridNotificationStoreData(
            version: NotificationStore.storeVersion,
            notifications: orderedIDs.compactMap { byID[$0] },
            orderedIDs: orderedIDs,
            lastUpdated: now
        )

        // Declare tmpPath before the do block so the catch block can reference it
        // for cleanup if the rename fails.
        let tmpPath = storePath + ".tmp"
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(storeData)

            let fm = FileManager.default
            let dir = (storePath as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

            try data.write(to: URL(fileURLWithPath: tmpPath))

            // POSIX rename atomically replaces destination
            if rename(tmpPath, storePath) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }

            jlog("notify.store.save", data: ["count": byID.count])
        } catch {
            // Re-mark dirty so the next mutation retries the write.
            // Remove the .tmp file if it was created before the failure.
            try? FileManager.default.removeItem(atPath: tmpPath)
            isDirty = true
            jlog("err.notify.store.save", msg: "\(error)")
        }
    }

    // Forces an immediate write if dirty. Called on app shutdown.
    func flush() {
        if isDirty {
            persistNow()
        }
    }

    // MARK: - CRUD

    // Adds a notification. Idempotent: if the id already exists, returns the
    // stored notification unchanged without modifying state.
    @discardableResult
    func add(_ notification: GridNotification) -> GridNotification {
        if let existing = byID[notification.id] {
            return existing
        }
        byID[notification.id] = notification
        orderedIDs.append(notification.id)
        markDirty()
        return notification
    }

    // Removes a notification by id. Returns true if found and removed.
    @discardableResult
    func remove(id: String) -> Bool {
        guard byID[id] != nil else { return false }
        byID.removeValue(forKey: id)
        orderedIDs.removeAll { $0 == id }
        markDirty()
        return true
    }

    // Returns the notification with the given id, or nil if not found.
    func get(id: String) -> GridNotification? {
        return byID[id]
    }

    // MARK: - Queries

    // Returns notifications matching the filter, sorted:
    //   1. Pinned first (stable within pinned group)
    //   2. Priority descending (urgent > high > normal > low)
    //   3. Timestamp descending (newest first) within the same priority
    func notifications(filter: GridNotificationFilter = .active) -> [GridNotification] {
        // Collect in insertion order for a stable tiebreaker
        var result = orderedIDs.compactMap { byID[$0] }

        // Apply filter predicates
        result = result.filter { n in
            if !filter.includeRead && n.isRead { return false }
            if !filter.includeDismissed && n.isDismissed { return false }
            if !filter.includePinned && n.isPinned { return false }
            if let sources = filter.sources, !sources.contains(n.source) { return false }
            if let minPriority = filter.minPriority, n.priority < minPriority { return false }
            if let searchText = filter.searchText {
                let trimmed = searchText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    let titleMatches = n.title.range(of: trimmed, options: .caseInsensitive) != nil
                    let bodyMatches = n.body.range(of: trimmed, options: .caseInsensitive) != nil
                    if !titleMatches && !bodyMatches { return false }
                }
            }
            return true
        }

        // Sort: pinned first, then priority descending, then timestamp descending
        // (newest first — the flipped ScrollView displays this bottom-up)
        result.sort { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            if a.priority != b.priority { return a.priority > b.priority }
            return a.timestamp > b.timestamp
        }

        return result
    }

    // Returns the count of notifications matching the filter.
    func count(filter: GridNotificationFilter = .active) -> Int {
        return notifications(filter: filter).count
    }

    // MARK: - State Mutations

    // Marks a notification as read. Returns true if state changed.
    @discardableResult
    func markRead(id: String) -> Bool {
        guard var n = byID[id], !n.isRead else { return false }
        n.isRead = true
        byID[id] = n
        markDirty()
        return true
    }

    // Soft-deletes a notification. Dismissed notifications are hidden by the
    // default filter but remain in the store until purged.
    @discardableResult
    func dismiss(id: String) -> Bool {
        guard var n = byID[id], !n.isDismissed else { return false }
        n.isDismissed = true
        byID[id] = n
        markDirty()
        return true
    }

    // Pins a notification so it sorts to the top of the list.
    @discardableResult
    func pin(id: String) -> Bool {
        guard var n = byID[id], !n.isPinned else { return false }
        n.isPinned = true
        byID[id] = n
        markDirty()
        return true
    }

    // Removes the pin from a notification.
    @discardableResult
    func unpin(id: String) -> Bool {
        guard var n = byID[id], n.isPinned else { return false }
        n.isPinned = false
        byID[id] = n
        markDirty()
        return true
    }

    // Changes the priority of a notification. Returns true if changed.
    @discardableResult
    func setPriority(id: String, priority: GridNotificationPriority) -> Bool {
        guard var n = byID[id], n.priority != priority else { return false }
        n.priority = priority
        byID[id] = n
        markDirty()
        return true
    }

    // MARK: - Bulk Operations

    // Dismisses all notifications matching the filter.
    // Returns the count of newly-dismissed notifications.
    @discardableResult
    func bulkDismiss(filter: GridNotificationFilter = .active) -> Int {
        let targets = notifications(filter: filter)
        var dismissedCount = 0
        for notification in targets {
            if dismiss(id: notification.id) {
                dismissedCount += 1
            }
        }
        return dismissedCount
    }

    // Marks all notifications matching the filter as read.
    // Returns the count of newly-read notifications.
    @discardableResult
    func bulkMarkRead(filter: GridNotificationFilter = .active) -> Int {
        let targets = notifications(filter: filter)
        var readCount = 0
        for notification in targets {
            if markRead(id: notification.id) {
                readCount += 1
            }
        }
        return readCount
    }

    // Hard-removes all dismissed notifications from the store.
    // Returns the count of removed notifications.
    @discardableResult
    func purge() -> Int {
        let dismissedIDs = byID.values.filter { $0.isDismissed }.map { $0.id }
        for id in dismissedIDs {
            byID.removeValue(forKey: id)
            orderedIDs.removeAll { $0 == id }
        }
        if dismissedIDs.count > 0 {
            markDirty()
        }
        return dismissedIDs.count
    }

    // Hard-removes all notifications from the store.
    func clear() {
        byID = [:]
        orderedIDs = []
        markDirty()
    }

    // MARK: - Trim

    // Removes the oldest non-pinned notifications beyond maxCount.
    // Pinned notifications are always preserved.
    // Returns count of removed notifications.
    @discardableResult
    func trim(to maxCount: Int) -> Int {
        guard maxCount > 0 else { return 0 }

        // Build ordered list of non-pinned IDs (oldest first = front of orderedIDs)
        let unpinnedIDs = orderedIDs.filter { byID[$0]?.isPinned == false }

        let excess = unpinnedIDs.count - maxCount
        guard excess > 0 else { return 0 }

        // Remove oldest unpinned notifications (first in insertion order)
        let toRemove = Array(unpinnedIDs.prefix(excess))
        for id in toRemove {
            byID.removeValue(forKey: id)
            orderedIDs.removeAll { $0 == id }
        }

        if !toRemove.isEmpty {
            markDirty()
        }

        return toRemove.count
    }
}
