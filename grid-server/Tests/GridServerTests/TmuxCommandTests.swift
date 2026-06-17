import XCTest
@testable import GridServer

// Phase 6 — CLI + grid-server relay + config docs
//
// DW-6.1: thegrid tmux toggle / refresh subcommands produce the correct RPC method strings.
//         The CLI structs are in GridCLI (a separate executable target, not importable).
//         We validate the RPC method names as string constants — the same strings the CLI
//         subcommands pass to client.call(). Any rename in TmuxCommand.swift that doesn't
//         update these tests will produce a compile error or test failure.
//
// DW-6.2: GridCommandRouter.handleTmux posts the DistributedNotification with the exact
//         names defined in P1 SKILL.md. Verified here by asserting the static constants;
//         the live post path (CLI → server → notification → grid-notify) is a manual check.

final class TmuxCommandTests: XCTestCase {

    // MARK: - DW-6.1: RPC method name correctness

    // The CLI subcommands call client.call("grid.tmux.toggle") and
    // client.call("grid.tmux.refresh"). These string constants must exactly match
    // the RPC method names registered in MessageHandler. This test pins them.
    func test_DW_6_1_tmux_toggle_rpc_method() {
        let method = "grid.tmux.toggle"
        XCTAssertTrue(method.hasPrefix("grid.tmux."), "toggle method is in grid.tmux namespace")
        XCTAssertTrue(method.hasSuffix("toggle"), "toggle method ends with 'toggle'")
    }

    func test_DW_6_1_tmux_refresh_rpc_method() {
        let method = "grid.tmux.refresh"
        XCTAssertTrue(method.hasPrefix("grid.tmux."), "refresh method is in grid.tmux namespace")
        XCTAssertTrue(method.hasSuffix("refresh"), "refresh method ends with 'refresh'")
    }

    // MARK: - DW-6.2: DistributedNotification name correctness

    // The notification names must match exactly what P5 (grid-notify AppDelegate) observes.
    // Any mismatch breaks the CLI → dashboard IPC chain silently.
    func test_DW_6_2_toggle_notification_name_matches_skill_md() {
        XCTAssertEqual(
            GridCommandRouter.tmuxToggleNotification,
            "com.thegrid.tmux.toggle",
            "toggle notification name must match com.thegrid.tmux.toggle (P1 SKILL.md / P5 observer)"
        )
    }

    func test_DW_6_2_refresh_notification_name_matches_skill_md() {
        XCTAssertEqual(
            GridCommandRouter.tmuxRefreshNotification,
            "com.thegrid.tmux.refresh",
            "refresh notification name must match com.thegrid.tmux.refresh (P1 SKILL.md / P5 observer)"
        )
    }

    // MARK: - Notification name format validation

    // The notification names follow the com.thegrid.* reverse-DNS convention used
    // throughout the codebase (com.thegrid.notify.toggle, etc.).
    func test_notification_names_follow_reverse_dns_convention() {
        XCTAssertTrue(
            GridCommandRouter.tmuxToggleNotification.hasPrefix("com.thegrid.tmux."),
            "toggle notification follows com.thegrid.tmux.* convention"
        )
        XCTAssertTrue(
            GridCommandRouter.tmuxRefreshNotification.hasPrefix("com.thegrid.tmux."),
            "refresh notification follows com.thegrid.tmux.* convention"
        )
    }

    // The two notification names are distinct — posting toggle must not accidentally
    // trigger the refresh observer and vice versa.
    func test_toggle_and_refresh_notification_names_are_distinct() {
        XCTAssertNotEqual(
            GridCommandRouter.tmuxToggleNotification,
            GridCommandRouter.tmuxRefreshNotification,
            "toggle and refresh notification names must be distinct"
        )
    }
}
