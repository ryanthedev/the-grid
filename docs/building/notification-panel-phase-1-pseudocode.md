# Pseudocode: Phase 1 - Notification data model and persistence

## Files to Create

- `grid-server/Sources/GridServer/Notifications/Notification.swift`
- `grid-server/Sources/GridServer/Notifications/NotificationStore.swift`
- `grid-server/Tests/GridServerTests/NotificationStoreTests.swift`

---

## Design Notes

### Design-It-Twice Summary

Three approaches were evaluated:
- A: Flat actor with dict-by-id + ordered-id-array (chosen)
- B: Actor wrapping a value-type struct (testability benefit, extra layer)
- C: Actor with single array storage (simpler but O(n) id lookup)

Chose A because it directly mirrors the `GridState` pattern, keeps the actor interface deep (callers see only high-level operations), and hides all storage details. Dict gives O(1) lookup for targeted mutations (dismiss/pin/priority by id). The ordered array preserves insertion order for stable list rendering.

### Information Hiding

Callers never see:
- Storage representation (`[String: Notification]` dict + `[String]` order array)
- Debounce task management
- File path construction
- JSON encoder/decoder configuration
- Atomic write mechanism (`.tmp` + `rename`)

### Module Depth Assessment

Interface: ~11 methods hiding ~150 lines of persistence + encoding + debounce logic.
Common case: `add(notification)` and `notifications(filter:)` -- both single-call, no wrapper needed.

---

## Pseudocode

### Notification.swift

```
// Notification priority -- ordered low to high for sort comparisons
enum NotificationPriority: String, Codable, Comparable {
    case low, normal, high, urgent
    // Implement Comparable via raw value ordering [low=0, normal=1, high=2, urgent=3]
    // Use a static order array, look up index, compare indices
}

// The three supported action types
enum NotificationAction: Codable {
    case focusWindow(windowID: UInt32)
    case runShellCommand(command: String)
    case openURL(url: String)
    // Encode/decode using a "type" discriminant field + associated payload
    // CodingKeys: type, windowID, command, url
    // Encode: write type string + relevant payload field
    // Decode: read type, switch, decode payload field
}

// Core notification model -- all fields Codable
struct Notification: Codable, Identifiable {
    let id: String              // UUID string, set at creation, immutable
    let source: String          // "rpc", "internal", "file", "pipe" -- caller-defined label
    let title: String
    var body: String            // Optional descriptive text, may be empty
    var priority: NotificationPriority
    let timestamp: Date         // Set at creation, immutable
    var isRead: Bool            // false by default
    var isPinned: Bool          // false by default
    var isDismissed: Bool       // false by default
    var action: NotificationAction?  // nil means no action

    // Designated init with sensible defaults
    init(
        id: String = UUID().uuidString,
        source: String,
        title: String,
        body: String = "",
        priority: NotificationPriority = .normal,
        timestamp: Date = Date(),
        isRead: Bool = false,
        isPinned: Bool = false,
        isDismissed: Bool = false,
        action: NotificationAction? = nil
    )
    // Just assign all fields -- no logic
}

// Filter criteria for querying notifications
struct NotificationFilter {
    var includeRead: Bool = true
    var includeDismissed: Bool = false  // dismissed are hidden by default
    var includePinned: Bool = true
    var sources: [String]? = nil        // nil = all sources
    var minPriority: NotificationPriority? = nil  // nil = all priorities
    var searchText: String? = nil       // nil = no text filter, matches title+body case-insensitive

    // Convenience: default filter (active notifications, not dismissed, all else)
    static var active: NotificationFilter { NotificationFilter() }
    // Convenience: all notifications including dismissed
    static var all: NotificationFilter { NotificationFilter(includeDismissed: true) }
}

// Persisted container -- mirrors GridRuntimeStateData pattern
struct NotificationStoreData: Codable {
    var version: Int = 1
    var notifications: [Notification] = []
    var orderedIDs: [String] = []   // Preserves insertion order
    var lastUpdated: Date = Date()
}
```

### NotificationStore.swift

