import XCTest
@testable import GridServer

final class SecureInputPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testBriefPasswordPromptLogsOnAndOffWithoutWarning() {
        var policy = SecureInputPolicy()
        XCTAssertEqual(policy.update(enabled: true, pid: 42, now: t0), [.began(pid: 42)])
        XCTAssertEqual(policy.update(enabled: true, pid: 42, now: t0 + 5), [])
        XCTAssertEqual(policy.update(enabled: false, pid: nil, now: t0 + 6), [.ended(seconds: 6)])
    }

    func testStuckWarnsOnceAfterThreshold() {
        var policy = SecureInputPolicy()
        _ = policy.update(enabled: true, pid: 42, now: t0)
        XCTAssertEqual(policy.update(enabled: true, pid: 42, now: t0 + 19), [])
        XCTAssertEqual(policy.update(enabled: true, pid: 42, now: t0 + 20), [.stuck(pid: 42, seconds: 20)])
        XCTAssertEqual(policy.update(enabled: true, pid: 42, now: t0 + 60), [])
    }

    // Measured live: the reported pid follows the frontmost app while one
    // process holds Secure Input, so a pid change must not restart the clock.
    func testReportedPidChangeDoesNotRestartTheClock() {
        var policy = SecureInputPolicy()
        _ = policy.update(enabled: true, pid: 42, now: t0)
        XCTAssertEqual(policy.update(enabled: true, pid: 7, now: t0 + 10), [])
        XCTAssertEqual(policy.update(enabled: true, pid: 9, now: t0 + 20), [.stuck(pid: 9, seconds: 20)])
    }

    func testOffWhileOffIsSilentAndWarningRearms() {
        var policy = SecureInputPolicy()
        XCTAssertEqual(policy.update(enabled: false, pid: nil, now: t0), [])
        _ = policy.update(enabled: true, pid: 42, now: t0)
        _ = policy.update(enabled: true, pid: 42, now: t0 + 30)
        _ = policy.update(enabled: false, pid: nil, now: t0 + 31)
        _ = policy.update(enabled: true, pid: 42, now: t0 + 40)
        XCTAssertEqual(policy.update(enabled: true, pid: 42, now: t0 + 60), [.stuck(pid: 42, seconds: 20)])
    }
}
