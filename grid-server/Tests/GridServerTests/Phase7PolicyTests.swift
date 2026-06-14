import XCTest
import Foundation
@testable import GridServer

/// Phase 7 pure-predicate unit tests. These exercise the decision logic off the
/// OS boundary (sockets / AX / SkyLight / processes). OS-level behaviors are
/// proved by integration tests and the plan's UAT layer.
final class Phase7PolicyTests: XCTestCase {

    // MARK: - DW-7.1 (#1) SIGPIPE removed from fatal list

    func test_DW_7_1_sigpipe_not_in_fatal_signal_list() {
        XCTAssertFalse(
            CrashReporter.fatalSignals.contains(SIGPIPE),
            "SIGPIPE must not be a fatal signal — a dead client must not kill the server")
    }

    func test_DW_7_1_real_crash_signals_still_fatal() {
        // The genuine crash signals must remain installed.
        for sig in [SIGSEGV, SIGABRT, SIGILL, SIGBUS, SIGFPE] {
            XCTAssertTrue(CrashReporter.fatalSignals.contains(sig), "\(sig) must stay fatal")
        }
    }

    // MARK: - DW-7.2 (#46) full-write loop

    func test_DW_7_2_full_write_loop_handles_short_write() {
        // send() returns 1 byte at a time → loop must keep going until all sent.
        var calls = 0
        let bytes: [UInt8] = Array("hello\n".utf8)
        let result = FullWrite.writeAll(bytes) { _, _ in
            calls += 1
            return (1, 0)
        }
        XCTAssertEqual(result, .ok)
        XCTAssertEqual(calls, bytes.count, "must issue one send per remaining byte on 1-byte writes")
    }

    func test_DW_7_2_full_write_retries_on_eintr_and_eagain() {
        var attempt = 0
        let bytes: [UInt8] = [1, 2, 3, 4]
        let result = FullWrite.writeAll(bytes) { _, len in
            attempt += 1
            switch attempt {
            case 1: return (-1, EINTR)
            case 2: return (-1, EAGAIN)
            default: return (len, 0)
            }
        }
        XCTAssertEqual(result, .ok)
        XCTAssertEqual(attempt, 3)
    }

    func test_DW_7_2_full_write_reports_disconnected_on_epipe() {
        let result = FullWrite.writeAll([1, 2, 3]) { _, _ in (-1, EPIPE) }
        XCTAssertEqual(result, .disconnected)
    }

    func test_DW_7_2_full_write_reports_disconnected_on_zero() {
        let result = FullWrite.writeAll([1, 2, 3]) { _, _ in (0, 0) }
        XCTAssertEqual(result, .disconnected)
    }

    func test_DW_7_2_full_write_reports_failed_on_other_errno() {
        let result = FullWrite.writeAll([1, 2, 3]) { _, _ in (-1, EINVAL) }
        XCTAssertEqual(result, .failed(EINVAL))
    }

    func test_DW_7_2_full_write_empty_is_ok() {
        XCTAssertEqual(FullWrite.writeAll([]) { _, _ in (0, 0) }, .ok)
    }

    // MARK: - DW-7.7 (#34) AX messaging timeout

    func test_DW_7_7_messaging_timeout_policy_is_sane() {
        XCTAssertTrue(AXMessagingTimeoutPolicy.isSane(AXMessagingTimeoutPolicy.timeoutSeconds))
        XCTAssertEqual(AXMessagingTimeoutPolicy.timeoutSeconds, 0.5)
        XCTAssertFalse(AXMessagingTimeoutPolicy.isSane(0))
        XCTAssertFalse(AXMessagingTimeoutPolicy.isSane(10))
    }

    // MARK: - DW-7.6 (#33) observer slot reservation

    func test_DW_7_6_slot_reservation_rejects_inflight_and_installed() {
        // Fresh pid: allowed.
        XCTAssertTrue(ObserverSlotPolicy.canCreate(installed: false, inFlight: false))
        // In-flight (the TOCTOU window): rejected — this is the fix.
        XCTAssertFalse(ObserverSlotPolicy.canCreate(installed: false, inFlight: true))
        // Already installed: rejected.
        XCTAssertFalse(ObserverSlotPolicy.canCreate(installed: true, inFlight: false))
        XCTAssertFalse(ObserverSlotPolicy.canCreate(installed: true, inFlight: true))
    }

    // MARK: - DW-7.7 (#34) app element carries a messaging timeout

    func test_DW_7_7_make_app_element_does_not_crash() {
        // Use this process's own pid; the call must return an element with the
        // timeout applied and not crash. (Behavioral non-freeze is a UAT item.)
        let element = makeAppElement(pid: getpid())
        // AXUIElement is non-optional; assert we got a usable CF object.
        XCTAssertNotNil(element as AnyObject)
    }

    // MARK: - DW-7.8 (#36) MSS re-probe

    func test_DW_7_8_reprobe_policy_on_repeated_fail() {
        XCTAssertFalse(MSSReprobePolicy.shouldReprobe(consecutiveFailures: 0))
        XCTAssertFalse(MSSReprobePolicy.shouldReprobe(consecutiveFailures: 2))
        XCTAssertTrue(MSSReprobePolicy.shouldReprobe(consecutiveFailures: 3))
        XCTAssertTrue(MSSReprobePolicy.shouldReprobe(consecutiveFailures: 9))
    }

    // MARK: - DW-7.9 (#37) watcher re-arm

    func test_DW_7_9_watcher_rearms_on_rename_or_delete() {
        XCTAssertTrue(ConfigWatcherPolicy.shouldRearm(eventFlags: .rename))
        XCTAssertTrue(ConfigWatcherPolicy.shouldRearm(eventFlags: .delete))
        XCTAssertTrue(ConfigWatcherPolicy.shouldRearm(eventFlags: [.rename, .write]))
    }

