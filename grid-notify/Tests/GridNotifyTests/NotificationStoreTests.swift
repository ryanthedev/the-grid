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
}
