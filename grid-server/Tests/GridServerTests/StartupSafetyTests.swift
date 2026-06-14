import XCTest
import Foundation
@testable import GridServer

/// DW-7.3 (#49) handler-registration readiness + DW-7.4 (#45) load-does-not-clobber.
final class StartupSafetyTests: XCTestCase {

    // MARK: - DW-7.3 (#49) startup 404 window

    func test_DW_7_3_grid_method_before_ready_is_retryable_not_404() {
        let mh = MessageHandler()
        XCTAssertFalse(mh.isReady())

        let exp = expectation(description: "response")
        let req = Request(id: "1", method: "grid.focus", params: nil)
        mh.handle(request: req) { response in
            // Before finalizeRegistration, an unregistered grid.* method must be
            // a retryable -32000, NOT a permanent -32601.
            XCTAssertEqual(response.error?.code, -32000)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func test_DW_7_3_unknown_method_after_ready_is_404() {
        let mh = MessageHandler()
        mh.finalizeRegistration()
        XCTAssertTrue(mh.isReady())

        let exp = expectation(description: "response")
        let req = Request(id: "2", method: "grid.totally.unknown", params: nil)
        mh.handle(request: req) { response in
            XCTAssertEqual(response.error?.code, -32601)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func test_DW_7_3_registered_method_resolves() {
        let mh = MessageHandler()
        mh.register(method: "grid.ping") { req, completion in
            completion(Response(id: req.id, result: AnyCodable("pong")))
        }
        mh.finalizeRegistration()

        let exp = expectation(description: "response")
        mh.handle(request: Request(id: "3", method: "grid.ping", params: nil)) { response in
            XCTAssertNil(response.error)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    // MARK: - DW-7.4 (#45) load does not clobber early in-memory state

    func test_DW_7_4_load_does_not_clobber_significant_in_memory_state() async {
        // Persisted snapshot: space "5" laid out with layout "A".
        var persisted = GridRuntimeStateData()
        persisted.spaces["5"] = {
            var s = GridSpaceStateData(); s.spaceId = "5"; s.currentLayoutId = "A"; return s
        }()
        let storage = InMemoryGridStorage()
        try? await storage.save(persisted)

        let state = GridState(storage: storage)
        // Simulate an early windowCreated handled before load() completes:
        // assign a window into space "5" cell "0".
        await state.assignWindow(42, toCellID: "0", inSpace: "5")

        // Now load() runs late.
        await state.load()

        // The early assignment MUST survive — load must not wholesale-replace a
        // space that already holds significant in-memory state.
        let assignments = await state.getWindowAssignments(spaceID: "5")
        XCTAssertEqual(assignments["0"], [42], "early in-memory assignment must not be clobbered by late load")
    }

    func test_DW_7_4_load_populates_when_memory_empty() async {
        var persisted = GridRuntimeStateData()
        persisted.spaces["7"] = {
            var s = GridSpaceStateData(); s.spaceId = "7"; s.currentLayoutId = "B"; return s
        }()
        let storage = InMemoryGridStorage()
        try? await storage.save(persisted)

        let state = GridState(storage: storage)
        // No in-memory mutations: load should populate normally.
        await state.load()
        let layout = await state.getCurrentLayout(spaceID: "7")
        XCTAssertEqual(layout, "B")
    }
}