```
actor NotificationStore {
    // MARK: - Storage
    // Dict for O(1) lookup by id
    private var byID: [String: Notification] = [:]
    // Ordered list of IDs -- preserves insertion order for stable rendering
    private var orderedIDs: [String] = []

    // MARK: - Persistence
    private let storePath: String
    private var saveTask: Task<Void, Never>?
    private var isDirty: Bool = false
    private let debounceInterval: Duration = .milliseconds(500)
    private static let storeVersion = 1

    // MARK: - Shared Instance (mirrors StateManager pattern)
    private static let _shared = NotificationStore()
    static var shared: NotificationStore { _shared }

    // MARK: - Init

    init() {
        storePath = "\(XDG.stateHome)/thegrid/notifications.json"
    }

    // MARK: - Load (called at server startup)

    func load() {
        // If file does not exist at storePath, log "notify.store.load.new" and return
        // Read file data from storePath
        // Decode NotificationStoreData using JSONDecoder with ISO8601 date strategy
        // On success:
        //   Rebuild byID dict from decoded.notifications
        //   Set orderedIDs = decoded.orderedIDs
        //   Validate orderedIDs: remove any IDs not present in byID
        //   Add any byID keys missing from orderedIDs (append in sorted order for determinism)
        //   Log "notify.store.load" with count
        // On decode error: log "err.notify.store.load" with error description, keep empty state
    }

    // MARK: - Persistence (debounced, same as GridState)

    private func markDirty() {
        isDirty = true
        Cancel saveTask if it exists
        saveTask = new Task that:
            sleeps for debounceInterval
            on success: calls persistNow()
            on cancellation: does nothing (newer save is pending)
    }

    private func persistNow() {
        Guard isDirty else return
        isDirty = false
        lastUpdated = now

        Build NotificationStoreData:
            version = storeVersion
            notifications = orderedIDs.compactMap { byID[$0] }
            orderedIDs = self.orderedIDs
            lastUpdated = now

        Encode with JSONEncoder:
            outputFormatting = [.prettyPrinted, .sortedKeys]
            dateEncodingStrategy = .iso8601

        Ensure directory exists (create with intermediates)
        Write to tmpPath = storePath + ".tmp"
        Call rename(tmpPath, storePath) -- atomic replace
        On rename error: throw and re-set isDirty = true
        Log "notify.store.save" on success
        Log "err.notify.store.save" on error, re-set isDirty = true
    }

    func flush() {
        // Immediate write if dirty -- called on server shutdown
        If isDirty: call persistNow()
    }

    // MARK: - CRUD

    // Add a new notification
    // If id already exists, this is a no-op (idempotent)
    // Returns the notification as stored
    func add(_ notification: Notification) -> Notification {
        Guard byID[notification.id] == nil else return byID[notification.id]!
        byID[notification.id] = notification
        orderedIDs.append(notification.id)
        markDirty()
        return notification
    }

    // Remove notification by id
    // Returns true if found and removed, false if not found
    @discardableResult
    func remove(id: String) -> Bool {
        Guard byID[id] != nil else return false
        byID.removeValue(forKey: id)
        orderedIDs.removeAll { $0 == id }
        markDirty()
        return true
    }

    // Get a single notification by id
    func get(id: String) -> Notification? {
        return byID[id]
    }

    // MARK: - Queries

    // Return notifications matching filter, in order:
    //   1. Pinned first (stable sort within pinned)
    //   2. By priority descending (urgent > high > normal > low)
    //   3. By timestamp descending (newest first) within same priority
    // orderedIDs preserves insertion order as tiebreaker
    func notifications(filter: NotificationFilter = .active) -> [Notification] {
        Collect all notifications from orderedIDs (preserving insertion order)
        Apply filter predicates:
            If !filter.includeRead: exclude isRead == true
            If !filter.includeDismissed: exclude isDismissed == true
            If !filter.includePinned: exclude isPinned == true
            If filter.sources != nil: exclude notifications whose source not in filter.sources
            If filter.minPriority != nil: exclude notifications with priority < minPriority
            If filter.searchText != nil (non-empty after trim):
                keep only notifications where title or body contains searchText (case-insensitive)
        Sort results:
            Primary: isPinned descending (pinned first)
            Secondary: priority descending
            Tertiary: timestamp descending (newest first)
        Return sorted filtered array
    }

    // Count matching filter (avoids materializing full array when only count needed)
    func count(filter: NotificationFilter = .active) -> Int {
        return notifications(filter: filter).count
    }

    // MARK: - State Mutations

    // Mark a notification as read
    // Returns true if state changed, false if already read or not found
    @discardableResult
    func markRead(id: String) -> Bool {
        Guard var n = byID[id], !n.isRead else return false
        n.isRead = true
        byID[id] = n
        markDirty()
        return true
    }

    // Dismiss a notification (soft delete -- remains in store, excluded by default filter)
    @discardableResult
    func dismiss(id: String) -> Bool {
        Guard var n = byID[id], !n.isDismissed else return false
        n.isDismissed = true
        byID[id] = n
        markDirty()
        return true
    }

    // Pin a notification
    @discardableResult
    func pin(id: String) -> Bool {
        Guard var n = byID[id], !n.isPinned else return false
        n.isPinned = true
        byID[id] = n
        markDirty()
        return true
    }

    // Unpin a notification
    @discardableResult
    func unpin(id: String) -> Bool {
        Guard var n = byID[id], n.isPinned else return false
        n.isPinned = false
        byID[id] = n
        markDirty()
        return true
    }

    // Set priority of a notification
    // Returns true if changed, false if same priority or not found
    @discardableResult
    func setPriority(id: String, priority: NotificationPriority) -> Bool {
        Guard var n = byID[id], n.priority != priority else return false
        n.priority = priority
        byID[id] = n
        markDirty()
        return true
    }

    // MARK: - Bulk Operations

    // Dismiss all notifications matching filter
    // Returns count of newly-dismissed notifications
    @discardableResult
    func bulkDismiss(filter: NotificationFilter = .active) -> Int {
        let targets = notifications(filter: filter)
        var count = 0
        For each notification in targets:
            If dismiss(id: notification.id): count += 1
        // markDirty was called per-dismiss but that's fine -- debounce absorbs the fan-out
        return count
    }

    // Mark all matching notifications as read
    // Returns count changed
    @discardableResult
    func bulkMarkRead(filter: NotificationFilter = .active) -> Int {
        let targets = notifications(filter: filter)
        var count = 0
        For each notification in targets:
            If markRead(id: notification.id): count += 1
        return count
    }

    // Remove all dismissed notifications (hard purge)
    // Returns count removed
    @discardableResult
    func purge() -> Int {
        let dismissedIDs = byID.values.filter { $0.isDismissed }.map { $0.id }
        For each id in dismissedIDs:
            byID.removeValue(forKey: id)
            orderedIDs.removeAll { $0 == id }
        If dismissedIDs.count > 0: markDirty()
        return dismissedIDs.count
    }

    // Remove ALL notifications (hard clear)
    func clear() {
        byID = [:]
        orderedIDs = []
        markDirty()
    }
}
```

