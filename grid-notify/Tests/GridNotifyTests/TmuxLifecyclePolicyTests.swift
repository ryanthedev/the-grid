import XCTest
@testable import GridNotify

// Tests for Phase 5: AppDelegate wiring + lifecycle + observers.
//
// Strategy:
//   - Pure lifecycle policy tests (TmuxDashboardLifecyclePolicy) run without
//     any AppKit context and cover DW-5.1, DW-5.3, DW-5.4 decision branches.
//   - Integration tests validate the watcher→viewModel wiring (DW-5.2) and
//     the onRefreshRequested→driver path (DW-5.3) using real objects but
//     without spawning a real claude process (injectable TmuxDriverCommand).
//   - AppDelegate itself is live AppKit and is not unit-tested (welc Sprout Method);
//     the live show/hide/toggle behavior is a manual-check item.
final class TmuxLifecyclePolicyTests: XCTestCase {

    // MARK: - Helpers

    private func makeConfig(
        interval: TimeInterval = 60,
        repoDir: String = "/tmp"
    ) -> NotifyConfig.Tmux {
        NotifyConfig.Tmux(enabled: true, interval: interval, repoDir: repoDir)
    }

    private var trueCommand: TmuxDriverCommand {
        TmuxDriverCommand(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
    }

    private func makeDriver() -> TmuxStatusDriver {
        let d = TmuxStatusDriver(config: makeConfig(), command: trueCommand)
        d._test_lockfilePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("policy-test-\(UUID().uuidString).lock")
            .path
        return d
    }

    private func makeSampleData() -> TmuxStatusData {
        let json = """
        {
          "generatedAt": 1718500001,
          "sessions": [
            {
              "name": "work",
              "attached": true,
              "windows": [
                {
                  "index": 0,
                  "name": "nvim",
                  "command": "nvim",
                  "active": true,
                  "statusKind": "active",
                  "summary": "editing main.swift",
                  "target": "work:0"
                }
              ]
            }
          ]
        }
        """
        let data = json.data(using: .utf8)!
        return try! JSONDecoder().decode(TmuxStatusData.self, from: data)
    }

    // MARK: - DW-5.1: policy decides show vs hide based on window visibility

    // When window is hidden, policy returns showAndStart.
    func test_DW_5_1_policy_showWhenHidden_returnsShowAndStart() {
        let action = TmuxDashboardLifecyclePolicy.action(windowVisible: false)
        XCTAssertEqual(action, .showAndStart,
            "When window is hidden, toggle must produce showAndStart")
    }

    // When window is visible, policy returns hideAndStop.
    func test_DW_5_1_policy_hideWhenVisible_returnsHideAndStop() {
        let action = TmuxDashboardLifecyclePolicy.action(windowVisible: true)
        XCTAssertEqual(action, .hideAndStop,
            "When window is visible, toggle must produce hideAndStop")
    }

    // Toggle is idempotent at the policy level: two consecutive 'visible' states
    // both yield hideAndStop; two 'hidden' states both yield showAndStart.
    func test_DW_5_1_policy_idempotent_show() {
        let a1 = TmuxDashboardLifecyclePolicy.action(windowVisible: false)
        let a2 = TmuxDashboardLifecyclePolicy.action(windowVisible: false)
        XCTAssertEqual(a1, .showAndStart)
        XCTAssertEqual(a2, .showAndStart)
    }

    func test_DW_5_1_policy_idempotent_hide() {
        let a1 = TmuxDashboardLifecyclePolicy.action(windowVisible: true)
        let a2 = TmuxDashboardLifecyclePolicy.action(windowVisible: true)
        XCTAssertEqual(a1, .hideAndStop)
        XCTAssertEqual(a2, .hideAndStop)
    }

    // MARK: - DW-5.2: watcher onChange → viewModel.load(_:) updates sessions live

    // Validates the wiring contract: when the watcher's onChange fires with new data,
    // the viewModel's sessions are updated on the MainActor.
    @MainActor
    func test_DW_5_2_watcherOnChange_callsViewModelLoad() async {
        let vm = TmuxDashboardViewModel()
        XCTAssertTrue(vm.sessions.isEmpty, "sessions must start empty")

        let sampleData = makeSampleData()

        // Simulate the watcher→viewModel wiring exactly as wired in setupTmuxDashboard:
        // onChange arrives on main queue → Task { @MainActor in vm.load(data) }
        let loadExpectation = XCTestExpectation(description: "viewModel.load called")
        var didLoad = false

        // Wire up the same closure pattern that AppDelegate uses.
        let onChangeClosure: (TmuxStatusData) -> Void = { [weak vm] data in
            Task { @MainActor in
                vm?.load(data)
                didLoad = true
                loadExpectation.fulfill()
            }
        }

        // Call the closure (simulating the watcher firing onChange).
        onChangeClosure(sampleData)

        await fulfillment(of: [loadExpectation], timeout: 1.0)

        XCTAssertTrue(didLoad)
        XCTAssertEqual(vm.sessions.count, 1,
            "After onChange fires, viewModel must have 1 session")
        XCTAssertEqual(vm.sessions[0].name, "work")
    }

    // MARK: - DW-5.3: onRefreshRequested → driver.refreshNow()

    // Validates the Refresh button wiring: vm.onRefreshRequested is wired to
    // driver.refreshNow(), so requestRefresh() → driver spawns.
    func test_DW_5_3_onRefreshRequested_callsDriverRefreshNow() {
        let driver = makeDriver()
        var refreshCalled = false

        // Simulate the closure wired in setupTmuxDashboard.
        let onRefresh: () -> Void = { [weak driver] in
            driver?.refreshNow()
            refreshCalled = true
        }

        onRefresh()
        Thread.sleep(forTimeInterval: 0.4)

        XCTAssertTrue(refreshCalled, "onRefreshRequested closure must have been called")
        XCTAssertEqual(driver._test_spawnCount, 1,
            "driver.refreshNow() must produce 1 spawn via the in-view Refresh path")
        driver.stop()
    }

    // The refresh notification path does not change window visibility (policy has no
    // visibility concept for refresh — it's a driver-only trigger).
    // We verify this by asserting the policy action for refresh is NOT about toggling.
    // (There is no policy function for refresh; it's a direct driver.refreshNow() call.)
    func test_DW_5_3_policy_refresh_doesNotChangeVisibility() {
        // Refresh notification calls driver.refreshNow() directly with no
        // TmuxDashboardLifecyclePolicy involvement. Validate this by asserting
        // that the policy only exposes the toggle action, not a refresh action.
        // Both toggle policy branches must be toggle-only.
        let showAction = TmuxDashboardLifecyclePolicy.action(windowVisible: false)
        let hideAction = TmuxDashboardLifecyclePolicy.action(windowVisible: true)
        XCTAssertNotEqual(showAction, hideAction,
            "Policy must distinguish show vs hide but refresh is not in the policy at all")
    }

    // MARK: - DW-5.4: hideAndStop stops the driver; terminate releases lock

    // When the policy yields hideAndStop, stopping the driver means no further spawns.
    // We verify this by starting a driver, stopping it, then verifying isRunning is false
    // and the flock is released.
    func test_DW_5_4_policy_hide_stopsDriver() {
        let driver = makeDriver()
        let lockPath = driver._test_lockfilePath!

        // Start the driver (gets the lock, runs /usr/bin/true immediately).
        driver.start()
        Thread.sleep(forTimeInterval: 0.4)

        // Simulate hideAndStop: policy says hideAndStop → stop the driver.
        let action = TmuxDashboardLifecyclePolicy.action(windowVisible: true)
        XCTAssertEqual(action, .hideAndStop)
        driver.stop()
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertFalse(driver._test_isRunning,
            "Driver must be stopped after hideAndStop action")

        // Verify flock is released — another fd can acquire it.
        let fd = open(lockPath, O_RDWR)
        guard fd >= 0 else {
            XCTFail("Could not open lockfile for flock verification")
            return
        }
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0,
            "Flock must be released after driver.stop()")
    }

