import XCTest
@testable import GridServer

final class TapWatchdogPolicyTests: XCTestCase {

    func testOneDeafIntervalOnlySuspectsThenRecreates() {
        var policy = TapWatchdogPolicy()
        XCTAssertEqual(policy.evaluate(systemKeys: 5, tapKeys: 0, inconclusive: false, restartAllowed: true), .suspect)
        XCTAssertEqual(policy.evaluate(systemKeys: 5, tapKeys: 0, inconclusive: false, restartAllowed: true), .recreateTap)
    }

    func testStillDeafAfterRecreateRestartsUnlessRecentlyRestarted() {
        var policy = TapWatchdogPolicy()
        for _ in 0..<2 { _ = policy.evaluate(systemKeys: 5, tapKeys: 0, inconclusive: false, restartAllowed: true) }
        var loopy = policy
        _ = policy.evaluate(systemKeys: 5, tapKeys: 0, inconclusive: false, restartAllowed: true)
        XCTAssertEqual(policy.evaluate(systemKeys: 5, tapKeys: 0, inconclusive: false, restartAllowed: true), .restartServer)
        _ = loopy.evaluate(systemKeys: 5, tapKeys: 0, inconclusive: false, restartAllowed: false)
        XCTAssertEqual(loopy.evaluate(systemKeys: 5, tapKeys: 0, inconclusive: false, restartAllowed: false), .stillDeaf)
    }

    func testTapHearingKeysClearsSuspicionAndRecreate() {
        var policy = TapWatchdogPolicy()
        for _ in 0..<2 { _ = policy.evaluate(systemKeys: 5, tapKeys: 0, inconclusive: false, restartAllowed: true) }
        XCTAssertEqual(policy.evaluate(systemKeys: 5, tapKeys: 5, inconclusive: false, restartAllowed: true), .ok)
        XCTAssertEqual(policy.evaluate(systemKeys: 5, tapKeys: 0, inconclusive: false, restartAllowed: true), .suspect)
        XCTAssertEqual(policy.evaluate(systemKeys: 5, tapKeys: 0, inconclusive: false, restartAllowed: true), .recreateTap)
    }

    func testFewKeysOrInconclusiveIntervalsNeverAct() {
        var policy = TapWatchdogPolicy()
        for _ in 0..<5 {
            XCTAssertEqual(policy.evaluate(systemKeys: 2, tapKeys: 0, inconclusive: false, restartAllowed: true), .ok)
            XCTAssertEqual(policy.evaluate(systemKeys: 50, tapKeys: 0, inconclusive: true, restartAllowed: true), .ok)
        }
    }
}
