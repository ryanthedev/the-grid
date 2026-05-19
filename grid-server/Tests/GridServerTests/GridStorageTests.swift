import XCTest
@testable import GridServer

// InMemoryGridStorage: test fake that stores GridRuntimeStateData in memory.
// Conforms to GridStorage so it can be injected into GridState.
// @unchecked Sendable: tests are single-threaded; no real concurrency.
final class InMemoryGridStorage: GridStorage, @unchecked Sendable {

    // Stored data, nil if no save has been called
    private var stored: GridRuntimeStateData? = nil

    // Count of save calls for assertion
    var saveCount: Int = 0

    // Count of load calls for assertion
    var loadCount: Int = 0

    // Optional error to throw on save (for error-path testing)
    var saveError: Error? = nil

    // Optional error to throw on load (for error-path testing)
    var loadError: Error? = nil

    func load() async throws -> GridRuntimeStateData? {
        loadCount += 1
        if let error = loadError {
            throw error
        }
        return stored
    }

    func save(_ data: GridRuntimeStateData) async throws {
        saveCount += 1
        if let error = saveError {
            throw error
        }
        stored = data
    }
}

// Tests for the GridStorage port protocol.
final class GridStorageTests: XCTestCase {

    // DW-4.1: Protocol exists with load and save methods.
    // Verified at compile time: InMemoryGridStorage conforms to GridStorage.
    // This test confirms the fake can be used as the protocol type.
    func test_DW_4_1_protocol_exists_with_load_and_save() async throws {
        let fake = InMemoryGridStorage()
        let port: any GridStorage = fake

        // load returns nil when nothing saved
        let result = try await port.load()
        XCTAssertNil(result, "load() should return nil when no state has been saved")

        // save then load roundtrip
        let data = GridRuntimeStateData(version: 1, spaces: [:], displaySpaces: [:], lastUpdated: Date())
        try await port.save(data)
        let loaded = try await port.load()
        XCTAssertNotNil(loaded, "load() should return data after save")
    }

    // DW-4.4 + DW-4.5: InMemoryGridStorage load with no prior save returns nil.
    func test_DW_4_4_and_4_5_load_empty_returns_nil() async throws {
        let storage = InMemoryGridStorage()
        let result = try await storage.load()
        XCTAssertNil(result, "InMemoryGridStorage should return nil when no data has been saved")
        XCTAssertEqual(storage.loadCount, 1, "load() should have been called once")
    }

    // DW-4.4 + DW-4.5: Save-load roundtrip preserves state data.
    func test_DW_4_4_and_4_5_roundtrip_preserves_state() async throws {
        let storage = InMemoryGridStorage()

        // Build a non-trivial state with one space and one cell
        var spaceData = GridSpaceStateData()
        spaceData.spaceId = "space-1"
        spaceData.currentLayoutId = "two-col"
        spaceData.layoutIndex = 2

        var cellData = GridCellStateData(cellId: "left")
        cellData.windows = [100, 200]
        spaceData.cells = ["left": cellData]

        let original = GridRuntimeStateData(
            version: 1,
            spaces: ["space-1": spaceData],
            displaySpaces: ["display-uuid": ["space-1", "space-2"]],
            lastUpdated: Date(timeIntervalSince1970: 0)
        )

        try await storage.save(original)
        XCTAssertEqual(storage.saveCount, 1, "save() should have been called once")

        let loaded = try await storage.load()
        XCTAssertNotNil(loaded, "load() should return saved data")

        guard let loaded = loaded else { return }

        XCTAssertEqual(loaded.version, 1, "version should be preserved")
        XCTAssertEqual(loaded.spaces["space-1"]?.currentLayoutId, "two-col", "layout ID should be preserved")
        XCTAssertEqual(loaded.spaces["space-1"]?.layoutIndex, 2, "layout index should be preserved")
        XCTAssertEqual(loaded.spaces["space-1"]?.cells["left"]?.windows, [100, 200], "cell windows should be preserved")
        XCTAssertEqual(loaded.displaySpaces["display-uuid"], ["space-1", "space-2"], "display spaces should be preserved")
    }

    // DW-4.3: GridState accepts any GridStorage at init and delegates load to storage.
    // Verifies that load() on GridState calls storage.load() and applies the data.
    func test_DW_4_3_gridstate_delegates_load_to_storage() async {
        let storage = InMemoryGridStorage()

        // Pre-seed storage with a known state
        var spaceData = GridSpaceStateData()
        spaceData.spaceId = "space-99"
        spaceData.currentLayoutId = "three-col"
        let seeded = GridRuntimeStateData(
            version: 1,
            spaces: ["space-99": spaceData],
            displaySpaces: [:],
            lastUpdated: Date()
        )
        try? await storage.save(seeded)
        XCTAssertEqual(storage.saveCount, 1, "seed save should not call GridState save")

        // Create GridState with injected storage
        let gridState = GridState(storage: storage)
        await gridState.load()

        // After load, GridState should reflect the stored state
        let layout = await gridState.getCurrentLayout(spaceID: "space-99")
        XCTAssertEqual(layout, "three-col", "GridState should apply state loaded from storage")
        XCTAssertEqual(storage.loadCount, 1, "GridState.load() should have called storage.load() once")
    }

    // DW-4.3: GridState accepts any GridStorage at init and delegates save to storage.
    // Verifies that markDirty + flush calls storage.save() with current state.
    func test_DW_4_3_gridstate_delegates_save_to_storage() async {
        let storage = InMemoryGridStorage()
        let gridState = GridState(storage: storage)

        // Mutate GridState to mark it dirty
        await gridState.setCurrentLayout(spaceID: "space-10", layoutID: "mono", layoutIndex: 0)

        // flush() forces immediate save (bypasses debounce)
        await gridState.flush()

        // Storage should have received the save
        XCTAssertGreaterThan(storage.saveCount, 0, "GridState.flush() should call storage.save()")

        // Load back to verify the data was passed correctly
        let saved = try? await storage.load()
        XCTAssertNotNil(saved, "Storage should contain the saved data")
        XCTAssertEqual(saved?.spaces["space-10"]?.currentLayoutId, "mono", "save should preserve layout ID")
    }
}
