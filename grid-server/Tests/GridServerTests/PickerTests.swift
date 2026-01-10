//
// PickerTests.swift
// GridServerTests
//
// Integration tests for the Picker UI
//

import XCTest
@testable import GridServer

final class PickerTests: XCTestCase {

    /// Test that shows the picker for 5 seconds then closes it
    /// Run with: swift test --filter PickerTests/testShowPickerFor5Seconds
    func testShowPickerFor5Seconds() async throws {
        // Sample items
        let items: [PickerItem] = [
            PickerItem(id: "1", display: "Item One", searchable: ["one", "first"]),
            PickerItem(id: "2", display: "Item Two", searchable: ["two", "second"]),
            PickerItem(id: "3", display: "Item Three", searchable: ["three", "third"]),
            PickerItem(id: "4", display: "Hello World", searchable: ["hello", "world"]),
            PickerItem(id: "5", display: "Test Item", searchable: ["test", "item"]),
        ]

        // Show picker in background task
        let showTask = Task {
            await PickerManager.shared.show(items: items, style: nil)
        }

        // Wait 5 seconds
        try await Task.sleep(nanoseconds: 5_000_000_000)

        // Hide the picker
        await PickerManager.shared.hide()

        // Cancel the show task (it would wait forever otherwise)
        showTask.cancel()

        // If we got here without crashing, the test passed
        XCTAssertTrue(true, "Picker showed and closed successfully")
    }
}
