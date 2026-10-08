import ArgumentParser
import Foundation

struct DumpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump",
        abstract: "Print the complete window manager state as JSON (windows, displays, apps)"
    )
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        // Always JSON: the point of dump is to pipe it to jq.
        printResult(try client.call("dump"), json: true)
    }
}
