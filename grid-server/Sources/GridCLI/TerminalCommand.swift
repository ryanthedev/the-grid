import ArgumentParser
import Foundation

/// Toggles the grid terminal (Ghostty scratch window).
/// No parameters needed -- sends "grid.terminal" RPC to the server,
/// which handles all toggle logic (find/launch/hide/show).
struct TerminalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "terminal",
        abstract: "Toggle the terminal"
    )

    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        let result = try client.call("grid.terminal")

        printOkOrJSON(result, json: globals.json)
    }
}
