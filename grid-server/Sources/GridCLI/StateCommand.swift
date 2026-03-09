import ArgumentParser
import Foundation

struct StateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "state",
        abstract: "Grid state operations",
        subcommands: [
            StateShow.self,
            StateReset.self,
        ]
    )
}

struct StateShow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show")
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        let result = try client.call("grid.state.show")
        printResult(result, json: globals.json)
    }
}

struct StateReset: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reset")
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        let result = try client.call("grid.state.reset")
        printOkOrJSON(result, json: globals.json)
    }
}
