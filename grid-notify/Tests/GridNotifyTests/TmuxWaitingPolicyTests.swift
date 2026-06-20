import XCTest
@testable import GridNotify

// MARK: - TmuxWaitingPolicyTests

// Pure-logic coverage for the waiting-transition predicate, the viewModel's
// baseline/dedupe/re-arm gating, the emission helper, and the store post path.
@MainActor
final class TmuxWaitingPolicyTests: XCTestCase {

    // MARK: - Helpers

    // Build a window directly off the JSON boundary via the memberwise init.
    private func window(_ target: String, _ kind: TmuxStatusKind, summary: String = "doing things") -> TmuxWindow {
        let parts = target.split(separator: ":")
        let index = Int(parts.last.map(String.init) ?? "0") ?? 0
        return TmuxWindow(
            index: index,
            name: "w",
            command: "cmd",
            active: false,
            statusKind: kind,
            summary: summary,
            target: target
        )
    }

    // Wrap a flat window list into TmuxStatusData (single synthetic session).
    private func statusData(_ windows: [TmuxWindow], generatedAt: Int = 1_718_500_000) -> TmuxStatusData {
        let session = TmuxSessionWrapper(name: "s", attached: true, windows: windows, activity: 0)
        return TmuxStatusDataWrapper(generatedAt: generatedAt, sessions: [session]).asData()
    }

    private func emptyData() -> TmuxStatusData {
        let json = #"{ "generatedAt": 1718500000, "sessions": [] }"#
        return try! JSONDecoder().decode(TmuxStatusData.self, from: Data(json.utf8))
    }

    // MARK: - DW-1.1

    // diff: a single new .waiting window over an empty previousWaiting →
    // newlyWaiting contains it; waitingNow contains only .waiting targets.
    func test_DW_1_1_diff_newlyWaiting_and_waitingNow() {
        let windows = [
            window("work:0", .active),
            window("work:1", .waiting),
            window("work:2", .running),
        ]
        let result = TmuxWaitingPolicy.diff(previousWaiting: [], windows: windows)

        XCTAssertEqual(result.newlyWaiting.map(\.target), ["work:1"])
        XCTAssertEqual(result.waitingNow, ["work:1"])
    }

    // MARK: - DW-1.2

    // Same window .waiting on two consecutive diffs → newlyWaiting only the first
    // time; waitingNow still contains it (dedupe while it stays waiting).
    func test_DW_1_2_dedupe_stays_waiting_not_repeated() {
        let windows = [window("work:0", .waiting)]

        let first = TmuxWaitingPolicy.diff(previousWaiting: [], windows: windows)
        XCTAssertEqual(first.newlyWaiting.map(\.target), ["work:0"])

        let second = TmuxWaitingPolicy.diff(previousWaiting: first.waitingNow, windows: windows)
        XCTAssertTrue(second.newlyWaiting.isEmpty, "Staying waiting must not re-fire")
        XCTAssertEqual(second.waitingNow, ["work:0"])
    }

    // MARK: - DW-1.3

    // waiting → left → waiting across three diffs → in newlyWaiting on entry #1
    // and entry #3, not in between (re-arm).
    func test_DW_1_3_rearm_after_leaving_waiting() {
        // Entry #1
        let d1 = TmuxWaitingPolicy.diff(previousWaiting: [], windows: [window("work:0", .waiting)])
        XCTAssertEqual(d1.newlyWaiting.map(\.target), ["work:0"])

        // Leaves waiting (now active)
        let d2 = TmuxWaitingPolicy.diff(previousWaiting: d1.waitingNow, windows: [window("work:0", .active)])
        XCTAssertTrue(d2.newlyWaiting.isEmpty)
        XCTAssertTrue(d2.waitingNow.isEmpty, "Left waiting → re-armed (not in waitingNow)")

        // Entry #3 — re-enters waiting, must fire again
        let d3 = TmuxWaitingPolicy.diff(previousWaiting: d2.waitingNow, windows: [window("work:0", .waiting)])
        XCTAssertEqual(d3.newlyWaiting.map(\.target), ["work:0"], "Re-entry must re-fire")
    }

    // Edge: a waiting window disappears entirely (session/window gone) → drops
    // from waitingNow (re-arms), no crash.
    func test_disappearing_window_drops_and_rearms() {
        let d1 = TmuxWaitingPolicy.diff(previousWaiting: [], windows: [window("work:0", .waiting)])
        XCTAssertEqual(d1.waitingNow, ["work:0"])

        // Window gone from the load entirely.
        let d2 = TmuxWaitingPolicy.diff(previousWaiting: d1.waitingNow, windows: [])
        XCTAssertTrue(d2.waitingNow.isEmpty)
        XCTAssertTrue(d2.newlyWaiting.isEmpty)

        // Reappears waiting → re-fires.
        let d3 = TmuxWaitingPolicy.diff(previousWaiting: d2.waitingNow, windows: [window("work:0", .waiting)])
        XCTAssertEqual(d3.newlyWaiting.map(\.target), ["work:0"])
    }

    // Edge: multiple windows enter waiting in one load → each appears once.
    func test_multiple_windows_enter_in_one_load() {
        let windows = [
            window("a:0", .waiting),
            window("b:0", .waiting),
            window("c:0", .active),
        ]
        let result = TmuxWaitingPolicy.diff(previousWaiting: [], windows: windows)
        XCTAssertEqual(Set(result.newlyWaiting.map(\.target)), ["a:0", "b:0"])
        XCTAssertEqual(result.waitingNow, ["a:0", "b:0"])
    }

    // MARK: - DW-1.4

