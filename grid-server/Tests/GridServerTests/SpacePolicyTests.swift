import XCTest
@testable import GridServer

final class SpacePolicyTests: XCTestCase {
    private func refused(_ decision: SpacePolicy.Decision) -> String? {
        if case .refuse(let why) = decision { return why }
        return nil
    }

    func testSwitchRefusesADisplayShowingFullscreenUnlessTold() {
        let blocked = SpacePolicy.switchDecision(targetType: .user, targetIsCurrent: false, displayCurrentType: .fullscreen, leaveFullscreen: false)
        XCTAssertTrue(refused(blocked)?.contains("fullscreen space") ?? false)
        XCTAssertTrue(refused(blocked)?.contains("leaveFullscreen=true") ?? false)
        XCTAssertEqual(SpacePolicy.switchDecision(targetType: .user, targetIsCurrent: false, displayCurrentType: .fullscreen, leaveFullscreen: true), .proceed)
        XCTAssertEqual(SpacePolicy.switchDecision(targetType: .user, targetIsCurrent: false, displayCurrentType: .user, leaveFullscreen: false), .proceed)
    }

    func testSwitchFailsClosedOnWhatItCannotRead() {
        // Unknown space, unreadable display, and targets that are not user spaces: the override changes none of them.
        XCTAssertNotNil(refused(SpacePolicy.switchDecision(targetType: nil, targetIsCurrent: false, displayCurrentType: .user, leaveFullscreen: true)))
        XCTAssertNotNil(refused(SpacePolicy.switchDecision(targetType: .user, targetIsCurrent: false, displayCurrentType: nil, leaveFullscreen: true)))
        XCTAssertNotNil(refused(SpacePolicy.switchDecision(targetType: .fullscreen, targetIsCurrent: false, displayCurrentType: .user, leaveFullscreen: true)))
        XCTAssertNotNil(refused(SpacePolicy.switchDecision(targetType: .system, targetIsCurrent: false, displayCurrentType: .user, leaveFullscreen: true)))
        XCTAssertNotNil(refused(SpacePolicy.switchDecision(targetType: .user, targetIsCurrent: false, displayCurrentType: .system, leaveFullscreen: true)))
        XCTAssertEqual(SpacePolicy.switchDecision(targetType: .user, targetIsCurrent: true, displayCurrentType: .user, leaveFullscreen: false), .alreadyDone)
    }

    func testPullNeverTakesAWindowOffOrOntoAFullscreenSpace() {
        let off = SpacePolicy.pullDecision(windowSpaces: [(1858, .fullscreen)], target: (3, .user))
        XCTAssertTrue(refused(off)?.contains("never pulled off") ?? false)
        let onto = SpacePolicy.pullDecision(windowSpaces: [(3, .user)], target: (1858, .fullscreen))
        XCTAssertTrue(refused(onto)?.contains("never pulled onto") ?? false)
        // A window listed on several spaces is refused if any one of them is fullscreen, even when it is already on the target.
        XCTAssertNotNil(refused(SpacePolicy.pullDecision(windowSpaces: [(3, .user), (1858, .fullscreen)], target: (3, .user))))
    }

    func testPullProceedsOnlyBetweenUserSpaces() {
        XCTAssertEqual(SpacePolicy.pullDecision(windowSpaces: [(4, .user)], target: (3, .user)), .proceed)
        XCTAssertEqual(SpacePolicy.pullDecision(windowSpaces: [(3, .user)], target: (3, .user)), .alreadyDone)
        // Fail closed: no space listed, an unreadable type, no readable target.
        XCTAssertNotNil(refused(SpacePolicy.pullDecision(windowSpaces: [], target: (3, .user))))
        XCTAssertNotNil(refused(SpacePolicy.pullDecision(windowSpaces: [(4, nil)], target: (3, .user))))
        XCTAssertNotNil(refused(SpacePolicy.pullDecision(windowSpaces: [(4, .user)], target: nil)))
        XCTAssertNotNil(refused(SpacePolicy.pullDecision(windowSpaces: [(4, .user)], target: (3, nil))))
        XCTAssertNotNil(refused(SpacePolicy.pullDecision(windowSpaces: [(4, .system)], target: (3, .user))))
    }
}