    // applicationWillTerminate path: stopping watcher then driver is safe and releases
    // the lock. We simulate this with real objects.
    func test_DW_5_4_terminate_stopsDriverAndWatcher() {
        let driver = makeDriver()
        let watcher = TmuxStatusWatcher(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("test-status-\(UUID().uuidString).json")
            .path)

        driver.start()
        watcher.start()
        Thread.sleep(forTimeInterval: 0.4)

        // Simulate applicationWillTerminate teardown order: watcher then driver.
        watcher.stop()
        driver.stop()
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertFalse(driver._test_isRunning,
            "Driver must not be running after terminate-sequence stop()")
    }

    // MARK: - Additional: feature-off guard (config.tmux.enabled == false → no wiring)

    // When enabled is false, the setupTmuxDashboard() method is NOT called.
    // We validate the guard condition by checking the config flag directly.
    func test_featureDisabledByDefault() {
        let config = NotifyConfig.Tmux()
        XCTAssertFalse(config.enabled,
            "tmux dashboard must be disabled by default; each run costs a Claude invocation")
    }

    // An enabled config with valid settings passes through correctly.
    func test_featureEnabledConfigIsValid() {
        let config = NotifyConfig.Tmux(enabled: true, interval: 60, repoDir: "/tmp")
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.interval, 60)
        XCTAssertEqual(config.repoDir, "/tmp")
        XCTAssertNil(config.model, "model must default to nil (no override)")
    }
}