### NotificationStoreTests.swift

```
// Tests use async/await because NotificationStore is an actor
// Each test creates a fresh NotificationStore with an isolated temp directory
// (set XDG_STATE_HOME env var to a temp dir to isolate from real state)

final class NotificationStoreTests: XCTestCase {

    // Helper: create a fresh store with a temp directory for persistence
    // Sets up a tmp dir, passes it via a custom NotificationStore init that accepts a path
    // NOTE: NotificationStore will need a testable init(path:) OR tests use XDG_STATE_HOME env override
    // Prefer the env override approach to avoid changing the production API

    // --- CRUD Tests ---

    func testAddNotification() async {
        // Create store
        // Add a notification with known fields
        // Call get(id:) and assert all fields match
        // Call notifications() and assert count == 1
    }

    func testAddIdempotent() async {
        // Add same notification twice (same id)
        // Assert count is still 1
        // Assert second add returns the stored notification unchanged
    }

    func testRemoveNotification() async {
        // Add two notifications
        // Remove one by id, assert returns true
        // Assert notifications() count == 1
        // Assert get(id:) returns nil for removed id
        // Remove same id again, assert returns false
    }

    func testGetByID() async {
        // Add notification
        // get(id:) returns correct notification
        // get(id: "nonexistent") returns nil
    }

    // --- Filter Tests ---

    func testFilterExcludesDismissed() async {
        // Add two notifications
        // Dismiss one
        // notifications(filter: .active) returns only undismissed
        // notifications(filter: .all) returns both
    }

    func testFilterByPriority() async {
        // Add: low, normal, high, urgent
        // Filter with minPriority = .high returns only high + urgent
    }

    func testFilterBySource() async {
        // Add notifications from "rpc" and "internal"
        // Filter sources = ["rpc"] returns only rpc notifications
    }

    func testFilterBySearchText() async {
        // Add: title="Build succeeded", title="Test failed"
        // Filter searchText="fail" returns only "Test failed"
        // Filter searchText="FAIL" (uppercase) also returns "Test failed" (case-insensitive)
    }

    // --- State Mutation Tests ---

    func testMarkRead() async {
        // Add unread notification
        // markRead returns true, isRead == true
        // markRead again returns false (no change)
    }

    func testDismiss() async {
        // Add notification
        // dismiss returns true, isDismissed == true
        // Not in active filter result
        // dismiss again returns false
    }

    func testPinUnpin() async {
        // Add notification
        // pin returns true, isPinned == true
        // pin again returns false
        // unpin returns true, isPinned == false
        // unpin again returns false
    }

    func testSetPriority() async {
        // Add notification with .normal
        // setPriority to .high returns true, priority == .high
        // setPriority to .high again returns false
    }

    // --- Ordering Tests ---

    func testPinnedAppearFirst() async {
        // Add A (normal, not pinned), B (normal, pinned)
        // notifications() returns [B, A] (pinned first)
    }

    func testHigherPriorityBeforeLower() async {
        // Add A (low), B (urgent), C (normal)
        // notifications() order: B (urgent), C (normal), A (low)
    }

    // --- Bulk Operation Tests ---

    func testBulkDismiss() async {
        // Add 3 notifications
        // bulkDismiss() returns 3
        // notifications(filter: .active) returns []
        // notifications(filter: .all) returns 3 (they still exist, just dismissed)
    }

    func testBulkMarkRead() async {
        // Add 3 unread notifications
        // bulkMarkRead() returns 3
        // All notifications have isRead == true
        // bulkMarkRead() again returns 0 (nothing changed)
    }

    func testPurge() async {
        // Add 3 notifications, dismiss 2
        // purge() returns 2
        // notifications(filter: .all) returns 1 (the undismissed one)
        // get(id:) for purged IDs returns nil
    }

    // --- Persistence Round-Trip Tests ---

    func testPersistenceRoundTrip() async throws {
        // Create store in a temp directory
        // Add several notifications with different fields (including actions)
        // flush() to force immediate write
        // Create a new store pointing at same temp directory
        // load() on new store
        // Assert all notifications present with all fields correct
        // Assert orderedIDs match
    }

    func testPersistenceWithActions() async throws {
        // Add notification with focusWindow action
        // Add notification with runShellCommand action
        // Add notification with openURL action
        // Add notification with nil action
        // flush(), reload
        // Assert each action round-trips correctly
    }

    func testPersistenceEmptyStore() async throws {
        // Create store, flush without adding anything
        // Load into new store
        // Assert count == 0 (no crash on empty file)
    }
}
```

