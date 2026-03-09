import ArgumentParser
import Foundation

struct CellCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cell",
        abstract: "Cell operations",
        subcommands: [
            CellSend.self,
            CellMode.self,
        ]
    )
}

struct CellSend: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "send")
    @Argument(help: "Direction to send window (left, right, up, down)")
    var direction: String
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        let result = try client.call("grid.cell.send", params: ["direction": direction])
        printOkOrJSON(result, json: globals.json)
    }
}

struct CellMode: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mode")
    @Argument(help: "Stack mode (omit to cycle)")
    var mode: String?
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        var params: [String: Any] = [:]
        if let mode = mode {
            params["mode"] = mode
        }

        let result = try client.call("grid.cell.mode", params: params)
        printOkOrJSON(result, json: globals.json)
    }
}
