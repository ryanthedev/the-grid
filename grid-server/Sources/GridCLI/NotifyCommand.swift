import ArgumentParser
import Foundation

// Top-level notify command with subcommands for notification management.
struct NotifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notify",
        abstract: "Notification management",
        subcommands: [
            NotifyShow.self,
            NotifyHide.self,
            NotifyToggle.self,
            NotifyPush.self,
            NotifyList.self,
            NotifyDismiss.self,
            NotifyClear.self,
            NotifyCount.self,
        ]
    )
}

// MARK: - Show / Hide / Toggle

struct NotifyShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show the notification panel"
    )

    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("grid.notify.show")
        printOkOrJSON(result, json: globals.json)
    }
}

struct NotifyHide: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hide",
        abstract: "Hide the notification panel"
    )

    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("grid.notify.hide")
        printOkOrJSON(result, json: globals.json)
    }
}

struct NotifyToggle: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "toggle",
        abstract: "Toggle the notification panel"
    )

    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("grid.notify.toggle")
        printOkOrJSON(result, json: globals.json)
    }
}

// MARK: - Push

struct NotifyPush: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push",
        abstract: "Push a new notification"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Notification title")
    var title: String

    @Option(name: .long, help: "Notification body text")
    var body: String?

    @Option(name: .long, help: "Priority: low, normal, high, urgent")
    var priority: String?

    @Option(name: .long, help: "Source label")
    var source: String?

    @Option(name: .long, help: "Action: focus:<wid>, exec:<cmd>, url:<url>")
    var action: String?

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        var params: [String: Any] = ["title": title]
        if let body { params["body"] = body }
        if let priority { params["priority"] = priority }
        if let source { params["source"] = source }
        if let action { params["action"] = action }

        let result = try client.call("grid.notify.push", params: params)
        printOkOrJSON(result, json: globals.json)
    }
}

// MARK: - List

struct NotifyList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List notifications"
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: .long, help: "Filter by source")
    var source: String?

    @Option(name: .long, help: "Minimum priority")
    var priority: String?

    @Flag(name: .long, help: "Include dismissed notifications")
    var all: Bool = false

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        var params: [String: Any] = [:]
        if let source { params["source"] = source }
        if let priority { params["priority"] = priority }
        if all { params["all"] = true }

        let result = try client.call("grid.notify.list", params: params)
        // The "message" field contains JSON array of notifications
        printResult(result, json: globals.json)
    }
}

// MARK: - Dismiss

struct NotifyDismiss: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dismiss",
        abstract: "Dismiss a notification by ID"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Notification ID to dismiss")
    var id: String

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("grid.notify.dismiss", params: ["id": id])
        printOkOrJSON(result, json: globals.json)
    }
}

// MARK: - Clear

struct NotifyClear: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Dismiss all active notifications"
    )

    @OptionGroup var globals: GlobalOptions

    @Flag(name: .long, help: "Permanently remove dismissed notifications")
    var purge: Bool = false

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        var params: [String: Any] = [:]
        if purge { params["purge"] = true }
        let result = try client.call("grid.notify.clear", params: params)
        printOkOrJSON(result, json: globals.json)
    }
}

// MARK: - Count

struct NotifyCount: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "count",
        abstract: "Count active notifications"
    )

    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("grid.notify.count")
        // Print just the count number for scripting.
        // If the response is unexpected (not a String), print "0" so callers
        // always receive a numeric string rather than silent empty output.
        if let msg = result["message"] as? String {
            print(msg)
        } else {
            print("0")
        }
    }
}