    // First load with an already-waiting window → onWaitingEntered NOT called
    // (baseline seed); a second load introducing a new waiting window → called.
    func test_DW_1_4_baseline_seed_no_emit_then_emit_on_transition() {
        let vm = TmuxDashboardViewModel()
        var emitted: [[TmuxWindow]] = []
        vm.onWaitingEntered = { emitted.append($0) }

        // First load: already waiting → baseline, no emit.
        vm.load(statusData([window("work:0", .waiting)]))
        XCTAssertTrue(emitted.isEmpty, "First load must NOT emit even when already waiting")

        // Second load: a NEW window enters waiting → emit with that window.
        vm.load(statusData([window("work:0", .waiting), window("work:1", .waiting)]))
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted[0].map(\.target), ["work:1"])
    }

    // MARK: - DW-1.5

    // A real transition invokes onWaitingEntered exactly once per entered window.
    func test_DW_1_5_onWaitingEntered_once_per_window() {
        let vm = TmuxDashboardViewModel()
        var emitted: [TmuxWindow] = []
        vm.onWaitingEntered = { emitted.append(contentsOf: $0) }

        // Baseline (nothing waiting).
        vm.load(statusData([window("work:0", .active)]))
        XCTAssertTrue(emitted.isEmpty)

        // Two windows enter waiting at once → one invocation, two windows.
        vm.load(statusData([window("work:0", .waiting), window("work:1", .waiting)]))
        XCTAssertEqual(emitted.map(\.target), ["work:0", "work:1"])

        // Stays waiting → no further emission.
        vm.load(statusData([window("work:0", .waiting), window("work:1", .waiting)]))
        XCTAssertEqual(emitted.map(\.target), ["work:0", "work:1"], "Staying waiting must not re-emit")
    }

    // The emission helper builds a GridNotification with the expected fields.
    func test_DW_1_5_emission_helper_builds_notification() {
        let win = window("work:0", .waiting, summary: "claude waiting for input at prompt")
        let n = TmuxDashboardViewModel.makeWaitingNotification(for: win)

        XCTAssertEqual(n.title, "work:0 needs input")
        XCTAssertEqual(n.body, "claude waiting for input at prompt")
        XCTAssertEqual(n.detailCmd, "tmux capture-pane -pt work:0 -S -200")
        XCTAssertEqual(n.source, "tmux")
        XCTAssertNil(n.action, "No click action per the plan")
    }

    // Distinct episodes must produce distinct ids so NotificationStore.add (which
    // is idempotent by id) does not silently drop a re-entry post.
    func test_DW_1_5_distinct_episodes_have_distinct_ids() {
        let win = window("work:0", .waiting)
        let a = TmuxDashboardViewModel.makeWaitingNotification(for: win)
        let b = TmuxDashboardViewModel.makeWaitingNotification(for: win)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertTrue(a.id.hasPrefix("tmux-waiting-work:0-"))
    }

    // MARK: - DW-1.5b

    // The helper→store.add path the AppDelegate wiring uses actually persists the
    // built notification into the store (crosses the actor boundary).
    func test_DW_1_5b_store_add_persists_built_notification() async {
        let tmp = NSTemporaryDirectory() + "tmux-waiting-\(UUID().uuidString).json"
        let store = NotificationStore(storePath: tmp)

        let win = window("work:0", .waiting, summary: "needs input")
        let notification = TmuxDashboardViewModel.makeWaitingNotification(for: win)
        await store.add(notification)

        let stored = await store.get(id: notification.id)
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.title, "work:0 needs input")
        XCTAssertEqual(stored?.source, "tmux")
    }

    // MARK: - DW-1.6

    // waitingCount equals the number of currently-.waiting windows after a load.
    func test_DW_1_6_waitingCount_matches_waiting_windows() {
        let vm = TmuxDashboardViewModel()
        vm.load(statusData([
            window("work:0", .waiting),
            window("work:1", .active),
            window("work:2", .waiting),
            window("work:3", .running),
        ]))
        XCTAssertEqual(vm.waitingCount, 2)
    }

    // Empty data → waitingCount 0, no emission, no crash.
    func test_DW_1_6_empty_data_zero_count() {
        let vm = TmuxDashboardViewModel()
        var emitted = false
        vm.onWaitingEntered = { _ in emitted = true }
        vm.load(emptyData())
        XCTAssertEqual(vm.waitingCount, 0)
        XCTAssertFalse(emitted)
    }
}

// MARK: - Test JSON builders

// TmuxWindow has a memberwise init, but TmuxSession/TmuxStatusData are decode-only.
// These tiny encoders let the policy tests assemble TmuxStatusData from windows
// without hand-writing JSON per case.
private struct TmuxSessionWrapper: Encodable {
    let name: String
    let attached: Bool
    let windows: [TmuxWindow]
    let activity: Int
}

private struct TmuxStatusDataWrapper: Encodable {
    let generatedAt: Int
    let sessions: [TmuxSessionWrapper]

    func asData() -> TmuxStatusData {
        let json = try! JSONEncoder().encode(self)
        return try! JSONDecoder().decode(TmuxStatusData.self, from: json)
    }
}

// TmuxWindow needs Encodable for the wrapper above (it is Decodable in production).
extension TmuxWindow: Encodable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        try c.encode(name, forKey: .name)
        try c.encode(command, forKey: .command)
        try c.encode(active, forKey: .active)
        try c.encode(statusKind.rawValue, forKey: .statusKind)
        try c.encode(summary, forKey: .summary)
        try c.encode(target, forKey: .target)
    }

    private enum CodingKeys: String, CodingKey {
        case index, name, command, active, statusKind, summary, target
    }
}
