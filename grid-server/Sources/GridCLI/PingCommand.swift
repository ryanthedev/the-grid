import ArgumentParser
import Foundation

struct PingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ping",
        abstract: "Ping the server"
    )

    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        let start = Date()
        let result = try client.call("ping")
        let elapsed = Date().timeIntervalSince(start) * 1000

        if globals.json {
            var out = result
            out["elapsed_ms"] = Int(elapsed)
            printResult(out, json: true)
        } else {
            print("pong (\(Int(elapsed))ms)")
        }
    }
}
