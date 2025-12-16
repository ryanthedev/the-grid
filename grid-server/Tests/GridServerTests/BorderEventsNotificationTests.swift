import XCTest
@testable import GridServer

final class BorderEventsNotificationTests: XCTestCase {

    /// Spy that records when BorderEvents methods are called
    class SpyBorderEvents: BorderEvents {
        var spaceChangedCallCount = 0

        override func handleSpaceChanged() {
            spaceChangedCallCount += 1
            super.handleSpaceChanged()
        }
    }

    func testHandleSpaceChangedNotifiesBorderEvents() {
        // Given: StateManager with a spy BorderEvents
        let stateManager = StateManager.shared
        let spy = SpyBorderEvents()
        stateManager.borderEvents = spy

        // When: handleSpaceChanged is called on StateManager
        stateManager.handleSpaceChanged()

        // Wait for async queue to process
        let expectation = XCTestExpectation(description: "Space change notification")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Then: BorderEvents should have been notified
        XCTAssertEqual(spy.spaceChangedCallCount, 1, "StateManager.handleSpaceChanged() should call borderEvents?.handleSpaceChanged()")
    }
}
