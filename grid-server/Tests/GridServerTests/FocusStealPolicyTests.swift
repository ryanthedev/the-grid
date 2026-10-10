import XCTest
@testable import GridServer

final class FocusStealPolicyTests: XCTestCase {

    // ska, Island: the app re-keyed its own untitled window after our raise.
    func testAppRekeyingAnotherWindowIsRetriedOnce() {
        XCTAssertTrue(FocusStealPolicy.shouldRetry(want: 20248, got: 25058, appIsFrontmost: true,
                                                   isLatestRequest: true, retriesSoFar: 0))
        XCTAssertFalse(FocusStealPolicy.shouldRetry(want: 20248, got: 25058, appIsFrontmost: true,
                                                    isLatestRequest: true, retriesSoFar: 1))
    }

    func testLandedOrUnreadableFocusIsLeftAlone() {
        XCTAssertFalse(FocusStealPolicy.shouldRetry(want: 20248, got: 20248, appIsFrontmost: true,
                                                    isLatestRequest: true, retriesSoFar: 0))
        XCTAssertFalse(FocusStealPolicy.shouldRetry(want: 20248, got: nil, appIsFrontmost: true,
                                                    isLatestRequest: true, retriesSoFar: 0))
    }

    func testUserMovingOnIsNeverFought() {
        XCTAssertFalse(FocusStealPolicy.shouldRetry(want: 20248, got: 25058, appIsFrontmost: false,
                                                    isLatestRequest: true, retriesSoFar: 0))
        XCTAssertFalse(FocusStealPolicy.shouldRetry(want: 20248, got: 25058, appIsFrontmost: true,
                                                    isLatestRequest: false, retriesSoFar: 0))
    }
}