    func test_DW_7_9_watcher_does_not_rearm_on_plain_write() {
        XCTAssertFalse(ConfigWatcherPolicy.shouldRearm(eventFlags: .write))
        XCTAssertFalse(ConfigWatcherPolicy.shouldRearm(eventFlags: .extend))
    }

    // MARK: - DW-7.11 (#39) off-screen sentinel

    func test_DW_7_11_refuse_sentinel_frame() {
        let parked = CGRect(origin: TerminalFramePolicy.sentinel, size: CGSize(width: 800, height: 600))
        XCTAssertTrue(TerminalFramePolicy.isOffScreenSentinel(parked))
        let nearParked = CGRect(x: -9000, y: 100, width: 800, height: 600)
        XCTAssertTrue(TerminalFramePolicy.isOffScreenSentinel(nearParked))
    }

    func test_DW_7_11_accepts_real_frame() {
        let real = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertFalse(TerminalFramePolicy.isOffScreenSentinel(real))
        // A small negative origin (window slightly off the top-left, e.g. menu bar)
        // is NOT the sentinel.
        let slightly = CGRect(x: -20, y: -10, width: 800, height: 600)
        XCTAssertFalse(TerminalFramePolicy.isOffScreenSentinel(slightly))
    }

    // MARK: - DW-7.12 (#47) bundle-id match

    func test_DW_7_12_bundle_id_match_predicate() {
        // Doc-style bundle id matches the running app's bundleIdentifier.
        XCTAssertTrue(AppMatchPolicy.matches(configKey: "com.apple.finder",
                                             bundleID: "com.apple.finder", name: "Finder"))
        // Back-compat: a display-name key still matches the name.
        XCTAssertTrue(AppMatchPolicy.matches(configKey: "Finder",
                                             bundleID: "com.apple.finder", name: "Finder"))
        // Non-matching key matches neither.
        XCTAssertFalse(AppMatchPolicy.matches(configKey: "com.apple.safari",
                                              bundleID: "com.apple.finder", name: "Finder"))
    }

    func test_DW_7_12_blacklist_matches_by_bundle_id() {
        let blacklist: Set<String> = ["com.apple.finder"]
        XCTAssertTrue(AppMatchPolicy.isBlacklisted(blacklist, bundleID: "com.apple.finder", name: "Finder"))
        XCTAssertFalse(AppMatchPolicy.isBlacklisted(blacklist, bundleID: "com.apple.safari", name: "Safari"))
    }

    func test_DW_7_12_resolve_key_prefers_bundle_id() {
        let keys: Set<String> = ["com.example.app", "Legacy"]
        XCTAssertEqual(AppMatchPolicy.resolveKey(keys, bundleID: "com.example.app", name: "Example"), "com.example.app")
        XCTAssertEqual(AppMatchPolicy.resolveKey(keys, bundleID: "com.other.app", name: "Legacy"), "Legacy")
        XCTAssertNil(AppMatchPolicy.resolveKey(keys, bundleID: "com.other.app", name: "Other"))
    }

    // MARK: - DW-7.13 (#22) notify action → notification mapping

    func test_DW_7_13_notify_action_to_notification_mapping() {
        // Distinct actions must map to distinct notification names — NOT all toggle.
        XCTAssertEqual(NotifyActionPolicy.notificationName(forAction: "show"), "com.thegrid.notify.show")
        XCTAssertEqual(NotifyActionPolicy.notificationName(forAction: "hide"), "com.thegrid.notify.hide")
        XCTAssertEqual(NotifyActionPolicy.notificationName(forAction: "toggle"), "com.thegrid.notify.toggle")
        XCTAssertEqual(NotifyActionPolicy.notificationName(forAction: "push"), "com.thegrid.notify.push")
        XCTAssertEqual(NotifyActionPolicy.notificationName(forAction: "dismiss"), "com.thegrid.notify.dismiss")

        // show/hide/push/dismiss are all distinct from each other and from toggle.
        let names = Set(["show", "hide", "push", "dismiss"].map(NotifyActionPolicy.notificationName(forAction:)))
        XCTAssertEqual(names.count, 4, "actions must not collapse to one notification")
        XCTAssertFalse(names.contains("com.thegrid.notify.toggle"))
    }

    func test_DW_7_13_buildcommand_forwards_notify_params() {
        // payloadFlags is what buildCommand uses to forward notify params (the
        // #22 bug dropped these entirely). title/body/priority must be emitted.
        let params: [String: String] = ["title": "Build done", "body": "All green", "priority": "high"]
        let flags = NotifyActionPolicy.payloadFlags(lookup: { params[$0] }, purge: true)
        XCTAssertTrue(flags.contains("--title"))
        XCTAssertTrue(flags.contains("\"Build done\""))
        XCTAssertTrue(flags.contains("--body"))
        XCTAssertTrue(flags.contains("\"All green\""))
        XCTAssertTrue(flags.contains("--priority"))
        XCTAssertTrue(flags.contains("--purge"))
    }

    func test_DW_7_13_payload_flags_omit_absent_params() {
        let flags = NotifyActionPolicy.payloadFlags(lookup: { _ in nil }, purge: false)
        XCTAssertTrue(flags.isEmpty, "no params → no flags forwarded")
    }

    func test_DW_7_13_payload_actions_flagged() {
        XCTAssertTrue(NotifyActionPolicy.carriesPayload("push"))
        XCTAssertTrue(NotifyActionPolicy.carriesPayload("dismiss"))
        XCTAssertFalse(NotifyActionPolicy.carriesPayload("toggle"))
        XCTAssertFalse(NotifyActionPolicy.carriesPayload("show"))
    }
}
