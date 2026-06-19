import ArgumentParser
import Foundation

// Top-level tmux command with subcommands for the tmux status dashboard.
// Relays each action to grid-server via RPC, which posts the corresponding
// DistributedNotification observed by grid-notify.
struct TmuxCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tmux",
        abstract: "Tmux status dashboard control",
        subcommands: [
            TmuxToggle.self,
            TmuxRefresh.self,
        ]
    )
}

// MARK: - Toggle

// Sends grid.tmux.toggle to grid-server, which posts com.thegrid.tmux.toggle.
// grid-notify observes that notification to show/hide the dashboard and
// start/stop the background status driver.
struct TmuxToggle: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "toggle",
        abstract: "Toggle the tmux status dashboard"
    )

    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("grid.tmux.toggle")
        printOkOrJSON(result, json: globals.json)
    }
}

// MARK: - Refresh

// Sends grid.tmux.refresh to grid-server, which posts com.thegrid.tmux.refresh.
// grid-notify observes that notification to trigger an immediate status refresh
// without toggling dashboard visibility.
struct TmuxRefresh: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh",
        abstract: "Trigger an immediate tmux status refresh"
    )

    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("grid.tmux.refresh")
        printOkOrJSON(result, json: globals.json)
    }
}
