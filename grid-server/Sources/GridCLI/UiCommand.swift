import ArgumentParser
import Foundation

struct UiCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui",
        abstract: "Read a window's accessibility tree and act on its nodes by ref",
        subcommands: [
            UiSnapshot.self,
            UiQuery.self,
            UiValue.self,
            UiPress.self,
            UiSetValue.self,
            UiClick.self,
        ]
    )
}

struct UiSnapshot: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "snapshot", abstract: "Print a window's UI outline, one node per line")
    @Argument(help: "Window ID, or a ref (WINDOW:N) to expand one subtree")
    var target: String
    @Option(name: .long, help: "Node budget")
    var maxNodes: Int?
    @Option(name: .long, help: "Depth limit")
    var maxDepth: Int?
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        var params: [String: Any] = [target.contains(":") ? "ref" : "windowId": target]
        if let maxNodes { params["maxNodes"] = maxNodes }
        if let maxDepth { params["maxDepth"] = maxDepth }
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("ui.snapshot", params: params)
        if globals.json {
            printResult(result, json: true)
            return
        }
        print(result["outline"] as? String ?? "")
        if let truncated = result["truncated"] as? String {
            FileHandle.standardError.write(Data("truncated: \(truncated)\n".utf8))
        }
    }
}

struct UiQuery: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "query", abstract: "Find nodes in a window by role, text, or pressability")
    @Argument(help: "Window ID")
    var windowId: String
    @Option(name: .long, help: "Role, with or without the AX prefix: button, row, AXSwitch")
    var role: String?
    @Option(name: .long, help: "Case-insensitive substring of a node's title, value, description or label")
    var text: String?
    @Flag(name: .long, help: "Only nodes that can be pressed")
    var pressable = false
    @Option(name: .long, help: "Maximum matches")
    var limit: Int?
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        var params: [String: Any] = ["windowId": windowId]
        if let role { params["role"] = role }
        if let text { params["text"] = text }
        if pressable { params["pressable"] = true }
        if let limit { params["limit"] = limit }
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("ui.query", params: params)
        if globals.json {
            printResult(result, json: true)
        } else {
            print(result["outline"] as? String ?? "")
        }
    }
}

struct UiValue: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "value", abstract: "Print a node's full value by ref")
    @Argument var ref: String
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("ui.value", params: ["ref": ref])
        if globals.json {
            printResult(result, json: true)
        } else {
            print(result["value"] as? String ?? "")
        }
    }
}

struct UiPress: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "press", abstract: "AXPress a node by ref")
    @Argument var ref: String
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        printOkOrJSON(try client.call("ui.press", params: ["ref": ref]), json: globals.json)
    }
}

struct UiSetValue: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set a node's value by ref")
    @Argument var ref: String
    @Argument var value: String
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        printOkOrJSON(try client.call("ui.setValue", params: ["ref": ref, "value": value]), json: globals.json)
    }
}

struct UiClick: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "click", abstract: "Click the center of a node by ref")
    @Argument var ref: String
    @Option(name: .long, help: "left, right, or middle")
    var button: String = "left"
    @Option(name: .long, help: "Click count (2 for double-click)")
    var count: Int = 1
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        printOkOrJSON(try client.call("ui.click", params: ["ref": ref, "button": button, "count": count]), json: globals.json)
    }
}
