import ArgumentParser
import Foundation

struct MenuCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "menu",
        abstract: "List an app's menu bar commands and run one by path",
        subcommands: [
            MenuSnapshot.self,
            MenuInvoke.self,
        ]
    )
}

struct MenuTargetOptions: ParsableArguments {
    @Option(name: .long, help: "App name or bundle identifier")
    var app: String?
    @Option(name: .long, help: "Any window of the app; menu invoke focuses it first")
    var window: String?

    func params() throws -> [String: Any] {
        if let window { return ["windowId": window] }
        if let app { return ["app": app] }
        throw ValidationError("give --app NAME or --window ID")
    }
}

struct MenuSnapshot: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "snapshot", abstract: "Print every menu command, one per line, without opening a menu")
    @OptionGroup var target: MenuTargetOptions
    @Option(name: .long, help: "Case-insensitive substring of the path or the shortcut")
    var text: String?
    @Flag(name: .long, help: "Only commands that are enabled now")
    var enabled = false
    @Option(name: .long, help: "Maximum lines")
    var limit: Int?
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        var params = try target.params()
        if let text { params["text"] = text }
        if enabled { params["enabled"] = true }
        if let limit { params["limit"] = limit }
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("menu.snapshot", params: params)
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

struct MenuInvoke: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "invoke", abstract: "Run a menu command by path, e.g. 'Edit > Select All' (activates the app)")
    @Argument(help: "Menu path, segments joined with '>'")
    var path: String
    @OptionGroup var target: MenuTargetOptions
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        var params = try target.params()
        params["path"] = path
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        printOkOrJSON(try client.call("menu.invoke", params: params), json: globals.json)
    }
}
