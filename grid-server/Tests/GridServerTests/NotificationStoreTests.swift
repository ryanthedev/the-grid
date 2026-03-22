import XCTest
@testable import GridServer

// Each test creates an isolated store backed by a unique temp directory so
// tests never touch real state files and never interfere with each other.
final class NotificationStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore() -> NotificationStore {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        return NotificationStore(storePath: "\(tmpDir)/notifications.json")
    }

    private func makeNotification(
        id: String = UUID().uuidString,
        source: String = "rpc",
        title: String = "Test",
        body: String = "",
        priority: GridNotificationPriority = .normal,
        timestamp: Date = Date(),
        action: GridNotificationAction? = nil
    ) -> GridNotification {
        return GridNotification(
            id: id,
            source: source,
            title: title,
            body: body,
            priority: priority,
            timestamp: timestamp,
            action: action
        )
    }

    // MARK: - CRUD Tests

    func testAddNotification() async {
        let store = makeStore()
        let n = makeNotification(source: "rpc", title: "Hello", body: "World", priority: .high)

        let returned = await store.add(n)
        XCTAssertEqual(returned.id, n.id)
        XCTAssertEqual(returned.title, "Hello")
        XCTAssertEqual(returned.body, "World")
        XCTAssertEqual(returned.priority, .high)

        let fetched = await store.get(id: n.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.title, "Hello")

        let all = await store.notifications(filter: .active)
        XCTAssertEqual(all.count, 1)
    }

    func testAddIdempotent() async {
        let store = makeStore()
        let n = makeNotification(id: "fixed-id", title: "Original")

        await store.add(n)

        // Second add with same id: modifying the title should have no effect
        let modified = GridNotification(id: "fixed-id", source: "rpc", title: "Modified")
        let returned = await store.add(modified)

        // Returns the first-stored notification, not the duplicate
        XCTAssertEqual(returned.title, "Original")

        let count = await store.count(filter: .all)
        XCTAssertEqual(count, 1)
    }

    func testRemoveNotification() async {
        let store = makeStore()
        let a = makeNotification(title: "A")
        let b = makeNotification(title: "B")

        await store.add(a)
        await store.add(b)

        let removedA = await store.remove(id: a.id)
        XCTAssertTrue(removedA)

        let remaining = await store.notifications(filter: .active)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].title, "B")

        let nilFetch = await store.get(id: a.id)
        XCTAssertNil(nilFetch)

        // Removing the same id again returns false
        let removedAgain = await store.remove(id: a.id)
        XCTAssertFalse(removedAgain)
    }

    func testGetByID() async {
        let store = makeStore()
        let n = makeNotification(title: "Specific")
        await store.add(n)

        let found = await store.get(id: n.id)
        XCTAssertEqual(found?.title, "Specific")

        let notFound = await store.get(id: "nonexistent-id")
        XCTAssertNil(notFound)
    }

    // MARK: - Filter Tests

    func testFilterExcludesDismissed() async {
        let store = makeStore()
        let a = makeNotification(title: "Keep")
        let b = makeNotification(title: "Dismiss")

        await store.add(a)
        await store.add(b)
        await store.dismiss(id: b.id)

        let active = await store.notifications(filter: .active)
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active[0].title, "Keep")

        let all = await store.notifications(filter: .all)
        XCTAssertEqual(all.count, 2)
    }

    func testFilterByPriority() async {
        let store = makeStore()
        await store.add(makeNotification(title: "low", priority: .low))
        await store.add(makeNotification(title: "normal", priority: .normal))
        await store.add(makeNotification(title: "high", priority: .high))
        await store.add(makeNotification(title: "urgent", priority: .urgent))

        var filter = GridNotificationFilter()
        filter.minPriority = .high
        let result = await store.notifications(filter: filter)

        XCTAssertEqual(result.count, 2)
        let titles = result.map { $0.title }
        XCTAssertTrue(titles.contains("high"))
        XCTAssertTrue(titles.contains("urgent"))
    }

    func testFilterBySource() async {
        let store = makeStore()
        await store.add(makeNotification(source: "rpc", title: "RPC"))
        await store.add(makeNotification(source: "internal", title: "Internal"))
        await store.add(makeNotification(source: "rpc", title: "RPC2"))

        var filter = GridNotificationFilter()
        filter.sources = ["rpc"]
        let result = await store.notifications(filter: filter)

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.source == "rpc" })
    }

    func testFilterBySearchText() async {
        let store = makeStore()
        await store.add(makeNotification(title: "Build succeeded"))
        await store.add(makeNotification(title: "Test failed", body: "assertion error"))

        var filter = GridNotificationFilter()
        filter.searchText = "fail"
        let result = await store.notifications(filter: filter)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].title, "Test failed")

        // Case-insensitive: "FAIL" should also match
        var upperFilter = GridNotificationFilter()
        upperFilter.searchText = "FAIL"
        let upperResult = await store.notifications(filter: upperFilter)
        XCTAssertEqual(upperResult.count, 1)
        XCTAssertEqual(upperResult[0].title, "Test failed")
    }

    // MARK: - State Mutation Tests

    func testMarkRead() async {
        let store = makeStore()
        let n = makeNotification()
        await store.add(n)

        let changed = await store.markRead(id: n.id)
        XCTAssertTrue(changed)

        let fetched = await store.get(id: n.id)
        XCTAssertEqual(fetched?.isRead, true)

        // Marking read again returns false
        let unchanged = await store.markRead(id: n.id)
        XCTAssertFalse(unchanged)
    }

    func testDismiss() async {
        let store = makeStore()
        let n = makeNotification()
        await store.add(n)

        let changed = await store.dismiss(id: n.id)
        XCTAssertTrue(changed)

        let fetched = await store.get(id: n.id)
        XCTAssertEqual(fetched?.isDismissed, true)

        // Should not appear in active filter
        let active = await store.notifications(filter: .active)
        XCTAssertEqual(active.count, 0)

        // Dismissing again returns false
        let unchanged = await store.dismiss(id: n.id)
        XCTAssertFalse(unchanged)
    }

    func testPinUnpin() async {
        let store = makeStore()
        let n = makeNotification()
        await store.add(n)

        let pinned = await store.pin(id: n.id)
        XCTAssertTrue(pinned)
        let afterPin = await store.get(id: n.id)
        XCTAssertEqual(afterPin?.isPinned, true)

        // Pin again returns false
        let pinnedAgain = await store.pin(id: n.id)
        XCTAssertFalse(pinnedAgain)

        let unpinned = await store.unpin(id: n.id)
        XCTAssertTrue(unpinned)
        let afterUnpin = await store.get(id: n.id)
        XCTAssertEqual(afterUnpin?.isPinned, false)

        // Unpin again returns false
        let unpinnedAgain = await store.unpin(id: n.id)
        XCTAssertFalse(unpinnedAgain)
    }

    func testSetPriority() async {
        let store = makeStore()
        let n = makeNotification(priority: .normal)
        await store.add(n)

        let changed = await store.setPriority(id: n.id, priority: .high)
        XCTAssertTrue(changed)
        let afterChange = await store.get(id: n.id)
        XCTAssertEqual(afterChange?.priority, .high)

        // Same priority returns false
        let unchanged = await store.setPriority(id: n.id, priority: .high)
        XCTAssertFalse(unchanged)
    }

    // MARK: - Ordering Tests

    func testPinnedAppearFirst() async {
        let store = makeStore()
        // A added first, B added second
        let a = makeNotification(title: "A")
        let b = makeNotification(title: "B")
        await store.add(a)
        await store.add(b)
        await store.pin(id: b.id)

        let result = await store.notifications(filter: .active)
        XCTAssertEqual(result.count, 2)
        // Pinned B should sort before unpinned A
        XCTAssertEqual(result[0].title, "B")
        XCTAssertEqual(result[1].title, "A")
    }

    func testHigherPriorityBeforeLower() async {
        let store = makeStore()
        // Fixed timestamps to make ordering deterministic
        let baseDate = Date(timeIntervalSince1970: 1_000_000)
        let a = makeNotification(title: "A", priority: .low, timestamp: baseDate)
        let b = makeNotification(title: "B", priority: .urgent, timestamp: baseDate)
        let c = makeNotification(title: "C", priority: .normal, timestamp: baseDate)

        await store.add(a)
        await store.add(b)
        await store.add(c)

        let result = await store.notifications(filter: .active)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].title, "B")
        XCTAssertEqual(result[1].title, "C")
        XCTAssertEqual(result[2].title, "A")
    }

    // MARK: - Bulk Operation Tests

    func testBulkDismiss() async {
        let store = makeStore()
        await store.add(makeNotification(title: "1"))
        await store.add(makeNotification(title: "2"))
        await store.add(makeNotification(title: "3"))

        let dismissed = await store.bulkDismiss()
        XCTAssertEqual(dismissed, 3)

        let active = await store.notifications(filter: .active)
        XCTAssertEqual(active.count, 0)

        // Notifications still exist in the store, just dismissed
        let all = await store.notifications(filter: .all)
        XCTAssertEqual(all.count, 3)
    }

    func testBulkMarkRead() async {
        let store = makeStore()
        await store.add(makeNotification(title: "1"))
        await store.add(makeNotification(title: "2"))
        await store.add(makeNotification(title: "3"))

        let readCount = await store.bulkMarkRead()
        XCTAssertEqual(readCount, 3)

        let all = await store.notifications(filter: .active)
        XCTAssertTrue(all.allSatisfy { $0.isRead })

        // All already read; returns 0
        let readAgain = await store.bulkMarkRead()
        XCTAssertEqual(readAgain, 0)
    }

    func testPurge() async {
        let store = makeStore()
        let keep = makeNotification(title: "Keep")
        let dismiss1 = makeNotification(title: "Dismiss1")
        let dismiss2 = makeNotification(title: "Dismiss2")

        await store.add(keep)
        await store.add(dismiss1)
        await store.add(dismiss2)

        await store.dismiss(id: dismiss1.id)
        await store.dismiss(id: dismiss2.id)

        let purged = await store.purge()
        XCTAssertEqual(purged, 2)

        let all = await store.notifications(filter: .all)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].title, "Keep")

        // Purged notifications no longer fetchable
        let nil1 = await store.get(id: dismiss1.id)
        XCTAssertNil(nil1)
        let nil2 = await store.get(id: dismiss2.id)
        XCTAssertNil(nil2)
    }

    // MARK: - Persistence Round-Trip Tests

    func testPersistenceRoundTrip() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        let storePath = "\(tmpDir)/notifications.json"

        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let store = NotificationStore(storePath: storePath)
        let n1 = GridNotification(
            id: "id-1", source: "rpc", title: "First",
            body: "body1", priority: .high, timestamp: baseDate,
            isRead: false, isPinned: true, isDismissed: false
        )
        let n2 = GridNotification(
            id: "id-2", source: "internal", title: "Second",
            body: "body2", priority: .urgent, timestamp: baseDate,
            isRead: true, isPinned: false, isDismissed: false
        )
        await store.add(n1)
        await store.add(n2)
        await store.flush()

        // Load into a fresh store from the same path
        let store2 = NotificationStore(storePath: storePath)
        await store2.load()

        let fetched1 = await store2.get(id: "id-1")
        XCTAssertNotNil(fetched1)
        XCTAssertEqual(fetched1?.title, "First")
        XCTAssertEqual(fetched1?.body, "body1")
        XCTAssertEqual(fetched1?.priority, .high)
        XCTAssertEqual(fetched1?.isPinned, true)

        let fetched2 = await store2.get(id: "id-2")
        XCTAssertNotNil(fetched2)
        XCTAssertEqual(fetched2?.title, "Second")
        XCTAssertEqual(fetched2?.isRead, true)

        // orderedIDs are preserved (insertion order: id-1, id-2)
        let all = await store2.notifications(filter: .all)
        XCTAssertEqual(all.count, 2)
    }

    func testPersistenceWithActions() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        let storePath = "\(tmpDir)/notifications.json"
        let store = NotificationStore(storePath: storePath)

        let focusN = makeNotification(id: "focus", action: .focusWindow(windowID: 42))
        let shellN = makeNotification(id: "shell", action: .runShellCommand(command: "echo hi"))
        let urlN = makeNotification(id: "url", action: .openURL(url: "https://example.com"))
        let nilN = makeNotification(id: "nil", action: nil)

        await store.add(focusN)
        await store.add(shellN)
        await store.add(urlN)
        await store.add(nilN)
        await store.flush()

        let store2 = NotificationStore(storePath: storePath)
        await store2.load()

        let focus = await store2.get(id: "focus")
        if case .focusWindow(let wid) = focus?.action {
            XCTAssertEqual(wid, 42)
        } else {
            XCTFail("Expected focusWindow action")
        }

        let shell = await store2.get(id: "shell")
        if case .runShellCommand(let cmd) = shell?.action {
            XCTAssertEqual(cmd, "echo hi")
        } else {
            XCTFail("Expected runShellCommand action")
        }

        let url = await store2.get(id: "url")
        if case .openURL(let u) = url?.action {
            XCTAssertEqual(u, "https://example.com")
        } else {
            XCTFail("Expected openURL action")
        }

        let nilAction = await store2.get(id: "nil")
        XCTAssertNil(nilAction?.action)
    }

    func testPersistenceEmptyStore() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        let storePath = "\(tmpDir)/notifications.json"
        let store = NotificationStore(storePath: storePath)

        // Flush with nothing added -- should produce a valid empty file
        await store.flush()

        let store2 = NotificationStore(storePath: storePath)
        await store2.load()

        let count = await store2.count(filter: .all)
        XCTAssertEqual(count, 0)
    }
}
