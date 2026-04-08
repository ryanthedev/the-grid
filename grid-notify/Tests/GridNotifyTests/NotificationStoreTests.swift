import XCTest
@testable import GridNotify

final class NotificationStoreTests: XCTestCase {

    private func makeTempPath() -> String {
        let dir = NSTemporaryDirectory()
        return "\(dir)/gridnotify-test-\(UUID().uuidString).json"
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + ".tmp")
    }

    func testAddAndGet() async {
        let path = makeTempPath()
        defer { cleanup(path) }

        let store = NotificationStore(storePath: path)
        let n = GridNotification(id: "test-1", source: "test", title: "Hello")
        await store.add(n)

        let fetched = await store.get(id: "test-1")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.title, "Hello")
        XCTAssertEqual(fetched?.source, "test")

        let count = await store.count()
        XCTAssertEqual(count, 1)
    }

    func testDismissHidesFromActive() async {
        let path = makeTempPath()
        defer { cleanup(path) }

        let store = NotificationStore(storePath: path)
        let n = GridNotification(id: "test-2", source: "test", title: "Dismiss me")
        await store.add(n)
        await store.dismiss(id: "test-2")

        // Active filter excludes dismissed
        let active = await store.count(filter: .active)
        XCTAssertEqual(active, 0)

        // All filter includes dismissed
        let all = await store.count(filter: .all)
        XCTAssertEqual(all, 1)
    }

    func testPersistAndReload() async {
        let path = makeTempPath()
        defer { cleanup(path) }

        // Create and persist
        let store1 = NotificationStore(storePath: path)
        let n = GridNotification(id: "persist-1", source: "test", title: "Persistent")
        await store1.add(n)
        await store1.flush()

        // Reload into a new store
        let store2 = NotificationStore(storePath: path)
        await store2.load()

        let fetched = await store2.get(id: "persist-1")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.title, "Persistent")

        let count = await store2.count()
        XCTAssertEqual(count, 1)
    }

    func testPinSortsFirst() async {
        let path = makeTempPath()
        defer { cleanup(path) }

        let store = NotificationStore(storePath: path)
        let n1 = GridNotification(id: "pin-1", source: "test", title: "First")
        let n2 = GridNotification(id: "pin-2", source: "test", title: "Second")
        await store.add(n1)
        await store.add(n2)
        await store.pin(id: "pin-2")

        let results = await store.notifications(filter: .active)
        XCTAssertEqual(results.count, 2)
        // Pinned notification should sort first
        XCTAssertEqual(results[0].id, "pin-2")
    }

    func testFilterBySearchText() async {
        let path = makeTempPath()
        defer { cleanup(path) }

        let store = NotificationStore(storePath: path)
        await store.add(GridNotification(id: "search-1", source: "test", title: "hello world"))
        await store.add(GridNotification(id: "search-2", source: "test", title: "goodbye"))

        var filter = GridNotificationFilter.active
        filter.searchText = "hello"
        let results = await store.notifications(filter: filter)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "search-1")
    }

    // MARK: - Upsert Tests

    func testUpsertUpdatesExisting() async {
        let path = makeTempPath()
        defer { cleanup(path) }

        let store = NotificationStore(storePath: path)
        let n1 = GridNotification(id: "upsert-1", source: "test", title: "Sarah", body: "hello", ttl: 60)
        await store.add(n1)

        // Upsert with same id but different body
        let n2 = GridNotification(id: "upsert-1", source: "test", title: "Sarah", body: "hey there", ttl: 60)
        await store.upsert(n2)

        let fetched = await store.get(id: "upsert-1")
        XCTAssertNotNil(fetched)
        // Body should be replaced
        XCTAssertEqual(fetched?.body, "hey there")
        // Group count should be 2 (original add + one upsert)
        XCTAssertEqual(fetched?.groupCount, 2)
        // Should still be only 1 notification in the store
        let count = await store.count()
        XCTAssertEqual(count, 1)
    }

    func testUpsertResetsTTL() async {
        let path = makeTempPath()
        defer { cleanup(path) }

        let store = NotificationStore(storePath: path)
        let n1 = GridNotification(id: "ttl-1", source: "test", title: "Sarah", body: "hi", ttl: 60)
        await store.add(n1)

        // Upsert to reset TTL
        let n2 = GridNotification(id: "ttl-1", source: "test", title: "Sarah", body: "hello again", ttl: 60)
        await store.upsert(n2)

        let fetched = await store.get(id: "ttl-1")
        XCTAssertNotNil(fetched)
        // ttlResetDate should be set after upsert
        XCTAssertNotNil(fetched?.ttlResetDate)
    }

    func testUpsertInsertsWhenNew() async {
        let path = makeTempPath()
        defer { cleanup(path) }

        let store = NotificationStore(storePath: path)
        // Upsert with a new id (no prior add)
        let n = GridNotification(id: "new-1", source: "test", title: "Alice", body: "first")
        await store.upsert(n)

        let fetched = await store.get(id: "new-1")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.title, "Alice")
        // Group count should be 1 (no prior notification to bump)
        XCTAssertEqual(fetched?.groupCount, 1)
        let count = await store.count()
        XCTAssertEqual(count, 1)
    }

    func testUpsertClearsDismissed() async {
        let path = makeTempPath()
        defer { cleanup(path) }

        let store = NotificationStore(storePath: path)
        let n1 = GridNotification(id: "dismiss-1", source: "test", title: "Bob", body: "hey")
        await store.add(n1)
        await store.dismiss(id: "dismiss-1")

        // Dismissed notification should not be in active results
        let activeBefore = await store.count(filter: .active)
        XCTAssertEqual(activeBefore, 0)

        // Upsert should un-dismiss it
        let n2 = GridNotification(id: "dismiss-1", source: "test", title: "Bob", body: "still here")
        await store.upsert(n2)

        let activeAfter = await store.count(filter: .active)
        XCTAssertEqual(activeAfter, 1)
        let fetched = await store.get(id: "dismiss-1")
        XCTAssertEqual(fetched?.isDismissed, false)
    }

    func testAddWithoutIdCreatesDistinctEntries() async {
        let path = makeTempPath()
        defer { cleanup(path) }

        let store = NotificationStore(storePath: path)
        // Simulate two pipe notifications without explicit id (different UUIDs)
        let n1 = GridNotification(id: UUID().uuidString, source: "test", title: "test", body: "a")
        let n2 = GridNotification(id: UUID().uuidString, source: "test", title: "test", body: "b")
        await store.add(n1)
        await store.add(n2)

        // Should create two separate notifications
        let count = await store.count()
        XCTAssertEqual(count, 2)
    }
}