---

## Key Implementation Notes

### NotificationAction Codable Strategy

Use a keyed container with a `"type"` discriminant string, plus optional payload fields:

```
Encode:
  write "type": "focusWindow" | "runShellCommand" | "openURL"
  write payload field: "windowID", "command", or "url"

Decode:
  read "type"
  switch:
    "focusWindow" -> decode "windowID" as UInt32
    "runShellCommand" -> decode "command" as String
    "openURL" -> decode "url" as String
    unknown -> throw DecodingError
```

### NotificationPriority Comparable

```
private static let order: [NotificationPriority] = [.low, .normal, .high, .urgent]

static func < (lhs, rhs) -> Bool {
    guard let l = order.firstIndex(of: lhs),
          let r = order.firstIndex(of: rhs) else { return false }
    return l < r
}
```

### Test Isolation for Persistence

Inject a custom `storePath` via a package-internal initializer `init(storePath: String)` used only in tests. The production `shared` singleton uses the default XDG path. This avoids any test touching real state files and avoids environment variable manipulation.

Mark the test-only init as `internal` (not public). Since tests use `@testable import GridServer`, they can access internal members.

### Date Encoding

Use `.iso8601` date encoding strategy (simpler than the custom formatter in `GridState`). Notifications don't need microsecond precision in timestamps.

---

## PRE-GATE Status

- [x] Discovery complete
- [x] Design-it-twice applied (3 approaches evaluated)
- [x] Depth evaluation: 11 methods hiding debounce + atomic write + encoding + storage details
- [x] Pseudocode complete
- [ ] Ready for implementation
